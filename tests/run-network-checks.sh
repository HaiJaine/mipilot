#!/usr/bin/env bash

set -u
set -o pipefail

CONFIG_FILE="${MIPILOT_CONFIG_FILE:-/etc/mihomo/config.yaml}"
MIHOMO_BIN="${MIPILOT_MIHOMO_BIN:-/usr/local/bin/mihomo}"
YQ_BIN="${MIPILOT_YQ_BIN:-/usr/local/lib/mipilot/yq}"
TUN_ROUTING_STATE_FILE="${MIPILOT_TUN_ROUTING_STATE_FILE:-/var/lib/mipilot/tun-routing.state}"
TUN_ROUTING_TABLE="mipilot_tun"
TUN_ROUTING_PRIORITY_MIN=8950
TUN_ROUTING_PRIORITY_MAX=8990
EXPECTED_TUN="${1:-any}"
PASSED=0
WARNED=0
FAILED=0
API=""
API_SECRET=""
HEADER_CONFIG=""
RUNNING_TUN_DEVICE=""

pass() {
  printf '[PASS] %s\n' "$*"
  PASSED=$((PASSED + 1))
}

warn() {
  printf '[WARN] %s\n' "$*"
  WARNED=$((WARNED + 1))
}

fail() {
  printf '[FAIL] %s\n' "$*"
  FAILED=$((FAILED + 1))
}

config_value() {
  local key="$1"

  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" {
      value = $0
      sub("^" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^[[:space:]\"\047]+|[[:space:]\"\047]+$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_FILE" 2>/dev/null
}

cleanup() {
  [[ -n $HEADER_CONFIG ]] && rm -f -- "$HEADER_CONFIG"
}

trap cleanup EXIT

api_get() {
  local path="$1"
  local arguments=(
    -fsS
    --connect-timeout 3
    --max-time 8
  )

  [[ -n $HEADER_CONFIG ]] && arguments+=(--config "$HEADER_CONFIG")
  curl "${arguments[@]}" "${API}${path}"
}

tun_routing_state_value() {
  local key="$1"

  awk -F= -v key="$key" '$1 == key { print $2; exit }' "$TUN_ROUTING_STATE_FILE" 2>/dev/null
}

tun_routing_state_is_valid() {
  local version
  local table
  local priority
  local mark

  [[ -f $TUN_ROUTING_STATE_FILE ]] || return 1
  version="$(tun_routing_state_value version)"
  table="$(tun_routing_state_value table)"
  priority="$(tun_routing_state_value priority)"
  mark="$(tun_routing_state_value mark)"
  [[ $version == 1 && $table == "$TUN_ROUTING_TABLE" && $priority =~ ^[0-9]+$ ]] || return 1
  (( priority >= TUN_ROUTING_PRIORITY_MIN && priority <= TUN_ROUTING_PRIORITY_MAX )) || return 1
  [[ $mark == 0x40000000 || $mark == 0x20000000 || $mark == 0x10000000 || $mark == 0x08000000 ]]
}

tun_routing_rule_exists() {
  local family="$1"
  local priority="$2"
  local mark="$3"

  ip "$family" rule show 2>/dev/null \
    | grep -Eq "^[[:space:]]*${priority}:[[:space:]].*fwmark ${mark}/${mark}.*lookup main([[:space:]]|$)"
}

tun_routing_rules_ready() {
  local priority
  local mark
  local decimal
  local chain
  local original_rule
  local reply_rule
  local family
  local families=(-4)

  command -v nft >/dev/null 2>&1 || return 1
  tun_routing_state_is_valid || return 1
  priority="$(tun_routing_state_value priority)"
  mark="$(tun_routing_state_value mark)"
  decimal=$((mark))
  chain="$(nft list chain inet "$TUN_ROUTING_TABLE" prerouting 2>/dev/null)" || return 1
  original_rule="$(grep -F 'ct direction original' <<<"$chain" | grep -F 'ct status dnat' | grep -F 'ct mark set' || true)"
  reply_rule="$(grep -F 'ct direction reply' <<<"$chain" | grep -F 'meta mark set' || true)"
  [[ -n $original_rule && -n $reply_rule ]] || return 1
  grep -Eiq "(^|[^[:alnum:]_])((${mark})|(${decimal}))([^[:alnum:]_]|$)" <<<"$original_rule" || return 1
  grep -Eiq "(^|[^[:alnum:]_])((${mark})|(${decimal}))([^[:alnum:]_]|$)" <<<"$reply_rule" || return 1
  ip -6 rule show >/dev/null 2>&1 && families+=(-6)
  for family in "${families[@]}"; do
    tun_routing_rule_exists "$family" "$priority" "$mark" || return 1
  done
}

if [[ $EXPECTED_TUN != any && $EXPECTED_TUN != on && $EXPECTED_TUN != off ]]; then
  printf '用法: %s [any|on|off]\n' "$0" >&2
  exit 2
fi

printf 'MiPilot 网络检查\n'
printf '时间: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '主机: %s\n' "$(hostname)"
printf '内核: %s\n' "$(uname -srmo)"
printf '预期TUN: %s\n\n' "$EXPECTED_TUN"

if [[ -r $CONFIG_FILE ]]; then
  pass "配置文件可读: ${CONFIG_FILE}"
else
  fail "配置文件不可读: ${CONFIG_FILE}; 请使用 sudo 运行"
fi

if [[ -x $MIHOMO_BIN ]] && "$MIHOMO_BIN" -t -d "$(dirname -- "$CONFIG_FILE")" -f "$CONFIG_FILE" >/dev/null 2>&1; then
  pass "Mihomo配置验证通过"
else
  fail "Mihomo配置验证失败或内核不可执行: ${MIHOMO_BIN}"
fi

if [[ -c /dev/net/tun ]]; then
  pass "/dev/net/tun 可用"
else
  fail "/dev/net/tun 不可用"
fi

controller="$(config_value external-controller)"
API_SECRET="$(config_value secret)"
allow_lan="$(config_value allow-lan)"
bind_address="$(config_value bind-address)"
if [[ $controller =~ ^(127\.0\.0\.1|localhost):([0-9]+)$ ]]; then
  API="http://${controller}"
  if [[ -n $API_SECRET ]]; then
    HEADER_CONFIG="$(mktemp /tmp/mipilot-network-curl.XXXXXX)" || exit 1
    chmod 600 "$HEADER_CONFIG"
    escaped_secret="${API_SECRET//\\/\\\\}"
    escaped_secret="${escaped_secret//\"/\\\"}"
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_secret" >"$HEADER_CONFIG"
  fi
  if config_response="$(api_get /configs 2>/dev/null)"; then
    pass "Mihomo API 可访问: ${API}"
    running_tun="$(jq -r '.tun.enable // false' <<<"$config_response")"
    RUNNING_TUN_DEVICE="$(jq -r '.tun.device // empty' <<<"$config_response")"
    printf '       API报告TUN=%s\n' "$running_tun"
    case "$EXPECTED_TUN:$running_tun" in
      on:true|off:false|any:true|any:false) pass "TUN运行状态符合预期" ;;
      *) fail "TUN运行状态不符合预期: expected=${EXPECTED_TUN}, actual=${running_tun}" ;;
    esac
  else
    fail "Mihomo API 不可访问: ${API}"
  fi
