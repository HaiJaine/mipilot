#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
MANAGER_SCRIPT="${PROJECT_DIR}/mipilot"
NETWORK_CHECK_SCRIPT="${TEST_DIR}/run-network-checks.sh"

PASSED=0
FAILED=0
TEST_TEMP_DIR=""

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  if [[ $actual != "$expected" ]]; then
    printf '    %s: expected %q, got %q\n' "$description" "$expected" "$actual" >&2
    return 1
  fi
}

assert_exists() {
  local path="$1"

  [[ -e $path ]] || fail "expected path to exist: ${path}"
}

assert_not_exists() {
  local path="$1"

  [[ ! -e $path ]] || fail "expected path to be absent: ${path}"
}

assert_file_has_line() {
  local path="$1"
  local line="$2"
  local description="$3"

  grep -Fqx -- "$line" "$path" || fail "${description}: missing line ${line}"
}

assert_line_count() {
  local path="$1"
  local line="$2"
  local expected="$3"
  local description="$4"
  local actual

  actual="$(grep -Fxc -- "$line" "$path" || true)"
  assert_equal "$expected" "$actual" "$description"
}

run_as_mock_sudo() {
  while [[ ${1:-} == -n ]]; do shift; done
  [[ ${1:-} == -v ]] && return 0
  "$@"
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/mipilot-test.XXXXXX"
}

register_temp_dir_cleanup() {
  TEST_TEMP_DIR="$1"
  trap 'if [[ -n ${TEST_TEMP_DIR:-} ]]; then rm -rf -- "$TEST_TEMP_DIR"; fi' EXIT
}

load_manager() {
  # shellcheck disable=SC2034
  MIPILOT_TESTING=1
  # shellcheck source=/dev/null
  source "$MANAGER_SCRIPT"
  if [[ -n ${TEST_TEMP_DIR:-} ]]; then
    MANAGER_CONFIG_DIR="${TEST_TEMP_DIR}/etc/mipilot"
    MANAGER_CONFIG_FILE="${MANAGER_CONFIG_DIR}/config.json"
  fi
}

test_bash_syntax() {
  bash -n "$MANAGER_SCRIPT" && bash -n "$NETWORK_CHECK_SCRIPT"
}

test_manager_release_version() {
  load_manager || return 1
  assert_equal "1.0.1" "$MANAGER_VERSION" "manager release version"
}

test_source_testing_guard() {
  local output

  if ! output="$(
    bash -c '
      manager=$1
      sudo() { return 97; }
      set -- --menu
      MIPILOT_TESTING=1
      source "$manager" || exit $?
      nounset_state=off
      pipefail_state=off
      [[ $- == *u* ]] && nounset_state=on
      set -o | awk '\''$1 == "pipefail" && $2 == "on" { enabled = 1 } END { exit(enabled ? 0 : 1) }'\'' && pipefail_state=on
      printf "sourced:%s:nounset=%s:pipefail=%s" "$SCRIPT_SOURCED" "$nounset_state" "$pipefail_state"
    ' bash "$MANAGER_SCRIPT" 2>&1
  )"; then
    fail "sourcing with MIPILOT_TESTING=1 failed: ${output}"
    return 1
  fi

  assert_equal "sourced:1:nounset=off:pipefail=off" "$output" "testing mode must return without changing caller shell options"
}

test_source_preserves_enabled_shell_options() {
  local output

  if ! output="$(
    bash -c '
      manager=$1
      set -u
      set -o pipefail
      MIPILOT_TESTING=1
      source "$manager" || exit $?
      nounset_state=off
      pipefail_state=off
      [[ $- == *u* ]] && nounset_state=on
      set -o | awk '\''$1 == "pipefail" && $2 == "on" { enabled = 1 } END { exit(enabled ? 0 : 1) }'\'' && pipefail_state=on
      printf "sourced:%s:nounset=%s:pipefail=%s" "$SCRIPT_SOURCED" "$nounset_state" "$pipefail_state"
    ' bash "$MANAGER_SCRIPT" 2>&1
  )"; then
    fail "sourcing with enabled shell options failed: ${output}"
    return 1
  fi

  assert_equal "sourced:1:nounset=on:pipefail=on" "$output" "sourcing must preserve enabled caller shell options"
}

test_dependency_install_continues_after_partial_apt_update() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1

  missing_runtime_commands() {
    [[ -f $root/dependencies-installed ]] || printf 'nft\n'
  }
  dpkg-query() {
    return 1
  }
  read_line_or_back() {
    INPUT_LINE="y"
    return 0
  }
  sudo() {
    if [[ $1 == apt-get && $2 == update ]]; then
      printf 'update\n' >>"$root/apt-calls"
      return 100
    fi
    if [[ $1 == apt-get && $2 == install ]]; then
      printf 'install\n' >>"$root/apt-calls"
      touch "$root/dependencies-installed"
      return 0
    fi
    return 1
  }

  if ! output="$(ensure_install_dependencies 2>&1)"; then
    fail "dependency installation stopped after a partial apt update failure: ${output}"
    return 1
  fi
  assert_equal $'update\ninstall' "$(cat "$root/apt-calls")" "APT update and install calls" || return 1
  grep -Fq 'APT 软件源更新未完全成功' <<<"$output" || fail "partial APT update warning was not shown"
}

test_find_local_assets() {
  local root
  local country_name
  local geosite_name
  local staged

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1

  mkdir -p -- "$root/lower" "$root/upper" "$root/plain" "$root/wrong-arch"

  printf 'country\n' >"$root/lower/country.mmdb"
  printf 'geosite\n' >"$root/lower/geosite.dat"
  : >"$root/lower/mihomo-linux-amd64-v1.9.12.gz"
  : >"$root/lower/mihomo-linux-amd64-v1.19.28.gz"
  : >"$root/lower/mihomo-linux-amd64-v1.20.1.gz"
  : >"$root/lower/mihomo-linux-arm64-v99.0.0.gz"

  find_local_assets "$root/lower" || {
    fail "lowercase local assets were not detected"
    return 1
  }
  assert_equal "$root/lower/mihomo-linux-amd64-v1.20.1.gz" "$LOCAL_MIHOMO_SOURCE" "highest amd64 version" || return 1
  assert_equal "$root/lower/country.mmdb" "$LOCAL_COUNTRY_MMDB" "lowercase country database" || return 1
  assert_equal "$root/lower/geosite.dat" "$LOCAL_GEOSITE_DAT" "lowercase geosite database" || return 1

  printf 'country\n' >"$root/upper/Country.mmdb"
  printf 'geosite\n' >"$root/upper/GeoSite.dat"
  : >"$root/upper/mihomo-linux-amd64-v2.0.0.gz"

  find_local_assets "$root/upper" || {
    fail "uppercase local assets were not detected"
    return 1
  }
  country_name="${LOCAL_COUNTRY_MMDB##*/}"
  geosite_name="${LOCAL_GEOSITE_DAT##*/}"
  assert_equal "country.mmdb" "${country_name,,}" "uppercase country database" || return 1
  assert_equal "geosite.dat" "${geosite_name,,}" "uppercase geosite database" || return 1

  printf 'plain-mihomo\n' >"$root/plain/mihomo"
  printf 'country\n' >"$root/plain/country.mmdb"
  printf 'geosite\n' >"$root/plain/geosite.dat"
  printf 'compressed-mihomo\n' | gzip >"$root/plain/mihomo-linux-amd64-v9.9.9.gz"
  find_local_assets "$root/plain" || {
    fail "uncompressed Mihomo asset was not detected"
    return 1
  }
  assert_equal "$root/plain/mihomo" "$LOCAL_MIHOMO_SOURCE" "preferred uncompressed Mihomo" || return 1
  staged="$root/staged-mihomo"
  stage_mihomo_source "$LOCAL_MIHOMO_SOURCE" "$staged" || return 1
  assert_equal "plain-mihomo" "$(cat "$staged")" "staged uncompressed Mihomo" || return 1
  stage_mihomo_source "$root/plain/mihomo-linux-amd64-v9.9.9.gz" "$staged" || return 1
  assert_equal "compressed-mihomo" "$(cat "$staged")" "staged compressed Mihomo" || return 1

  printf 'country\n' >"$root/wrong-arch/country.mmdb"
  printf 'geosite\n' >"$root/wrong-arch/geosite.dat"
  : >"$root/wrong-arch/mihomo-linux-arm64-v3.0.0.gz"
  : >"$root/wrong-arch/mihomo-linux-amd64-v3.0.gz"

  if find_local_assets "$root/wrong-arch"; then
    fail "wrong-architecture or malformed archives must be rejected"
    return 1
  fi
  assert_equal "" "$LOCAL_MIHOMO_SOURCE" "rejected archive selection" || return 1
}

