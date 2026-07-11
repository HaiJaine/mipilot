#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
MANAGER_SCRIPT="${PROJECT_DIR}/mipilot"

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
}

test_bash_syntax() {
  bash -n "$MANAGER_SCRIPT"
}

test_manager_release_version() {
  load_manager || return 1
  assert_equal "1.0.0" "$MANAGER_VERSION" "manager release version"
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

test_find_local_assets() {
  local root
  local country_name
  local geosite_name

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1

  mkdir -p -- "$root/lower" "$root/upper" "$root/wrong-arch"

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
  assert_equal "$root/lower/mihomo-linux-amd64-v1.20.1.gz" "$LOCAL_MIHOMO_ARCHIVE" "highest amd64 version" || return 1
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

  printf 'country\n' >"$root/wrong-arch/country.mmdb"
  printf 'geosite\n' >"$root/wrong-arch/geosite.dat"
  : >"$root/wrong-arch/mihomo-linux-arm64-v3.0.0.gz"
  : >"$root/wrong-arch/mihomo-linux-amd64-v3.0.gz"

  if find_local_assets "$root/wrong-arch"; then
    fail "wrong-architecture or malformed archives must be rejected"
    return 1
  fi
  assert_equal "" "$LOCAL_MIHOMO_ARCHIVE" "rejected archive selection" || return 1
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

test_detect_public_service_ports() {
  local output

  load_manager || return 1
  ss() {
    case " $* " in
      *" -ltn "*)
        printf '%s\n' \
          'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*' \
          'LISTEN 0 128 127.0.0.1:9090 0.0.0.0:*' \
          'LISTEN 0 128 [::]:443 [::]:*'
        ;;
      *" -lun "*)
        printf '%s\n' 'UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*'
        ;;
    esac
  }
  docker() {
    if [[ ${1:-} == ps && ${2:-} == --format ]]; then
      printf '%s\n' '0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp, 127.0.0.1:9000->9000/udp'
    fi
    return 0
  }
  timeout() {
    shift
    "$@"
  }
  sudo() {
    run_as_mock_sudo "$@"
  }

  output="$(detect_public_service_ports)" || return 1
  assert_equal $'tcp:22\ntcp:443\ntcp:8080\nudp:5353\nudp:9000' "$output" "detected public service ports"
}

test_sync_tun_bypass_rules() {
  local root
  local rules_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  TUN_BYPASS_STATE_FILE="$root/tun-bypass-ports.conf"
  rules_file="$root/rules"
  printf 'tcp:8080\n' >"$TUN_BYPASS_STATE_FILE"
  : >"$rules_file"

  sudo() {
    run_as_mock_sudo "$@"
  }
  ip() {
    if [[ ${1:-} == rule && ${2:-} == show ]]; then
      cat "$rules_file"
    elif [[ ${1:-} == rule && ${2:-} == add ]]; then
      printf '%s: from all ipproto %s sport %s lookup main\n' "$4" "$6" "$8" >>"$rules_file"
    elif [[ ${1:-} == rule && ${2:-} == del ]]; then
      : >"$rules_file"
    else
      return 1
    fi
  }
  tun_config_value() {
    printf 'true\n'
  }

  sync_tun_bypass_rules || return 1
  grep -Fq '8990: from all ipproto tcp sport 8080 lookup main' "$rules_file" || return 1
  sync_tun_bypass_rules || return 1
  assert_equal "1" "$(wc -l <"$rules_file" | tr -d ' ')" "idempotent bypass rule count" || return 1

  tun_config_value() {
    printf 'false\n'
  }
  sync_tun_bypass_rules || return 1
  assert_equal "0" "$(wc -l <"$rules_file" | tr -d ' ')" "removed bypass rule count"
}

test_render_tun_server_compatibility() {
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
  assert_file_has_line "$output_file" "  auto-redirect: false" "server-compatible auto-redirect" || return 1
  assert_file_has_line "$output_file" "  auto-detect-interface: true" "enabled interface detection"
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
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  TUN_BYPASS_STATE_FILE="$CONFIG_DIR/tun-bypass-ports.conf"
  PROXY_STATE_DIR="$root/home/.config/mipilot"
  PROXY_STATE_FILE="$PROXY_STATE_DIR/proxy-state.sh"
  mkdir -p -- "$CONFIG_DIR" "$PROXY_STATE_DIR"
  printf 'old\n' >"$SUBSCRIPTION_FILE"
  printf 'old\n' >"$SUBSCRIPTION_LIST_FILE"
  printf 'old\n' >"$REGION_STATE_FILE"
  printf 'true\n' >"$TUN_STATE_FILE"
  printf 'export MIHOMO_PROXY_ENABLED=1\n' >"$PROXY_STATE_FILE"

  sudo() {
    run_as_mock_sudo "$@"
  }

  clear_manager_runtime_state || return 1
  assert_not_exists "$SUBSCRIPTION_FILE" || return 1
  assert_not_exists "$REGION_STATE_FILE" || return 1
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
run_test "local asset discovery" test_find_local_assets
run_test "configuration backup pruning" test_prune_config_backups
run_test "rollback expiration" test_cleanup_expired_rollbacks
run_test "installation state detection" test_detect_install_state
run_test "manager lock release" test_manager_lock_release
run_test "lock release preserves caller stderr" test_lock_release_preserves_stderr
run_test "curl download follows current system route" test_download_uses_curl_without_forced_proxy
run_test "public service port detection" test_detect_public_service_ports
run_test "TUN bypass rule synchronization" test_sync_tun_bypass_rules
run_test "server-compatible TUN rendering" test_render_tun_server_compatibility
run_test "minimal direct configuration" test_render_minimal_config
run_test "SHA256 sidecar verification" test_verify_sha256_sidecar
run_test "idempotent shell integration" test_shell_integration_idempotent
run_test "manager version comparison" test_version_is_newer
run_test "progress runner non-TTY behavior" test_progress_runner_non_tty
run_test "API secret argument protection" test_api_secret_not_in_arguments
run_test "secure subscription curl config" test_secure_subscription_curl_config
run_test "local API config rendering" test_local_api_config_rendering
run_test "manager candidate validation helpers" test_manager_candidate_validation_helpers
run_test "online manager update and rollback" test_online_manager_update_and_rollback
run_test "subscription activation marker rollback" test_subscription_activation_marker_rollback
run_test "reset runtime state" test_reset_runtime_state
run_test "uninstall stop-before-delete guard" test_uninstall_stops_before_delete

printf '\nResult: %s passed, %s failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