else
  fail "external-controller 不是受支持的本机地址: ${controller:-未配置}"
fi
if [[ -n $API_SECRET ]]; then
  pass "Mihomo API 已配置访问密钥"
else
  fail "Mihomo API 未配置访问密钥"
fi
if [[ $allow_lan == false ]]; then
  pass "显式代理已禁止局域网访问: bind-address=${bind_address:-未配置}"
elif [[ $allow_lan == true ]]; then
  warn "显式代理允许局域网或容器访问: bind-address=${bind_address:-未配置}; 请确认认证和允许网段符合预期"
else
  fail "显式代理监听配置不完整: allow-lan=${allow_lan:-未配置}, bind-address=${bind_address:-未配置}"
fi

if route_v4="$(ip -4 route get 1.1.1.1 2>/dev/null)"; then
  pass "IPv4路由可解析"
  printf '       %s\n' "$route_v4"
else
  fail "IPv4路由无法解析"
fi

if [[ $EXPECTED_TUN == on ]]; then
  if [[ -n $RUNNING_TUN_DEVICE ]] && ip link show "$RUNNING_TUN_DEVICE" >/dev/null 2>&1; then
    pass "Mihomo TUN 网卡已建立: ${RUNNING_TUN_DEVICE}"
  else
    fail "Mihomo TUN 网卡未建立: ${RUNNING_TUN_DEVICE:-API未报告}"
  fi
  if [[ -x $YQ_BIN ]] &&
     "$YQ_BIN" eval -e '
       .tun.enable == true and
       .tun."auto-route" == true and
       .tun."auto-redirect" == false and
       .tun."strict-route" == false and
       (.tun."route-exclude-address" | any_c(. == "192.168.0.0/16")) and
       (.tun."route-exclude-address" | any_c(. == "100.64.0.0/10")) and
       (.rules | any_c(. == "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve")) and
       (.rules | any_c(. == "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve")) and
       (.dns != null) and
       (.dns.enable != true or (.tun."dns-hijack" | any_c(. == "any:53")))
     ' "$CONFIG_FILE" >/dev/null 2>&1; then
    pass "Mihomo原生TUN接管和局域网绕过配置完整"
  else
    fail "Mihomo原生TUN接管或局域网绕过配置不完整"
  fi
  if tun_routing_rules_ready; then
    pass "MiPilot DNAT入站连接回程保护已就绪"
  else
    fail "MiPilot DNAT入站连接回程保护不完整"
  fi