test_prune_config_backups() {
  local root
  local index
  local backups=()

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  BACKUP_DIR="$root/backups"
  mkdir -p -- "$BACKUP_DIR/nested"

  for index in 1 2 3 4 5; do
    printf 'backup %s\n' "$index" >"$BACKUP_DIR/config-${index}.yaml"
    touch -d "@$((1700000000 + index))" "$BACKUP_DIR/config-${index}.yaml"
  done
  printf 'keep\n' >"$BACKUP_DIR/unrelated.txt"
  printf 'keep\n' >"$BACKUP_DIR/config-unrelated.json"
  printf 'keep\n' >"$BACKUP_DIR/nested/config-nested.yaml"

  sudo() {
    run_as_mock_sudo "$@"
  }

  prune_config_backups 3 || return 1

  backups=("$BACKUP_DIR"/config-*.yaml)
  assert_equal "3" "${#backups[@]}" "retained backup count" || return 1
  assert_not_exists "$BACKUP_DIR/config-1.yaml" || return 1
  assert_not_exists "$BACKUP_DIR/config-2.yaml" || return 1
  assert_exists "$BACKUP_DIR/config-3.yaml" || return 1
  assert_exists "$BACKUP_DIR/config-4.yaml" || return 1
  assert_exists "$BACKUP_DIR/config-5.yaml" || return 1
  assert_exists "$BACKUP_DIR/unrelated.txt" || return 1
  assert_exists "$BACKUP_DIR/config-unrelated.json" || return 1
  assert_exists "$BACKUP_DIR/nested/config-nested.yaml" || return 1
}

test_cleanup_expired_rollbacks() {
  local root
  local now

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  ROLLBACK_DIR="$root/rollback"
  mkdir -p -- "$ROLLBACK_DIR/core" "$ROLLBACK_DIR/geo"
  now="$(date +%s)"
  printf '%s\n' "$((now - 73 * 60 * 60))" >"$ROLLBACK_DIR/core/created_at"
  printf '%s\n' "$((now - 71 * 60 * 60))" >"$ROLLBACK_DIR/geo/created_at"

  sudo() {
    run_as_mock_sudo "$@"
  }

  cleanup_expired_rollbacks || return 1

  assert_not_exists "$ROLLBACK_DIR/core" || return 1
  assert_exists "$ROLLBACK_DIR/geo" || return 1
  assert_exists "$ROLLBACK_DIR/geo/created_at" || return 1
}

test_detect_install_state() {
  local root
  local state

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1

  MIHOMO_BIN="$root/usr/local/bin/mihomo"
  CONFIG_FILE="$root/etc/mihomo/config.yaml"
  # shellcheck disable=SC2034
  SERVICE_FILE="$root/etc/systemd/system/mihomo.service"
  CLEANUP_SERVICE_FILE="$root/etc/systemd/system/mipilot-cleanup.service"
  CLEANUP_TIMER_FILE="$root/etc/systemd/system/mipilot-cleanup.timer"
  MANAGER_INSTALLED_SCRIPT="$root/usr/local/lib/mipilot/mipilot"
  MANAGER_COMMAND="$root/usr/local/bin/mipilot"
  INSTALL_MARKER="$root/var/lib/mipilot/installed"
  SHELL_RC_FILE="$root/home/.bashrc"
  MOCK_SYSTEMCTL_SERVICE=0

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == test ]]; then
      shift
      builtin test "$@"
      return $?
    fi
    return 98
  }

  systemctl() {
    [[ ${1:-} == cat && ${2:-} == mihomo && ${MOCK_SYSTEMCTL_SERVICE:-0} == 1 ]]
  }

  command() {
    if [[ ${1:-} == -v && ${2:-} == mihomo ]]; then
      return 1
    fi
    builtin command "$@"
  }

  state="$(detect_install_state)" || return 1
  assert_equal "absent" "$state" "absent installation state" || return 1

  mkdir -p -- "$(dirname -- "$CONFIG_FILE")"
  printf 'mixed-port: 7890\n' >"$CONFIG_FILE"
  state="$(detect_install_state)" || return 1
  assert_equal "partial" "$state" "partial installation state" || return 1

  mkdir -p -- "$(dirname -- "$MIHOMO_BIN")"
  printf '#!/usr/bin/env sh\n' >"$MIHOMO_BIN"
  chmod 755 "$MIHOMO_BIN"
  MOCK_SYSTEMCTL_SERVICE=1
  state="$(detect_install_state)" || return 1
  assert_equal "existing" "$state" "existing installation state" || return 1

  mkdir -p -- "$(dirname -- "$MANAGER_INSTALLED_SCRIPT")" "$(dirname -- "$INSTALL_MARKER")" "$(dirname -- "$SHELL_RC_FILE")" "$(dirname -- "$CLEANUP_SERVICE_FILE")"
  printf '#!/usr/bin/env bash\n' >"$MANAGER_INSTALLED_SCRIPT"
  printf 'installed\n' >"$INSTALL_MARKER"
  state="$(detect_install_state)" || return 1
  assert_equal "partial" "$state" "managed marker without command and cleanup units" || return 1

  printf '#!/usr/bin/env bash\n' >"$MANAGER_COMMAND"
  chmod 755 "$MANAGER_COMMAND"
  printf '[Service]\n' >"$CLEANUP_SERVICE_FILE"
  printf '[Timer]\n' >"$CLEANUP_TIMER_FILE"
  printf '%s\n' "$SHELL_INTEGRATION_BEGIN" >"$SHELL_RC_FILE"
  state="$(detect_install_state)" || return 1
  assert_equal "managed" "$state" "managed installation state" || return 1
}

test_mipilot_config_migration_and_materialization() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  SUBSCRIPTION_LIST_FILE="$CONFIG_DIR/subscriptions.list"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  mkdir -p -- "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<'EOF'
mode: global
tun:
  enable: true
EOF
  printf 'https://one.example/sub\n' >"$SUBSCRIPTION_FILE"
  printf 'https://one.example/sub\nhttps://two.example/sub\n' >"$SUBSCRIPTION_LIST_FILE"
  printf 'custom-1;MiPilot-日本;Japan;url-test\n' >"$REGION_STATE_FILE"
  printf 'Proxy\n' >"$REGION_PARENT_FILE"
  printf 'true\n' >"$TUN_STATE_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }
  installed_runtime_mode() {
    printf 'manual\n'
  }

  sync_mipilot_config_from_state || return 1
  jq -e '
    .schema_version == 1
    and .runtime.type == "manual"
    and .mode == "global"
    and .tun.enabled == true
    and .subscription.active == "https://one.example/sub"
    and (.subscription.items | length) == 2
    and .rule_selection.parent == "Proxy"
    and .custom_groups[0].name == "MiPilot-日本"
  ' "$MANAGER_CONFIG_FILE" >/dev/null || fail "migrated MiPilot config is incomplete"

  rm -f -- "$SUBSCRIPTION_FILE" "$SUBSCRIPTION_LIST_FILE" "$REGION_STATE_FILE" "$REGION_PARENT_FILE" "$TUN_STATE_FILE"
  materialize_mipilot_state || return 1
  assert_file_has_line "$SUBSCRIPTION_LIST_FILE" 'https://two.example/sub' "materialized subscriptions" || return 1
  assert_file_has_line "$REGION_STATE_FILE" 'custom-1;MiPilot-日本;Japan;url-test' "materialized custom group" || return 1
  assert_equal "Proxy" "$(cat "$REGION_PARENT_FILE")" "materialized rule parent" || return 1
  assert_equal "true" "$(cat "$TUN_STATE_FILE")" "materialized TUN state"
}

test_config_backup_bundles_mipilot_settings() {
  local root
  local backup

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  BACKUP_DIR="$CONFIG_DIR/backups"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf 'mode: rule\n' >"$CONFIG_FILE"
  cat >"$MANAGER_CONFIG_FILE" <<'EOF'
{
  "schema_version": 1,
  "runtime": {"type": "manual"},
  "mode": "rule",
  "tun": {"enabled": false},
  "subscription": {"active": "", "items": []},
  "rule_selection": {"parent": "", "group": ""},
  "global_selection": {"node": ""},
  "selector_selections": {},
  "custom_groups": []
}
EOF
  sudo() {
    run_as_mock_sudo "$@"
  }

  backup="$(create_config_backup bundled)" || return 1
  assert_exists "$backup" || return 1
  assert_exists "${backup%.yaml}.mipilot.json" || return 1
  cmp -s -- "$MANAGER_CONFIG_FILE" "${backup%.yaml}.mipilot.json" || fail "MiPilot settings backup differs"
}

test_tun_render_preserves_non_tun_state() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  cat >"$input_file" <<'EOF'
mode: global
tun:
  enable: false
proxy-groups:
  - name: MiPilot-日本
    type: url-test
    proxies:
      - JP-01
rules:
  - DOMAIN,example.com,MiPilot-日本
  - MATCH,DIRECT
EOF
  sudo() {
    run_as_mock_sudo "$@"
  }

  render_tun_config "$input_file" "$output_file" true || return 1
  assert_file_has_line "$output_file" 'mode: global' "preserved global mode" || return 1
  assert_file_has_line "$output_file" '  - name: MiPilot-日本' "preserved custom group" || return 1
  assert_file_has_line "$output_file" '  - DOMAIN,example.com,MiPilot-日本' "preserved custom rule"
}