elif [[ $EXPECTED_TUN == off ]]; then
  if [[ ! -e $TUN_ROUTING_STATE_FILE ]] &&
     { ! command -v nft >/dev/null 2>&1 || ! nft list table inet "$TUN_ROUTING_TABLE" >/dev/null 2>&1; }; then
    pass "TUN关闭后没有MiPilot回程规则残留"
  else
    fail "TUN关闭后仍有MiPilot回程状态或nftables表"
  fi
fi

mapfile -t default_routes < <(ip -4 route show default 2>/dev/null)
if (( ${#default_routes[@]} == 0 )); then
  fail "没有IPv4默认路由"
elif (( ${#default_routes[@]} == 1 )); then
  pass "检测到单条IPv4默认路由"
else
  warn "检测到 ${#default_routes[@]} 条IPv4默认路由, 需要核对实际出口和回程"
fi
printf '       %s\n' "${default_routes[@]:-无}"

if [[ -n ${SSH_CONNECTION:-} ]]; then
  ssh_client="${SSH_CONNECTION%% *}"
  if ssh_route="$(ip route get "$ssh_client" 2>/dev/null)"; then
    pass "当前SSH客户端回程路由可解析: ${ssh_client}"
    printf '       %s\n' "$ssh_route"
  else
    warn "当前SSH客户端回程路由无法解析: ${ssh_client}"
  fi
else
  warn "当前不是SSH会话, 未验证远程回程路由"
fi

if getent ahosts cp.cloudflare.com >/dev/null 2>&1; then
  pass "系统DNS解析正常"
else
  fail "系统DNS解析失败"
fi

if curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 10 \
     -o /dev/null https://cp.cloudflare.com/generate_204; then
  pass "不使用显式代理的IPv4公网探测通过"
else
  warn "不使用显式代理的IPv4公网探测失败"
fi

mixed_port="$(config_value mixed-port)"
if [[ $mixed_port =~ ^[0-9]+$ ]]; then
  if curl -4 -fsS --proxy "http://127.0.0.1:${mixed_port}" --connect-timeout 5 --max-time 10 \
       -o /dev/null https://cp.cloudflare.com/generate_204; then
    pass "本机Mixed代理公网探测通过"
  else
    fail "本机Mixed代理公网探测失败: 127.0.0.1:${mixed_port}"
  fi
else
  warn "未配置mixed-port, 跳过本机代理探测"
fi

if ip -6 route show default 2>/dev/null | grep -q .; then
  if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    pass "IPv6默认路由可解析"
  else
    fail "存在IPv6默认路由但公网IPv6路由无法解析"
  fi
else
  warn "没有IPv6默认路由, 跳过IPv6检查"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    docker_networks="$(docker network ls --format '{{.Name}}' 2>/dev/null | tr '\n' ' ')"
    pass "Docker服务可访问"
    printf '       网络: %s\n' "${docker_networks:-无}"
    warn "本机Docker检查不代表公网映射端口可访问; 必须从独立公网客户端运行端点探测"
  else
    warn "已安装Docker但当前用户无法访问Docker服务"
  fi
else
  warn "未安装Docker, 跳过容器网络检查"
fi

if command -v nft >/dev/null 2>&1; then
  if nft list ruleset >/dev/null 2>&1; then
    pass "nftables规则可读取"
  else
    warn "nftables规则不可读取"
  fi
elif command -v iptables >/dev/null 2>&1; then
  if iptables -S >/dev/null 2>&1; then
    pass "iptables规则可读取"
  else
    warn "iptables规则不可读取"
  fi
else
  warn "未找到nft或iptables命令"
fi

printf '\nResult: %s passed, %s warned, %s failed\n' "$PASSED" "$WARNED" "$FAILED"
(( FAILED == 0 ))