test_runtime_mode_marker_precedence() {
  local root
  local mode

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  INSTALL_MARKER="$root/installed"
  printf 'runtime=manual\n' >"$INSTALL_MARKER"

  sudo() {
    run_as_mock_sudo "$@"
  }
  service_exists() {
    return 0
  }

  mode="$(installed_runtime_mode)" || return 1
  assert_equal "manual" "$mode" "marker runtime must override service fallback" || return 1
  printf 'runtime=service\n' >"$INSTALL_MARKER"
  mode="$(installed_runtime_mode)" || return 1
  assert_equal "service" "$mode" "service runtime marker" || return 1
}

test_runtime_backend_dispatch() {
  local selected=""

  load_manager || return 1
  installed_runtime_mode() {
    printf 'manual\n'
  }
  manual_start() {
    selected="manual-start"
  }
  manual_stop() {
    selected="manual-stop"
  }
  run_tun_routing_action() {
    return 0
  }
  runtime_start || return 1
  assert_equal "manual-start" "$selected" "manual start dispatch" || return 1
  runtime_stop || return 1
  assert_equal "manual-stop" "$selected" "manual stop dispatch" || return 1

  installed_runtime_mode() {
    printf 'service\n'
  }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == systemctl && ${2:-} == start && ${3:-} == mihomo ]]; then
      selected="service-start"
      return 0
    fi
    return 1
  }
  runtime_start || return 1
  assert_equal "service-start" "$selected" "service start dispatch"
}

test_install_runtime_choice_defaults_manual() {
  load_manager || return 1
  read_line_or_back() {
    INPUT_LINE=""
    return 0
  }
  choose_install_runtime_mode || return 1
  assert_equal "manual" "$SELECTED" "default install runtime" || return 1

  read_line_or_back() {
    INPUT_LINE="yes"
    return 0
  }
  choose_install_runtime_mode || return 1
  assert_equal "service" "$SELECTED" "explicit service install runtime"
}

test_service_unit_reconciles_tun_routing() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  SERVICE_FILE="$root/etc/systemd/system/mihomo.service"
  MANAGER_COMMAND="$root/usr/local/bin/mipilot"
  MIHOMO_BIN="$root/usr/local/bin/mihomo"
  CONFIG_DIR="$root/etc/mihomo"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == install && ${2:-} == -d ]]; then
      mkdir -p -- "${@: -1}"
      return
    fi
    run_as_mock_sudo "$@"
  }
  atomic_install_file() {
    local source_file="$2"
    local destination="$3"

    mkdir -p -- "$(dirname -- "$destination")"
    cp -- "$source_file" "$destination"
  }

  write_service_unit || return 1
  assert_file_has_line "$SERVICE_FILE" "ExecStartPre=+${MANAGER_COMMAND} --reconcile-tun-routing" "privileged service TUN routing setup" || return 1
  assert_file_has_line "$SERVICE_FILE" "ExecStart=\"${MIHOMO_BIN}\" -d \"${CONFIG_DIR}\"" "restricted Mihomo service process" || return 1
  assert_file_has_line "$SERVICE_FILE" "ExecStopPost=+${MANAGER_COMMAND} --remove-tun-routing" "privileged service TUN routing cleanup"
}

test_tun_routing_action_uses_independent_lock() {
  local root
  local invocation_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  invocation_file="$root/invocation"
  TUN_ROUTING_LOCK_FILE="$root/tun-routing.lock"
  SCRIPT_PATH="$root/mipilot"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    printf '%s\n' "$*" >"$invocation_file"
  }

  run_tun_routing_action reconcile || return 1
  assert_equal "flock --exclusive --wait 30 ${TUN_ROUTING_LOCK_FILE} env MIPILOT_CONFIG_DIR=${CONFIG_DIR} MIPILOT_STATE_DIR=${STATE_DIR} MIPILOT_TUN_ROUTING_STATE_FILE=${TUN_ROUTING_STATE_FILE} bash ${SCRIPT_PATH} --reconcile-tun-routing-unlocked" \
    "$(cat "$invocation_file")" "locked TUN routing reconciliation" || return 1
  run_tun_routing_action remove || return 1
  assert_equal "flock --exclusive --wait 30 ${TUN_ROUTING_LOCK_FILE} env MIPILOT_CONFIG_DIR=${CONFIG_DIR} MIPILOT_STATE_DIR=${STATE_DIR} MIPILOT_TUN_ROUTING_STATE_FILE=${TUN_ROUTING_STATE_FILE} bash ${SCRIPT_PATH} --remove-tun-routing-unlocked" \
    "$(cat "$invocation_file")" "locked TUN routing cleanup" || return 1
  if run_tun_routing_action invalid; then
    fail "unknown TUN routing action was accepted"
    return 1
  fi
  sudo() {
    return 75
  }
  if run_tun_routing_action reconcile; then
    fail "TUN routing lock failure was ignored"
    return 1
  fi
}

test_manager_lock_release() {
  local root

  if ! command -v flock >/dev/null 2>&1; then
    printf '    flock unavailable; lock behavior is covered on Ubuntu CI\n'
    return 0
  fi

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  LOCK_FILE="$root/mipilot.lock"

  sudo() {
    run_as_mock_sudo "$@"
  }

  acquire_manager_lock || return 1
  release_manager_lock
  flock -n "$LOCK_FILE" -c true || fail "released manager lock remained held by the caller shell"
}

test_lock_release_preserves_stderr() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1

  flock() {
    return 0
  }

  output="$(
    {
      exec 9>"$root/mipilot.lock"
      release_manager_lock
      printf 'stderr-alive' >&2
    } 2>&1
  )"
  assert_equal "stderr-alive" "$output" "lock release must not redirect the caller shell stderr"
}

test_download_uses_curl_without_forced_proxy() {
  local root
  local arguments_file
  local output
  local route_notice_count

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  arguments_file="$root/curl-arguments"

  run_cancellable_named() {
    shift 2
    printf '%s\n' "$@" >>"$arguments_file"
    return 0
  }

  output="$(
    download_file "https://example.test/release" "$root/release" "Mihomo 最新版本信息" &&
      download_file "https://example.test/file" "$root/output" "Mihomo 内核"
  )" || return 1
  [[ $output == *"正在下载: Mihomo 最新版本信息"* ]] || return 1
  [[ $output == *"正在下载: Mihomo 内核"* ]] || return 1
  route_notice_count="$(grep -Fc '网络路径由当前TUN、代理环境变量或系统路由决定.' <<<"$output")"
  assert_equal "1" "$route_notice_count" "route notice count" || return 1
  assert_line_count "$arguments_file" "curl" 2 "download command count" || return 1
  assert_file_has_line "$arguments_file" "-4" "IPv4 download option" || return 1
  assert_file_has_line "$arguments_file" "https://example.test/file" "download URL" || return 1
  if grep -Eq -- '^--(proxy|noproxy)$' "$arguments_file"; then
    fail "download command forced a proxy mode"
    return 1
  fi
}

test_render_tun_native_routing() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  sudo() {
    run_as_mock_sudo "$@"
  }
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  cat >"$input_file" <<'EOF'
mixed-port: 7890
tun:
  enable: false
  stack: mixed
  auto-route: false
  auto-redirect: true
  auto-detect-interface: false
rules:
  - MATCH,DIRECT
EOF

  render_tun_config "$input_file" "$output_file" true || return 1
  assert_file_has_line "$output_file" "  enable: true" "enabled TUN" || return 1
  assert_file_has_line "$output_file" "  auto-route: true" "enabled auto-route" || return 1
  assert_file_has_line "$output_file" "  auto-redirect: false" "disabled automatic redirect" || return 1
  assert_file_has_line "$output_file" "  auto-detect-interface: true" "enabled interface detection"
}

test_cleanup_legacy_tun_bypass() {
  local root
  local rules_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  TUN_BYPASS_STATE_FILE="$root/tun-bypass-ports.conf"
  TUN_BYPASS_SERVICE_FILE="$root/mipilot-tun-bypass.service"
  rules_file="$root/rules"
  printf 'tcp:8080\n' >"$TUN_BYPASS_STATE_FILE"
  printf '8990: from all ipproto tcp sport 8080 lookup main\n' >"$rules_file"

  sudo() {
    run_as_mock_sudo "$@"
  }
  ip() {
    [[ ${1:-} == -6 ]] && shift
    if [[ ${1:-} == rule && ${2:-} == show ]]; then
      cat "$rules_file"
    elif [[ ${1:-} == rule && ${2:-} == del ]]; then
      : >"$rules_file"
    else
      return 1
    fi
  }

  cleanup_legacy_tun_bypass || return 1
  assert_not_exists "$TUN_BYPASS_STATE_FILE" || return 1
  assert_equal '0' "$(wc -l <"$rules_file" | tr -d ' ')" "removed recorded legacy bypass rule"
}

test_tun_routing_rules_are_connection_based() {
  local root
  local ip_rules_file
  local table_file
  local generated_rules
  local remaining

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  STATE_DIR="$root/state"
  TUN_ROUTING_STATE_FILE="$STATE_DIR/tun-routing.state"
  ip_rules_file="$root/ip-rules"
  table_file="$root/nft-table"
  generated_rules="$root/generated.nft"
  printf '%s\n' '8990: from all lookup 100' >"$ip_rules_file"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == install && ${2:-} == -d ]]; then
      mkdir -p -- "${@: -1}"
      return
    fi
    run_as_mock_sudo "$@"
  }
  atomic_install_file() {
    local source_file="$2"
    local destination="$3"

    mkdir -p -- "$(dirname -- "$destination")"
    cp -- "$source_file" "$destination"
  }
  ip() {
    local family="$1"
    shift
    [[ $family == -4 ]] || return 1
    if [[ ${1:-} == rule && ${2:-} == show ]]; then
      cat "$ip_rules_file"
    elif [[ ${1:-} == rule && ${2:-} == add ]]; then
      printf '%s: from all fwmark %s lookup main\n' "$4" "$6" >>"$ip_rules_file"
    elif [[ ${1:-} == rule && ${2:-} == del ]]; then
      awk -F: -v priority="$4" '$1 + 0 != priority' "$ip_rules_file" >"${ip_rules_file}.next"
      mv -- "${ip_rules_file}.next" "$ip_rules_file"
    else
      return 1
    fi
  }
  nft() {
    if [[ ${1:-} == list && ${2:-} == ruleset ]]; then
      return 0
    elif [[ ${1:-} == list && ${2:-} == chain ]]; then
      [[ -f $table_file ]] && cat "$generated_rules"
    elif [[ ${1:-} == list && ${2:-} == table ]]; then
      [[ -f $table_file ]]
    elif [[ ${1:-} == -f ]]; then
      cp -- "$2" "$generated_rules"
      : >"$table_file"
    elif [[ ${1:-} == delete && ${2:-} == table ]]; then
      rm -f -- "$table_file"
    else
      return 1
    fi
  }
  tun_routing_priority_in_use() {
    [[ $1 == 8990 ]]
  }
  tun_routing_mark_in_use() {
    return 1
  }

  setup_tun_routing_rules || return 1
  assert_file_has_line "$TUN_ROUTING_STATE_FILE" 'priority=8989' "selected free rule priority" || return 1
  assert_file_has_line "$TUN_ROUTING_STATE_FILE" 'mark=0x40000000' "selected connection mark" || return 1
  grep -Fq 'ct direction original ct status dnat' "$generated_rules" || return 1
  grep -Fq 'ct direction reply ct mark & 0x40000000' "$generated_rules" || return 1
  if grep -Eq 'dport|sport|8080' "$generated_rules"; then
    fail "TUN routing rules depend on a port"
    return 1
  fi

  setup_tun_routing_rules || return 1
  assert_equal '1' "$(grep -c 'fwmark' "$ip_rules_file")" "idempotent TUN route rule" || return 1

  sed -i 's/0x40000000/0x20000000/g' "$generated_rules"
  if tun_routing_rules_ready; then
    fail "mismatched managed nft mark was accepted"
    return 1
  fi
  setup_tun_routing_rules || return 1
  grep -Fq 'ct direction original ct status dnat ct mark set ct mark | 0x40000000' "$generated_rules" || return 1

  printf 'table inet mipilot_tun { chain prerouting { } }\n' >"$generated_rules"
  if tun_routing_rules_ready; then
    fail "empty managed nft chain was accepted"
    return 1
  fi
  setup_tun_routing_rules || return 1
  grep -Fq 'ct direction original ct status dnat' "$generated_rules" || return 1
  grep -Fq 'ct direction reply ct mark & 0x40000000' "$generated_rules" || return 1

  remove_tun_routing_rules || return 1
  assert_not_exists "$TUN_ROUTING_STATE_FILE" || return 1
  assert_not_exists "$table_file" || return 1
  remaining="$(cat "$ip_rules_file")"
  assert_equal '8990: from all lookup 100' "$remaining" "preserved unrelated route rule"
}

test_reconcile_tun_runtime_state() {
  local root
  local cleaned=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'tun:' \
    '  enable: true' \
    'rules:' \
    '  - MATCH,DIRECT' >"$CONFIG_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }
  cleanup_legacy_tun_bypass() {
    cleaned=1
  }

  reconcile_tun_runtime_state || return 1
  assert_equal 'true' "$(cat "$TUN_STATE_FILE")" "reconciled TUN state" || return 1
  jq -e '.tun.enabled == true' "$MANAGER_CONFIG_FILE" >/dev/null || {
    fail "reconciled MiPilot TUN setting"
    return 1
  }
  assert_equal '1' "$cleaned" "cleaned legacy TUN bypass"
}

test_tun_state_sync_failure_restores_sidecar() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  TUN_STATE_FILE="$root/tun.state"
  printf 'false\n' >"$TUN_STATE_FILE"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == install && ${2:-} == -m ]]; then
      shift 3
      cp -- "$1" "$2"
      return
    fi
    run_as_mock_sudo "$@"
  }
  update_mipilot_tun() {
    return 1
  }

  if save_tun_state true; then
    fail "TUN state save succeeded after MiPilot config sync failure"
    return 1
  fi
  assert_equal 'false' "$(cat "$TUN_STATE_FILE")" "restored TUN sidecar after MiPilot config sync failure"
}

test_mode_switch_persists_config() {
  local root
  local api_calls

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'
  api_calls="$root/api-calls"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'mixed-port: 7890' \
    'mode: rule' \
    'rules:' \
    '  - MATCH,DIRECT' >"$CONFIG_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }
  require_api() {
    return 0
  }
  choose_item() {
    # shellcheck disable=SC2034
    SELECTED='global'
    return 0
  }
  run_cancellable_named() {
    return 0
  }
  create_config_backup() {
    printf '%s\n' "$root/config-backup.yaml"
  }
  api() {
    if (( $# == 1 )); then
      printf '%s\n' '{"mode":"rule"}'
    else
      printf '%s\n' "$*" >>"$api_calls"
    fi
  }

  switch_mode >/dev/null || return 1
  assert_file_has_line "$CONFIG_FILE" 'mode: global' "persisted global mode" || return 1
  assert_line_count "$CONFIG_FILE" 'mode: global' 1 "persisted mode count" || return 1
  grep -Fq '"mode":"global"' "$api_calls" || fail "runtime mode API update was missing"
}

test_render_store_selected_config() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'mode: rule' \
    'profile:' \
    '  store-selected: false' \
    '  store-fake-ip: true' \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  render_store_selected_config "$input_file" "$output_file" || return 1
  assert_file_has_line "$output_file" '  store-selected: true' "enabled selected-node persistence" || return 1
  assert_file_has_line "$output_file" '  store-fake-ip: true' "preserved profile setting" || return 1
  assert_line_count "$output_file" '  store-selected: true' 1 "store-selected count"
}

test_custom_region_group_rendering() {
  local root
  local input_file
  local output_file
  local state_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  state_file="$root/region-groups.conf"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "🚀节点选择"' \
    '    type: select' \
    '    proxies:' \
    '      - DIRECT' \
    'rules:' \
    '  - MATCH,🚀节点选择' >"$input_file"
  printf '%s\n' \
    'custom-1;MiPilot-亚洲优选;日本|Japan|JP|新加坡|Singapore|SG;fallback' \
    'custom-2;MiPilot-日本手动;日本|Japan|JP;select' \
    'custom-3;MiPilot-旧版自动;新加坡|Singapore|SG' >"$state_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_region_groups_to_config "$input_file" "$output_file" "$state_file" || return 1
  assert_file_has_line "$output_file" '  - name: "MiPilot-亚洲优选"' "custom group definition" || return 1
  assert_file_has_line "$output_file" '      - "MiPilot-亚洲优选"' "custom group parent reference" || return 1
  assert_file_has_line "$output_file" '    type: fallback' "custom group fallback type" || return 1
  assert_file_has_line "$output_file" '    type: select' "custom group manual selection type" || return 1
  assert_file_has_line "$output_file" '    type: url-test' "legacy group automatic selection type" || return 1
  grep -Fq '日本|Japan|JP|新加坡|Singapore|SG' "$output_file" || fail "custom group combined filter was missing"
}

test_rule_mode_selects_managed_group() {
  local root
  local api_calls
  local choices_file
  local api_response
  local item

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  REGION_STATE_FILE="$root/region-groups.conf"
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'
  api_calls="$root/api-calls"
  choices_file="$root/choices"
  printf '%s\n' 'custom-1;MiPilot-亚洲优选;Japan|Singapore' >"$REGION_STATE_FILE"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "🚀节点选择"' \
    '    type: select' \
    'rules:' \
    '  - MATCH,🚀节点选择' >"$CONFIG_FILE"
  api_response='{"proxies":{"🚀节点选择":{"type":"Selector","all":["DIRECT","自动选择","MiPilot-亚洲优选"],"now":"自动选择"},"自动选择":{"type":"URLTest","all":["香港01","日本01"],"now":"香港01"},"MiPilot-亚洲优选":{"type":"URLTest","all":["日本01","新加坡01"],"now":"新加坡01"},"香港01":{"type":"Vmess"},"日本01":{"type":"Vmess"},"新加坡01":{"type":"Vmess"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }
  api() {
    if (( $# == 1 )); then
      printf '%s\n' "$api_response"
    else
      printf '%s\n' "$*" >>"$api_calls"
    fi
  }
  choose_item() {
    printf '%s\n' "$@" >"$choices_file"
    for item in "$@"; do
      if [[ $item == *'MiPilot-亚洲优选'* ]]; then
        # shellcheck disable=SC2034
        SELECTED="$item"
        return 0
      fi
    done
    return 1
  }

  manage_rule_nodes >/dev/null || return 1
  grep -Fq '自动选择' "$choices_file" || fail "subscription strategy group was not listed"
  grep -Fq 'MiPilot-亚洲优选' "$choices_file" || fail "custom strategy group was not listed"
  grep -Fq 'MiPilot-亚洲优选' "$api_calls" || fail "managed group API selection was missing"
  grep -Fq '/proxies/%F0%9F%9A%80%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9' "$api_calls" || fail "managed parent group API target was incorrect"
}

test_dynamic_region_parent_selection() {
  local root
  local response

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: Proxy' \
    '    type: select' \
    'rules:' \
    '  - MATCH,Proxy' >"$CONFIG_FILE"
  response='{"proxies":{"Proxy":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"GLOBAL":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }

  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal 'Proxy' "$REGION_PARENT" "automatically selected sole non-GLOBAL parent"
}

test_unreferenced_selector_uses_managed_rule_outlet() {
  local root
  local response

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 节点选择' \
    '    type: select' \
    '  - name: 实际出口' \
    '    type: url-test' \
    'rules:' \
    '  - DOMAIN-SUFFIX,example.com,节点选择' \
    '  - MATCH,实际出口' >"$CONFIG_FILE"
  response='{"proxies":{"节点选择":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"实际出口":{"type":"URLTest","all":["日本01"],"now":"日本01"},"GLOBAL":{"type":"Selector","all":["日本01"],"now":"日本01"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }

  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal '节点选择' "$REGION_PARENT" "rule-referenced selector parent" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 节点选择' \
    '    type: select' \
    '  - name: 实际出口' \
    '    type: url-test' \
    'rules:' \
    '  - MATCH,实际出口' >"$CONFIG_FILE"
  rm -f -- "$REGION_PARENT_FILE"
  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal "$REGION_MANAGED_PARENT" "$REGION_PARENT" "unreferenced selector must not be selected"
}

test_custom_region_group_without_subscription_groups() {
  local root
  local input_file
  local output_file
  local state_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  state_file="$root/region-groups.conf"
  printf '%s\n' \
    'proxies:' \
    '  - name: 日本01' \
    '    type: vmess' \
    'rules:' \
    '  - GEOIP,CN,DIRECT' \
    '  - MATCH,DIRECT' >"$input_file"
  printf '%s\n' \
    'custom-1;MiPilot-日本优选;日本|Japan|JP;url-test' >"$state_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_region_groups_to_config \
    "$input_file" "$output_file" "$state_file" "$REGION_MANAGED_PARENT" || return 1
  assert_file_has_line "$output_file" '  - name: "MiPilot-日本优选"' "standalone custom group definition" || return 1
  assert_file_has_line "$output_file" '  - name: "MiPilot-规则出口"' "managed rule outlet definition" || return 1
  assert_file_has_line "$output_file" '      - "MiPilot-日本优选"' "managed outlet custom group reference" || return 1
  assert_file_has_line "$output_file" '  - GEOIP,CN,DIRECT' "preserved direct rule" || return 1
  assert_file_has_line "$output_file" '  - MATCH,"MiPilot-规则出口"' "managed outlet match rule"
}

test_region_group_strategy_refresh() {
  local root
  local input_file
  local output_file
  local state_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  state_file="$root/region-groups.conf"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "MiPilot-日本"' \
    '    type: url-test' \
    '    include-all-proxies: true' \
    '    filter: "old"' \
    '    exclude-filter: "old"' \
    '    url: https://old.example' \
    '    interval: 60' \
    '    tolerance: 100' \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"
  printf '%s\n' 'custom-1;MiPilot-日本;日本|Japan;fallback' >"$state_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  refresh_saved_region_definitions "$input_file" "$output_file" "$state_file" || return 1
  assert_file_has_line "$output_file" '    type: fallback' "updated managed group type" || return 1
  assert_file_has_line "$output_file" '    interval: 300' "updated fallback interval" || return 1
  if grep -Fq 'tolerance:' "$output_file"; then
    fail "fallback group retained URLTest tolerance"
    return 1
  fi
}

test_remove_region_group_exact_match() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: Proxy' \
    '    type: select' \
    '    proxies:' \
    '      - "MiPilot-日本"' \
    '      - "MiPilot-日本-备用"' \
    '  - name: "MiPilot-日本"' \
    '    type: url-test' \
    '  - name: "MiPilot-日本-备用"' \
    '    type: url-test' \
    'rules:' \
    '  - MATCH,Proxy' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  render_without_region_group "$input_file" "$output_file" 'MiPilot-日本' || return 1
  if grep -Fq 'name: "MiPilot-日本"' "$output_file"; then
    fail "removed group definition remained"
    return 1
  fi
  assert_file_has_line "$output_file" '      - "MiPilot-日本-备用"' "substring group reference preserved" || return 1
  assert_file_has_line "$output_file" '  - name: "MiPilot-日本-备用"' "substring group definition preserved"
}

test_missing_selector_uses_managed_rule_outlet() {
  local root
  local response

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'proxies:' \
    '  - name: 日本01' \
    '    type: vmess' \
    'rules:' \
    '  - MATCH,DIRECT' >"$CONFIG_FILE"
  response='{"proxies":{"日本01":{"type":"Vmess"},"GLOBAL":{"type":"Selector","all":["日本01"],"now":"日本01"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }

  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal "$REGION_MANAGED_PARENT" "$REGION_PARENT" "selected managed rule outlet"
}

test_managed_outlet_keeps_subscription_groups() {
  local root
  local input_file
  local output_file
  local state_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  state_file="$root/region-groups.conf"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "订阅自动选择"' \
    '    type: url-test' \
    '    proxies:' \
    '      - 日本01' \
    'rules:' \
    '  - MATCH,订阅自动选择' >"$input_file"
  printf '%s\n' \
    'custom-1;MiPilot-日本优选;日本|Japan|JP;url-test' >"$state_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_region_groups_to_config \
    "$input_file" "$output_file" "$state_file" "$REGION_MANAGED_PARENT" || return 1
  assert_file_has_line "$output_file" '      - "订阅自动选择"' "managed outlet subscription group reference" || return 1
  assert_file_has_line "$output_file" '      - "MiPilot-日本优选"' "managed outlet custom group reference"
}

test_render_minimal_config() {
  local root
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/etc/mihomo/config.yaml"
  output_file="$root/minimal.yaml"
  mkdir -p -- "$(dirname -- "$CONFIG_FILE")"
  printf 'secret: old-secret\n' >"$CONFIG_FILE"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == test ]]; then
      shift
      builtin test "$@"
      return $?
    fi
    return 98
  }

  config_value() {
    if [[ ${1:-} == secret ]]; then
      printf 'test-secret\n'
      return 0
    fi
    return 1
  }

  render_minimal_config "$output_file" || return 1

  assert_file_has_line "$output_file" "mode: direct" "direct mode" || return 1
  assert_file_has_line "$output_file" "  enable: false" "disabled TUN" || return 1
  assert_file_has_line "$output_file" "  auto-redirect: false" "server-compatible redirect mode" || return 1
  assert_file_has_line "$output_file" "proxies: []" "empty proxy nodes" || return 1
  assert_file_has_line "$output_file" "proxy-groups: []" "empty proxy groups" || return 1
  assert_file_has_line "$output_file" "  - MATCH,DIRECT" "direct fallback rule" || return 1
}

test_verify_sha256_sidecar() {
  local root
  local file
  local actual_hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  file="$root/country.mmdb"
  printf 'mihomo geo test data\n' >"$file"
  actual_hash="$(sha256sum "$file" | awk '{print $1}')"
  printf '%s  %s\n' "${actual_hash^^}" "$(basename -- "$file")" >"$root/correct.sha256sum"
  printf '%064d  %s\n' 0 "$(basename -- "$file")" >"$root/wrong.sha256sum"

  verify_sha256_sidecar "$file" "$root/correct.sha256sum" || {
    fail "correct SHA256 sidecar was rejected"
    return 1
  }
  if verify_sha256_sidecar "$file" "$root/wrong.sha256sum"; then
    fail "incorrect SHA256 sidecar was accepted"
    return 1
  fi
}

test_shell_integration_idempotent() {
  local root
  local bashrc
  local first_normalized
  local second_normalized

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  HOME="$root/home"
  PROXY_STATE_DIR="$HOME/.config/mipilot"
  MANAGER_INSTALLED_SCRIPT="$root/usr/local/lib/mipilot/mipilot"
  bashrc="$HOME/.bashrc"
  SHELL_RC_FILE="$bashrc"
  mkdir -p -- "$HOME"

  {
    printf 'export KEEP_BEFORE=1\n'
    printf '%s\n' "$LEGACY_SHELL_INTEGRATION_MARKER"
    printf 'if [ -f "$HOME/.config/mipilot/proxy-state.sh" ]; then\n'
    printf '  . "$HOME/.config/mipilot/proxy-state.sh"\n'
    printf 'fi\n'
    printf 'mihomo_menu() {\n'
    printf '  source "/old/mihomo-menu.sh"\n'
    printf '}\n'
    printf 'export KEEP_AFTER=1\n'
    printf '%s\n' "$LEGACY_MIHOMOCTL_BEGIN"
    printf 'old mihomoctl block\n'
    printf '%s\n' "$LEGACY_MIHOMOCTL_END"
    printf '%s\n' "$SHELL_INTEGRATION_BEGIN"
    printf 'stale managed block\n'
    printf '%s\n' "$SHELL_INTEGRATION_END"
  } >"$bashrc"

  ensure_shell_integration || return 1

  if grep -Fq -- "mihomo_menu" "$bashrc"; then
    fail "legacy mihomo_menu integration was not removed"
    return 1
  fi
  if grep -Fq -- "old mihomoctl block" "$bashrc"; then
    fail "legacy mihomoctl managed block was not removed"
    return 1
  fi
  assert_file_has_line "$bashrc" "export KEEP_BEFORE=1" "content before managed block" || return 1
  assert_file_has_line "$bashrc" "export KEEP_AFTER=1" "content after legacy block" || return 1
  assert_line_count "$bashrc" "$SHELL_INTEGRATION_BEGIN" 1 "managed block begin count" || return 1
  assert_line_count "$bashrc" "$SHELL_INTEGRATION_END" 1 "managed block end count" || return 1
  assert_line_count "$bashrc" "mipilot() {" 1 "mipilot function count" || return 1
  first_normalized="$(grep -v '^[[:space:]]*$' "$bashrc")"

  ensure_shell_integration || return 1

  if grep -Fq -- "mihomo_menu" "$bashrc"; then
    fail "legacy mihomo_menu integration returned after repeated execution"
    return 1
  fi
  assert_line_count "$bashrc" "$SHELL_INTEGRATION_BEGIN" 1 "repeated managed block begin count" || return 1
  assert_line_count "$bashrc" "$SHELL_INTEGRATION_END" 1 "repeated managed block end count" || return 1
  assert_line_count "$bashrc" "mipilot() {" 1 "repeated mipilot function count" || return 1
  second_normalized="$(grep -v '^[[:space:]]*$' "$bashrc")"
  assert_equal "$first_normalized" "$second_normalized" "repeated shell integration content" || return 1
}

test_proxy_state_restores_previous_environment() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  PROXY_STATE_DIR="$root/home/.config/mipilot"
  PROXY_STATE_FILE="$PROXY_STATE_DIR/proxy-state.sh"
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
  export http_proxy='http://company-proxy.example:8080'
  export NO_PROXY='internal.example'
  export MIHOMO_PROXY_ENABLED=0

  write_proxy_state 1 || return 1
  apply_proxy_state
  assert_equal "$PROXY_URL" "$http_proxy" "MiPilot HTTP proxy" || return 1
  assert_equal "$PROXY_URL" "$https_proxy" "MiPilot HTTPS proxy" || return 1

  disable_proxy_state || return 1
  assert_equal 'http://company-proxy.example:8080' "$http_proxy" "restored original HTTP proxy" || return 1
  assert_equal 'internal.example' "$NO_PROXY" "restored original NO_PROXY" || return 1
  [[ ! -v https_proxy ]] || fail "previously unset HTTPS proxy was not removed"
}

test_version_is_newer() {
  load_manager || return 1

  version_is_newer "1.20.0" "1.19.28" || {
    fail "upgrade version was not considered newer"
    return 1
  }
  if version_is_newer "1.20.0" "1.20.0"; then
    fail "equal versions must not be considered newer"
    return 1
  fi
  if version_is_newer "1.19.28" "1.20.0"; then
    fail "downgrade version must not be considered newer"
    return 1
  fi
  version_is_newer "1.0.0" "1.0.0-dev" || {
    fail "stable release was not considered newer than development build"
    return 1
  }
  if version_is_newer "1.0.0-dev" "1.0.0"; then
    fail "development build must not replace the matching stable release"
    return 1
  fi
  if version_is_newer "invalid" "1.0.0"; then
    fail "invalid semantic version was accepted"
    return 1
  fi
}

test_progress_runner_non_tty() {
  local output
  local status=0

  load_manager || return 1
  progress_fixture() {
    sleep 0.4
    printf 'result'
  }
  output="$(run_blocking "测试耗时操作" 3 progress_fixture 2>&1)" || status=$?
  assert_equal "0" "$status" "progress runner status" || return 1
  [[ $output == *"测试耗时操作..."* ]] || fail "non-TTY progress start was missing"
  [[ $output == *"result"* ]] || fail "progress command output was missing"
  [[ $output != *"Done"* ]] || fail "background completion noise leaked into output"
}

test_api_secret_not_in_arguments() {
  local root
  local args_file
  local header_file
  local header_path_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  args_file="$root/args"
  header_path_file="$root/header-path"
  # shellcheck disable=SC2034
  API_SECRET="secret-value"
  curl() {
    printf '%s\n' "$@" >"$args_file"
    while (( $# > 0 )); do
      if [[ $1 == -H && ${2:-} == @* ]]; then
        header_file="${2#@}"
        printf '%s\n' "$header_file" >"$header_path_file"
        grep -Fq 'Authorization: Bearer secret-value' "$header_file" || return 1
        shift 2
      else
        shift
      fi
    done
    printf '{}'
  }
  api_quick 'http://127.0.0.1:9090/configs' >/dev/null || return 1
  if grep -Fq 'secret-value' "$args_file"; then
    fail "API secret leaked into curl arguments"
    return 1
  fi
  header_file="$(cat "$header_path_file")"
  [[ -n ${header_file:-} && ! -e $header_file ]] || fail "temporary API header file was not removed"
}

test_secure_subscription_curl_config() {
  local root
  local config

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  config="$root/curl.conf"
  create_curl_url_config 'https://example.test/sub?token=abc' "$config" || return 1
  assert_file_has_line "$config" 'url = "https://example.test/sub?token=abc"' "subscription curl config" || return 1
  if create_curl_url_config $'https://example.test/sub\nheader=x' "$config"; then
    fail "subscription URL containing a newline was accepted"
    return 1
  fi
}

test_local_api_config_rendering() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'mixed-port: 7890' \
    "external-controller: '0.0.0.0:9090'" \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  render_local_api_config "$input_file" "$output_file" || return 1
  assert_file_has_line "$output_file" "external-controller: '127.0.0.1:9090'" "local API controller" || return 1
  if grep -Fq '0.0.0.0:9090' "$output_file"; then
    fail "public API controller was retained"
    return 1
  fi
  assert_line_count "$output_file" "external-controller: '127.0.0.1:9090'" 1 "API controller count" || return 1

  grep -v '^external-controller:' "$input_file" >"$root/without-controller.yaml"
  render_local_api_config "$root/without-controller.yaml" "$output_file" || return 1
  assert_line_count "$output_file" "external-controller: '127.0.0.1:9090'" 1 "appended API controller count" || return 1
}

test_local_proxy_config_rendering() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'mixed-port: 7890' \
    'allow-lan: true' \
    "bind-address: '*'" \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  render_local_proxy_config "$input_file" "$output_file" || return 1
  assert_file_has_line "$output_file" 'allow-lan: false' "disabled LAN proxy access" || return 1
  assert_file_has_line "$output_file" "bind-address: '127.0.0.1'" "local proxy bind address" || return 1
  if grep -Fq "bind-address: '*'" "$output_file"; then
    fail "public proxy bind address was retained"
    return 1
  fi
}

test_manager_candidate_validation_helpers() {
  local root
  local candidate
  local sidecar
  local hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  candidate="$root/mipilot"
  sidecar="$root/mipilot.sha256"
  printf '#!/usr/bin/env bash\nMANAGER_VERSION="1.2.3"\n' >"$candidate"
  assert_equal "1.2.3" "$(manager_version_from_script "$candidate")" "candidate manager version" || return 1
  hash="$(sha256sum "$candidate" | awk '{print $1}')"
  printf '%s  mipilot\n' "$hash" >"$sidecar"
  verify_sha256_sidecar "$candidate" "$sidecar" || fail "valid manager sidecar was rejected"
  printf '0%.0s' {1..64} >"$sidecar"
  if verify_sha256_sidecar "$candidate" "$sidecar"; then
    fail "invalid manager sidecar was accepted"
    return 1
  fi
}

test_online_manager_update_and_rollback() {
  local root
  local release_script
  local release_sidecar
  local hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  MANAGER_VERSION="1.0.0-dev"
  MANAGER_LIB_DIR="$root/usr/local/lib/mipilot"
  MANAGER_INSTALLED_SCRIPT="$MANAGER_LIB_DIR/mipilot"
  INSTALL_MARKER="$root/var/lib/mipilot/install-marker"
  ROLLBACK_DIR="$root/var/lib/mipilot/rollback"
  mkdir -p -- "$MANAGER_LIB_DIR" "$(dirname -- "$INSTALL_MARKER")"
  printf '#!/usr/bin/env bash\nMANAGER_VERSION="1.0.0-dev"\n' >"$MANAGER_INSTALLED_SCRIPT"
  chmod 755 "$MANAGER_INSTALLED_SCRIPT"
  printf 'version=1.0.0-dev\n' >"$INSTALL_MARKER"

  release_script="$root/release-mipilot"
  release_sidecar="$root/release-mipilot.sha256"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'MANAGER_VERSION="1.0.0"' \
    'MANAGER_INSTALLED_SCRIPT="/usr/local/lib/mipilot/mipilot"' >"$release_script"
  hash="$(sha256sum "$release_script" | awk '{print $1}')"
  printf '%s  mipilot\n' "$hash" >"$release_sidecar"

  download_file() {
    case "$1" in
      */mipilot) cp -- "$release_script" "$2" ;;
      */mipilot.sha256) cp -- "$release_sidecar" "$2" ;;
      *) return 1 ;;
    esac
  }
  read_line_or_back() {
    # shellcheck disable=SC2034
    INPUT_LINE="y"
    return 0
  }
  ensure_sudo_access() {
    return 0
  }
  run_cancellable_named() {
    shift 2
    "$@"
  }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == install && ${2:-} == -d ]]; then
      mkdir -p -- "${@: -1}"
      return 0
    fi
    run_as_mock_sudo "$@"
  }
  systemctl() {
    return 0
  }

  online_update_manager || return 1
  grep -Fq 'MANAGER_VERSION="1.0.0"' "$MANAGER_INSTALLED_SCRIPT" || fail "manager update did not install candidate"
  grep -Fq 'MANAGER_VERSION="1.0.0-dev"' "$ROLLBACK_DIR/manager/mipilot" || fail "manager rollback copy was not saved"
  assert_equal "1" "$MANAGER_SHOULD_EXIT" "manager update exit flag" || return 1

  MANAGER_SHOULD_EXIT=0
  manual_rollback_manager || return 1
  grep -Fq 'MANAGER_VERSION="1.0.0-dev"' "$MANAGER_INSTALLED_SCRIPT" || fail "manager rollback did not restore previous script"
  assert_equal "1" "$MANAGER_SHOULD_EXIT" "manager rollback exit flag"
}

test_subscription_activation_marker_rollback() {
  local root
  local status=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'https://old.example/sub' >"$SUBSCRIPTION_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }
  download_and_apply_subscription() {
    return 1
  }

  activate_subscription 'https://new.example/sub' >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || {
    fail "failed subscription activation unexpectedly succeeded"
    return 1
  }
  assert_equal 'https://old.example/sub' "$(head -n 1 "$SUBSCRIPTION_FILE")" "active subscription marker rollback" || return 1
}

test_reset_runtime_state() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  SUBSCRIPTION_LIST_FILE="$CONFIG_DIR/subscriptions.list"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  TUN_BYPASS_STATE_FILE="$CONFIG_DIR/tun-bypass-ports.conf"
  # shellcheck disable=SC2034
  TUN_BYPASS_SERVICE_FILE="$root/etc/systemd/system/mipilot-tun-bypass.service"
  PROXY_STATE_DIR="$root/home/.config/mipilot"
  PROXY_STATE_FILE="$PROXY_STATE_DIR/proxy-state.sh"
  mkdir -p -- "$CONFIG_DIR" "$PROXY_STATE_DIR"
  printf 'old\n' >"$SUBSCRIPTION_FILE"
  printf 'old\n' >"$SUBSCRIPTION_LIST_FILE"
  printf 'old\n' >"$REGION_STATE_FILE"
  printf 'Proxy\n' >"$REGION_PARENT_FILE"
  printf 'true\n' >"$TUN_STATE_FILE"
  printf 'tcp:8080\n' >"$TUN_BYPASS_STATE_FILE"
  printf 'export MIHOMO_PROXY_ENABLED=1\n' >"$PROXY_STATE_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }
  run_tun_routing_action() {
    return 0
  }

  clear_manager_runtime_state || return 1
  assert_not_exists "$SUBSCRIPTION_FILE" || return 1
  assert_not_exists "$REGION_STATE_FILE" || return 1
  assert_not_exists "$REGION_PARENT_FILE" || return 1
  assert_not_exists "$TUN_BYPASS_STATE_FILE" || return 1
  assert_equal "" "$(cat "$SUBSCRIPTION_LIST_FILE")" "empty subscription list after reset" || return 1
  assert_equal "false" "$(cat "$TUN_STATE_FILE")" "disabled TUN state after reset" || return 1
  grep -Fq 'MIHOMO_PROXY_ENABLED=0' "$PROXY_STATE_FILE" || fail "terminal proxy state was not disabled"
}

test_uninstall_stops_before_delete() {
  local root
  local delete_attempted=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  USER_HOME="$root/home"
  PROXY_STATE_DIR="$USER_HOME/.config/mipilot"
  PROXY_STATE_FILE="$PROXY_STATE_DIR/proxy-state.sh"
  mkdir -p -- "$PROXY_STATE_DIR"

  service_exists() {
    return 0
  }
  write_proxy_state() {
    return 0
  }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == systemctl && ${2:-} == disable ]]; then
      return 1
    fi
    if [[ ${1:-} == rm ]]; then
      delete_attempted=1
    fi
    return 0
  }

  if remove_managed_installation 0 >/dev/null 2>&1; then
    fail "uninstall succeeded even though service stop failed"
    return 1
  fi
  assert_equal "0" "$delete_attempted" "no deletion after failed service stop" || return 1
}

test_rule_policy_parsing_edges() {
  local root
  local config_file
  local actual

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  config_file="$root/config.yaml"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: Proxy' \
    '    type: select' \
    '  - name: Backup' \
    '    type: select' \
    '  - name: Unused' \
    '    type: select' \
    'rules:' \
    '  - "DOMAIN-SUFFIX,example.com,Proxy"' \
    "  - 'IP-CIDR,1.1.1.0/24,Backup,no-resolve'" \
    '  - MATCH,DIRECT' >"$config_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  actual="$(list_rule_selector_names "$config_file" | sort)"
  assert_equal $'Backup\nProxy' "$actual" "quoted and no-resolve rule policies"
}

test_multiple_rule_selectors_require_choice() {
  local root
  local response
  local choice_requested=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: Alpha' \
    '    type: select' \
    '  - name: Beta' \
    '    type: select' \
    'rules:' \
    '  - DOMAIN-SUFFIX,alpha.example,Alpha' \
    '  - MATCH,Beta' >"$CONFIG_FILE"
  response='{"proxies":{"Alpha":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"Beta":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }
  choose_item() {
    choice_requested=1
    # shellcheck disable=SC2034
    SELECTED='Beta'
  }

  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal '1' "$choice_requested" "ambiguous rule entry choice prompt" || return 1
  assert_equal 'Beta' "$REGION_PARENT" "explicitly selected rule entry"
}

test_stale_saved_parent_is_ignored() {
  local root
  local response

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'OldParent' >"$REGION_PARENT_FILE"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: OldParent' \
    '    type: select' \
    '  - name: Proxy' \
    '    type: select' \
    'rules:' \
    '  - MATCH,Proxy' >"$CONFIG_FILE"
  response='{"proxies":{"OldParent":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"Proxy":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }

  ensure_region_parent "$response" >/dev/null || return 1
  assert_equal 'Proxy' "$REGION_PARENT" "stale unreferenced saved parent"
}

test_inline_rules_rejected_for_managed_outlet() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'proxy-groups: []' \
    'rules: ["MATCH,DIRECT"]' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  if render_managed_rule_outlet "$input_file" "$output_file" >/dev/null 2>&1; then
    fail "inline rules unexpectedly accepted"
    return 1
  fi
}

test_region_metadata_restored_when_config_commit_fails() {
  local root
  local candidate_state
  local backup_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  MIHOMO_BIN="$root/mihomo"
  REGION_PARENT='NewParent'
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'mode: rule' >"$CONFIG_FILE"
  printf '%s\n' 'old;MiPilot-旧;Old;url-test' >"$REGION_STATE_FILE"
  printf '%s\n' 'OldParent' >"$REGION_PARENT_FILE"
  candidate_state="$root/candidate-state"
  backup_file="$root/config-backup"
  printf '%s\n' 'new;MiPilot-新;New;fallback' >"$candidate_state"
  cp -- "$CONFIG_FILE" "$backup_file"

  sudo() {
    run_as_mock_sudo "$@"
  }
  apply_region_groups_to_config() {
    cp -- "$1" "$2"
  }
  run_cancellable_named() {
    return 0
  }
  create_config_backup() {
    printf '%s\n' "$backup_file"
  }
  atomic_install_file() {
    local source_file="$2"
    local destination="$3"
    if [[ $destination == "$CONFIG_FILE" ]]; then return 1; fi
    mkdir -p -- "$(dirname -- "$destination")"
    cp -- "$source_file" "$destination"
  }

  if apply_region_group_state "$candidate_state" test "unexpected" >/dev/null 2>&1; then
    fail "region state apply succeeded after config commit failure"
    return 1
  fi
  assert_equal 'old;MiPilot-旧;Old;url-test' "$(cat "$REGION_STATE_FILE")" "restored region state" || return 1
  assert_equal 'OldParent' "$(cat "$REGION_PARENT_FILE")" "restored region parent"
}

test_tun_state_failure_preserves_config() {
  local root
  local original_hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  MIHOMO_BIN="$root/mihomo"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'tun:' '  enable: false' >"$CONFIG_FILE"
  original_hash="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"

  sudo() {
    run_as_mock_sudo "$@"
  }
  run_cancellable_named() {
    return 0
  }
  create_config_backup() {
    printf '%s\n' "$root/backup"
  }
  save_tun_state() {
    return 1
  }

  if apply_tun_setting true "开启" >/dev/null 2>&1; then
    fail "TUN apply succeeded after state write failure"
    return 1
  fi
  assert_equal "$original_hash" "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" "config unchanged after TUN state failure"
}

test_tun_restart_failure_restores_state() {
  local root
  local backup_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  MIHOMO_BIN="$root/mihomo"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'tun:' '  enable: false' >"$CONFIG_FILE"
  printf '%s\n' 'false' >"$TUN_STATE_FILE"
  backup_file="$root/config-backup"
  cp -- "$CONFIG_FILE" "$backup_file"

  sudo() {
    run_as_mock_sudo "$@"
  }
  run_cancellable_named() {
    return 0
  }
  create_config_backup() {
    printf '%s\n' "$backup_file"
  }
  run_blocking() {
    return 1
  }
  rollback_config() {
    cp -- "$backup_file" "$CONFIG_FILE"
  }

  if apply_tun_setting true "开启" >/dev/null 2>&1; then
    fail "TUN apply succeeded after restart failure"
    return 1
  fi
  assert_equal 'false' "$(cat "$TUN_STATE_FILE")" "restored TUN state after restart failure" || return 1
  assert_file_has_line "$CONFIG_FILE" '  enable: false' "restored TUN config"
}

test_tun_runtime_api_mismatch_fails() {
  load_manager || return 1
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":false}}'
  }

  if verify_tun_runtime_network >/dev/null 2>&1; then
    fail "TUN runtime check accepted disabled API state"
    return 1
  fi
}

test_tun_runtime_missing_return_rules_fails() {
  load_manager || return 1
  API='http://127.0.0.1:9090'

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true}}'
  }
  tun_routing_rules_ready() {
    return 1
  }

  if verify_tun_runtime_network >/dev/null 2>&1; then
    fail "TUN runtime check accepted missing return routing rules"
    return 1
  fi
}

test_tun_public_probe_failure_is_warning() {
  local output

  load_manager || return 1
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'
  SSH_CONNECTION=''

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true}}'
  }
  tun_routing_rules_ready() {
    return 0
  }
  ip() {
    if [[ ${1:-} == -4 ]]; then
      printf '%s\n' 'default via 192.0.2.1 dev eth0' 'default via 198.51.100.1 dev eth1'
    else
      return 0
    fi
  }
  curl() {
    return 1
  }

  output="$(verify_tun_runtime_network)" || return 1
  [[ $output == *'检测到 2 条 IPv4 默认路由'* ]] || return 1
  [[ $output == *'公网连通性探测失败'* ]] || return 1
}

test_tun_ssh_return_route_failure() {
  load_manager || return 1
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'
  # shellcheck disable=SC2034
  SSH_CONNECTION='203.0.113.10 50000 192.0.2.10 22'

  refresh_api_config() {
    # shellcheck disable=SC2034
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true}}'
  }
  tun_routing_rules_ready() {
    return 0
  }
  ip() {
    if [[ ${1:-} == route && ${2:-} == get && ${3:-} == 203.0.113.10 ]]; then return 1; fi
    if [[ ${1:-} == -4 ]]; then printf '%s\n' 'default via 192.0.2.1 dev eth0'; fi
    return 0
  }

  if verify_tun_runtime_network >/dev/null 2>&1; then
    fail "TUN runtime check accepted missing SSH return route"
    return 1
  fi
}

run_test() {
  local name="$1"
  local function_name="$2"

  printf '[RUN ] %s\n' "$name"
  if ("$function_name"); then
    printf '[PASS] %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf '[FAIL] %s\n' "$name" >&2
    FAILED=$((FAILED + 1))
  fi
}

run_test "bash -n" test_bash_syntax
run_test "manager release version" test_manager_release_version
run_test "testing source guard" test_source_testing_guard
run_test "source preserves enabled shell options" test_source_preserves_enabled_shell_options
run_test "dependency install survives partial APT update failure" test_dependency_install_continues_after_partial_apt_update
run_test "local asset discovery" test_find_local_assets
run_test "configuration backup pruning" test_prune_config_backups
run_test "rollback expiration" test_cleanup_expired_rollbacks
run_test "installation state detection" test_detect_install_state
run_test "MiPilot config migration and materialization" test_mipilot_config_migration_and_materialization
run_test "configuration backup includes MiPilot settings" test_config_backup_bundles_mipilot_settings
run_test "TUN preserves non-TUN state" test_tun_render_preserves_non_tun_state
run_test "runtime marker precedence" test_runtime_mode_marker_precedence
run_test "runtime backend dispatch" test_runtime_backend_dispatch
run_test "manual install default" test_install_runtime_choice_defaults_manual
run_test "service TUN routing lifecycle" test_service_unit_reconciles_tun_routing
run_test "TUN routing action lock" test_tun_routing_action_uses_independent_lock
run_test "manager lock release" test_manager_lock_release
run_test "lock release preserves caller stderr" test_lock_release_preserves_stderr
run_test "curl download follows current system route" test_download_uses_curl_without_forced_proxy
run_test "restored TUN state reconciliation" test_reconcile_tun_runtime_state
run_test "TUN state sync failure restores sidecar" test_tun_state_sync_failure_restores_sidecar
run_test "native Mihomo TUN routing" test_render_tun_native_routing
run_test "legacy TUN bypass cleanup" test_cleanup_legacy_tun_bypass
run_test "connection-based TUN return routing" test_tun_routing_rules_are_connection_based
run_test "mode switch persistence" test_mode_switch_persists_config
run_test "selected-node persistence rendering" test_render_store_selected_config
run_test "custom region group rendering" test_custom_region_group_rendering
run_test "rule mode managed-group selection" test_rule_mode_selects_managed_group
run_test "dynamic region parent selection" test_dynamic_region_parent_selection
run_test "unreferenced selector falls back to managed outlet" test_unreferenced_selector_uses_managed_rule_outlet
run_test "custom region group without subscription groups" test_custom_region_group_without_subscription_groups
run_test "managed region strategy refresh" test_region_group_strategy_refresh
run_test "exact managed region deletion" test_remove_region_group_exact_match
run_test "managed rule outlet without selector" test_missing_selector_uses_managed_rule_outlet
run_test "managed rule outlet keeps subscription groups" test_managed_outlet_keeps_subscription_groups
run_test "minimal direct configuration" test_render_minimal_config
run_test "SHA256 sidecar verification" test_verify_sha256_sidecar
run_test "idempotent shell integration" test_shell_integration_idempotent
run_test "proxy environment restoration" test_proxy_state_restores_previous_environment
run_test "manager version comparison" test_version_is_newer
run_test "progress runner non-TTY behavior" test_progress_runner_non_tty
run_test "API secret argument protection" test_api_secret_not_in_arguments
run_test "secure subscription curl config" test_secure_subscription_curl_config
run_test "local API config rendering" test_local_api_config_rendering
run_test "local proxy config rendering" test_local_proxy_config_rendering
run_test "manager candidate validation helpers" test_manager_candidate_validation_helpers
run_test "online manager update and rollback" test_online_manager_update_and_rollback
run_test "subscription activation marker rollback" test_subscription_activation_marker_rollback
run_test "reset runtime state" test_reset_runtime_state
run_test "uninstall stop-before-delete guard" test_uninstall_stops_before_delete
run_test "rule policy parsing edge cases" test_rule_policy_parsing_edges
run_test "multiple rule selectors require explicit choice" test_multiple_rule_selectors_require_choice
run_test "stale saved rule parent ignored" test_stale_saved_parent_is_ignored
run_test "inline rules rejected for managed outlet" test_inline_rules_rejected_for_managed_outlet
run_test "region metadata rollback on config failure" test_region_metadata_restored_when_config_commit_fails
run_test "TUN state failure preserves config" test_tun_state_failure_preserves_config
run_test "TUN restart failure restores state" test_tun_restart_failure_restores_state
run_test "TUN API mismatch fails health check" test_tun_runtime_api_mismatch_fails
run_test "TUN return routing rules are required" test_tun_runtime_missing_return_rules_fails
run_test "TUN public probe failure warns" test_tun_public_probe_failure_is_warning
run_test "TUN SSH return route failure" test_tun_ssh_return_route_failure

printf '\nResult: %s passed, %s failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
