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

assert_yaml_equal() {
  local path="$1"
  local expression="$2"
  local expected="$3"
  local description="$4"
  local actual

  actual="$("${MIPILOT_YQ_BIN:?test yq path is required}" --yaml-fix-merge-anchor-to-spec eval -r "$expression" "$path")" || return 1
  assert_equal "$expected" "$actual" "$description"
}

run_as_mock_sudo() {
  local create_directories=0
  local paths=()

  while [[ ${1:-} == -n ]]; do shift; done
  [[ ${1:-} == -v ]] && return 0
  if [[ ${1:-} == install && ${2:-} == -d ]]; then
    shift 2
    create_directories=1
    while (( $# > 0 )); do
      case "$1" in
        -m) shift 2 ;;
        --) shift ;;
        -*) shift ;;
        *) paths+=("$1"); shift ;;
      esac
    done
    (( create_directories == 1 && ${#paths[@]} > 0 )) || return 1
    mkdir -p -- "${paths[@]}"
    return
  fi
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
  SERVICE_USER="mipilot-test-account-does-not-exist"
  SERVICE_GROUP="mipilot-test-account-does-not-exist"
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
  assert_equal "1.0.2" "$MANAGER_VERSION" "manager release version"
}

test_strategy_group_ui_labels() {
  grep -Fq '  4) 策略组管理' "$MANAGER_SCRIPT" || { fail "main menu strategy group label is missing"; return 1; }
  grep -Fq '================ 策略组管理 ==================' "$MANAGER_SCRIPT" || { fail "strategy group page title is missing"; return 1; }
  grep -Fq '选择订阅的主要规则出口:' "$MANAGER_SCRIPT" || { fail "friendly rule entry label is missing"; return 1; }
  if grep -Fq '地区分组管理' "$MANAGER_SCRIPT"; then
    fail "legacy region group management label remains"
    return 1
  fi
  if grep -Fq '将挂载到' "$MANAGER_SCRIPT"; then
    fail "internal mounting terminology remains"
    return 1
  fi
  if grep -Fq '分组方式' "$MANAGER_SCRIPT"; then
    fail "legacy group type terminology remains"
    return 1
  fi
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

test_linux_input_normalization() {
  local output
  local read_count=0

  load_manager || return 1

  read_line_or_back "" <<< $'value\r' || return 1
  assert_equal "value" "$INPUT_LINE" "carriage return cleanup" || return 1
  assert_equal "/tmp/path with spaces" \
    "$(trim_input_whitespace $' \t/tmp/path with spaces \r')" \
    "surrounding whitespace cleanup" || return 1

  read_line_or_back() {
    INPUT_LINE=$' 09\r'
    return 0
  }
  read_choice_or_back "" || return 1
  assert_equal "9" "$MENU_CHOICE" "decimal menu choice normalization" || return 1

  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then
      INPUT_LINE=""
    else
      INPUT_LINE="2"
    fi
    return 0
  }
  read_choice_or_back "" || return 1
  assert_equal "2" "$MENU_CHOICE" "Enter keeps the current menu active" || return 1
  assert_equal "2" "$read_count" "menu prompt count after Enter" || return 1

  read_line_or_back() {
    return 130
  }
  if read_choice_or_back ""; then
    fail "Esc did not return from the current menu"
    return 1
  fi

  read_line_or_back() {
    INPUT_LINE="999999999999999999999999"
    return 0
  }
  if output="$(choose_item "test" one two three 2>&1)"; then
    fail "oversized numeric menu choice was accepted"
    return 1
  fi
  grep -Fq '编号无效.' <<<"$output" || fail "oversized numeric menu choice did not fail cleanly"

  read_line_or_back() {
    INPUT_LINE="1 0"
    return 0
  }
  if choose_item "test" one two three four five six seven eight nine ten >/dev/null 2>&1; then
    fail "menu choice containing internal whitespace was accepted"
    return 1
  fi

  grep -Fq '编号后按 Enter' "$MANAGER_SCRIPT" || fail "menu prompts do not explain how to submit a choice"
  if grep -Fq 'Enter继续' "$MANAGER_SCRIPT"; then
    fail "ambiguous Enter continuation prompt remains"
    return 1
  fi
  if grep -Fq '回车返回' "$MANAGER_SCRIPT"; then
    fail "legacy Enter-to-return prompt remains"
    return 1
  fi
  if grep -Eq '^[[:space:]]*clear[[:space:]]*$' "$MANAGER_SCRIPT"; then
    fail "unguarded clear command remains"
    return 1
  fi
  assert_equal "" "$(TERM= clear_screen)" "non-TTY screen clear output" || return 1

  read_count=0
  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then INPUT_LINE="maybe"; else INPUT_LINE=" y "; fi
    return 0
  }
  read_yes_no_or_back "" no >/dev/null || return 1
  assert_equal "yes" "$CONFIRM_RESULT" "validated yes/no answer" || return 1
  assert_equal "2" "$read_count" "invalid yes/no answer retry count" || return 1

  read_line_or_back() {
    INPUT_LINE=""
    return 0
  }
  read_yes_no_or_back "" no || return 1
  assert_equal "no" "$CONFIRM_RESULT" "empty confirmation uses displayed default"
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
  printf 'yq\n' >"$root/lower/yq_linux_amd64"
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
  assert_equal "$root/lower/yq_linux_amd64" "$LOCAL_YQ_SOURCE" "yq binary" || return 1

  printf 'country\n' >"$root/upper/Country.mmdb"
  printf 'geosite\n' >"$root/upper/GeoSite.dat"
  printf 'yq\n' >"$root/upper/yq_linux_amd64"
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
  printf 'yq\n' >"$root/plain/yq_linux_amd64"
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
  printf 'yq\n' >"$root/wrong-arch/yq_linux_amd64"
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
  assert_equal "true" "$(cat "$TUN_STATE_FILE")" "materialized TUN state" || return 1

  installed_runtime_mode() {
    printf 'service\n'
  }
  ensure_service_runtime_permissions() {
    touch "$root/service-permissions-preserved"
  }
  materialize_mipilot_state || return 1
  assert_exists "$root/service-permissions-preserved"
}

test_reconcile_skips_semantic_only_changes() {
  local root
  local original_hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  BACKUP_DIR="$CONFIG_DIR/backups"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf '%s\n' 'mode: rule' 'tun: {enable: false}' >"$CONFIG_FILE"
  printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    '  "runtime": {"type": "service"},' \
    '  "mode": "rule",' \
    '  "tun": {"enabled": false},' \
    '  "subscription": {"active": "", "items": []},' \
    '  "rule_selection": {"parent": "Proxy", "group": "Proxy"},' \
    '  "global_selection": {"node": ""},' \
    '  "selector_selections": {},' \
    '  "custom_groups": []' \
    '}' >"$MANAGER_CONFIG_FILE"
  original_hash="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"

  sudo() {
    run_as_mock_sudo "$@"
  }
  render_mode_config() {
    cp -- "$1" "$2"
  }
  render_tun_config() {
    cp -- "$1" "$2"
  }
  apply_rule_selector_to_config() {
    printf '%s\n' 'tun:' '  enable: false' 'mode: "rule"' >"$2"
  }
  runtime_is_active() {
    return 0
  }
  restart_mihomo_with_progress() {
    touch "$root/restarted"
    return 0
  }

  reconcile_runtime_config_from_mipilot || return 1
  assert_not_exists "$root/restarted" || return 1
  assert_not_exists "$BACKUP_DIR" || return 1
  assert_equal "$original_hash" "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" \
    "semantic-only startup reconciliation preserves config"
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

test_privileged_temp_copy_uses_caller_owned_output() {
  local root
  local source_file
  local temporary_file
  local sudo_command=""

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  source_file="$root/protected-source"
  temporary_file="$root/caller-temp"
  printf '%s\n' 'protected state' >"$source_file"
  : >"$temporary_file"

  sudo() {
    sudo_command="${1:-}"
    run_as_mock_sudo "$@"
  }

  copy_privileged_file_to_temp "$source_file" "$temporary_file" || return 1
  assert_equal 'cat' "$sudo_command" "privileged snapshot read command" || return 1
  assert_equal 'protected state' "$(cat "$temporary_file")" "privileged snapshot content" || return 1
  rm -f -- "$temporary_file" || fail "caller-owned privileged snapshot could not be removed"
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

test_runtime_mode_switch_persists_manager_config() {
  local mock_mode="service"
  local installed_mode=""
  local persisted_mode=""

  load_manager || return 1
  installed_runtime_mode() { printf '%s\n' "$mock_mode"; }
  current_core_version() { printf '1.0.0\n'; }
  run_blocking() { return 0; }
  save_component_rollback() { return 0; }
  manual_stop() { return 0; }
  write_service_unit() { return 0; }
  wait_for_mihomo_stable() { return 0; }
  restore_manual_runtime_permissions() { return 0; }
  remove_managed_service_account() { return 0; }
  restore_component_rollback() { return 0; }
  ensure_service_account() { return 0; }
  ensure_service_runtime_permissions() { return 0; }
  install_manager_files() {
    installed_mode="$1"
    mock_mode="$1"
  }
  update_mipilot_runtime() {
    persisted_mode="$1"
  }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    [[ ${1:-} == -v ]] && return 0
    case "${1:-} ${2:-}" in
      systemctl\ *|rm\ *) return 0 ;;
      *) "$@" ;;
    esac
  }

  switch_runtime_mode >/dev/null || return 1
  assert_equal "manual" "$installed_mode" "service-to-manual installed mode" || return 1
  assert_equal "manual" "$persisted_mode" "service-to-manual persisted mode" || return 1

  installed_mode=""
  persisted_mode=""
  switch_runtime_mode >/dev/null || return 1
  assert_equal "service" "$installed_mode" "manual-to-service installed mode" || return 1
  assert_equal "service" "$persisted_mode" "manual-to-service persisted mode"
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
  ensure_service_account() { return 0; }
  ensure_service_runtime_permissions() { return 0; }

  write_service_unit || return 1
  assert_file_has_line "$SERVICE_FILE" "User=${SERVICE_USER}" "dedicated Mihomo service user" || return 1
  assert_file_has_line "$SERVICE_FILE" "ProtectSystem=strict" "Mihomo service filesystem protection" || return 1
  assert_file_has_line "$SERVICE_FILE" "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW" "minimal Mihomo capabilities" || return 1
  assert_file_has_line "$SERVICE_FILE" "ReadOnlyPaths=${CONFIG_FILE}" "read-only Mihomo primary config" || return 1
  if grep -Fq 'CAP_NET_BIND_SERVICE' "$SERVICE_FILE"; then
    fail "unnecessary low-port capability remains"
    return 1
  fi
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
  local dns_output_file
  local disabled_output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  sudo() {
    run_as_mock_sudo "$@"
  }
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  dns_output_file="$root/output-dns.yaml"
  disabled_output_file="$root/output-disabled.yaml"
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
  assert_yaml_equal "$output_file" '.tun.enable' true "enabled TUN" || return 1
  assert_yaml_equal "$output_file" '.tun."auto-route"' true "enabled auto-route" || return 1
  assert_yaml_equal "$output_file" '.tun."auto-redirect"' true "enabled automatic redirect" || return 1
  assert_yaml_equal "$output_file" '.tun."auto-detect-interface"' true "enabled interface detection" || return 1
  assert_yaml_equal "$output_file" '.tun."strict-route"' false "server-compatible strict route" || return 1
  assert_yaml_equal "$output_file" '.tun."route-exclude-address"[] | select(. == "192.168.0.0/16")' '192.168.0.0/16' "LAN route exclusion" || return 1
  assert_yaml_equal "$output_file" '.tun."route-exclude-address"[] | select(. == "100.64.0.0/10")' '100.64.0.0/10' "CGNAT route exclusion" || return 1
  assert_yaml_equal "$output_file" '.rules[0]' 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve' "local safety rule priority" || return 1
  assert_yaml_equal "$output_file" '.rules[] | select(. == "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve")' 'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve' "CGNAT safety rule" || return 1
  assert_yaml_equal "$output_file" '.dns.enable' true "default Mihomo DNS enabled" || return 1
  assert_yaml_equal "$output_file" '.dns."enhanced-mode"' 'redir-host' "default DNS enhanced mode" || return 1
  assert_yaml_equal "$output_file" '.tun."dns-hijack"[] | select(. == "any:53")' 'any:53' "default DNS hijack" || return 1

  "$YQ_BIN" eval '.dns.enable = true | .tun."dns-hijack" = ["udp://any:5353"]' "$input_file" >"$root/input-dns.yaml" || return 1
  render_tun_config "$root/input-dns.yaml" "$dns_output_file" true || return 1
  assert_yaml_equal "$dns_output_file" '.tun."dns-hijack"[] | select(. == "any:53")' 'any:53' "DNS hijack with enabled Mihomo DNS" || return 1
  assert_yaml_equal "$dns_output_file" '.tun."dns-hijack"[] | select(. == "udp://any:5353")' 'udp://any:5353' "custom DNS hijack preserved while enabling" || return 1

  render_tun_config "$root/input-dns.yaml" "$disabled_output_file" false || return 1
  assert_yaml_equal "$disabled_output_file" '.tun."dns-hijack"[] | select(. == "udp://any:5353")' 'udp://any:5353' "custom DNS hijack preserved while disabling" || return 1
  assert_yaml_equal "$disabled_output_file" '.rules[0]' 'MATCH,DIRECT' "disabled TUN does not prepend routing rules" || return 1
  assert_yaml_equal "$disabled_output_file" '.tun."route-exclude-address" == null' true "disabled TUN does not add route exclusions"
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
  local remaining

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  STATE_DIR="$root/state"
  TUN_ROUTING_STATE_FILE="$STATE_DIR/tun-routing.state"
  ip_rules_file="$root/ip-rules"
  table_file="$root/nft-table"
  mkdir -p -- "$STATE_DIR"
  printf '%s\n' \
    'version=1' \
    'table=mipilot_tun' \
    'priority=8989' \
    'mark=0x40000000' >"$TUN_ROUTING_STATE_FILE"
  printf '%s\n' \
    '8989: from all fwmark 0x40000000/0x40000000 lookup main' \
    '8990: from all lookup 100' >"$ip_rules_file"
  : >"$table_file"

  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    run_as_mock_sudo "$@"
  }
  ip() {
    local family="$1"
    shift
    [[ $family == -4 ]] || return 1
    if [[ ${1:-} == rule && ${2:-} == show ]]; then
      cat "$ip_rules_file"
    elif [[ ${1:-} == rule && ${2:-} == del ]]; then
      awk -F: -v priority="$4" '$1 + 0 != priority' "$ip_rules_file" >"${ip_rules_file}.next"
      mv -- "${ip_rules_file}.next" "$ip_rules_file"
    else
      return 1
    fi
  }
  nft() {
    if [[ ${1:-} == list && ${2:-} == table ]]; then
      [[ -f $table_file ]]
    elif [[ ${1:-} == delete && ${2:-} == table ]]; then
      rm -f -- "$table_file"
    else
      return 1
    fi
  }
  setup_tun_routing_rules || return 1
  assert_not_exists "$TUN_ROUTING_STATE_FILE" || return 1
  assert_not_exists "$table_file" || return 1
  remaining="$(cat "$ip_rules_file")"
  assert_equal '8990: from all lookup 100' "$remaining" "removed legacy MiPilot route only"
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
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-亚洲优选") | .type' fallback "custom group definition" || return 1
  if grep -Fq '      - "MiPilot-亚洲优选"' "$output_file"; then
    fail "custom group was nested under a subscription selector"
    return 1
  fi
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-亚洲优选") | .type' fallback "custom group fallback type" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-日本手动") | .type' select "custom group manual selection type" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-旧版自动") | .type' url-test "legacy group automatic selection type" || return 1
  grep -Fq '日本|Japan|JP|新加坡|Singapore|SG' "$output_file" || fail "custom group combined filter was missing"
}

test_custom_region_selection_input() {
  local root
  local captured_state
  local selection
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  REGION_STATE_FILE="$root/region-groups.conf"
  captured_state="$root/captured-regions.conf"

  sudo() {
    run_as_mock_sudo "$@"
  }
  read_line_or_back() {
    case "$1" in
      输入地区编号*) INPUT_LINE="$selection" ;;
      自定义策略组名称*) INPUT_LINE="亚洲优选" ;;
      确认创建策略组*) INPUT_LINE="y" ;;
      *) return 1 ;;
    esac
    return 0
  }
  config_has_group() {
    return 1
  }
  choose_item() {
    SELECTED="自动测速 - 定期检测并选择延迟合适的节点"
    return 0
  }
  jq() {
    printf '%s\n' '🇯🇵日本01' '🇸🇬新加坡01'
  }
  apply_region_group_state() {
    cp -- "$1" "$captured_state"
  }

  for selection in '3,4' ' 3 , 4 ' $'3， 4\r' '3,3,4'; do
    if ! output="$(create_custom_region_group '{"proxies":{}}' 2>&1)"; then
      fail "custom region selection was rejected for $(printf '%q' "$selection"): ${output}"
      return 1
    fi
    grep -Fq ';MiPilot-亚洲优选;' "$captured_state" || fail "custom region state was not created" || return 1
    grep -Fq '日本' "$captured_state" || fail "Japanese region pattern was not selected" || return 1
    grep -Fq '新加坡' "$captured_state" || fail "Singapore region pattern was not selected" || return 1
  done

  for selection in '1 0' ',3' '3,' '3,,4' '3;4' '3,a' '9999999999'; do
    if output="$(create_custom_region_group '{"proxies":{}}' 2>&1)"; then
      fail "invalid region selection was accepted for $(printf '%q' "$selection")"
      return 1
    fi
    grep -Fq '地区编号格式无效' <<<"$output" || fail "invalid region selection did not fail during parsing" || return 1
  done

  selection='15'
  if output="$(create_custom_region_group '{"proxies":{}}' 2>&1)"; then
    fail "out-of-range region selection was accepted"
    return 1
  fi
  grep -Fq '地区编号无效' <<<"$output" || fail "out-of-range region selection did not report its value"
}

test_rule_mode_selects_managed_group() {
  local root
  local api_calls
  local saved_selection
  local choices_file
  local api_response
  local item

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  MANAGER_CONFIG_FILE="$root/config.json"
  REGION_STATE_FILE="$root/region-groups.conf"
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'
  api_calls="$root/api-calls"
  saved_selection="$root/saved-selection"
  choices_file="$root/choices"
  printf '%s\n' 'custom-1;MiPilot-亚洲优选;Japan|Singapore' >"$REGION_STATE_FILE"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "🚀节点选择"' \
    '    type: select' \
    '    proxies: ["自动选择"]' \
    '  - name: "自动选择"' \
    '    type: url-test' \
    '    proxies: ["香港01", "日本01"]' \
    '  - name: "AI网站"' \
    '    type: select' \
    '    proxies: ["🚀节点选择", "DIRECT"]' \
    '  - name: "MiPilot-亚洲优选"' \
    '    type: url-test' \
    '    proxies: ["日本01", "新加坡01"]' \
    'rules:' \
    '  - MATCH,🚀节点选择' >"$CONFIG_FILE"
  printf '%s\n' '{"rule_selection":{"parent":"🚀节点选择","group":"🚀节点选择"}}' >"$MANAGER_CONFIG_FILE"
  api_response='{"proxies":{"MiPilot-规则选择":{"type":"Selector","all":["🚀节点选择","自动选择","AI网站","MiPilot-亚洲优选"],"now":"🚀节点选择"},"🚀节点选择":{"type":"Selector","all":["DIRECT","自动选择"],"now":"自动选择"},"自动选择":{"type":"URLTest","all":["香港01","日本01"],"now":"香港01"},"AI网站":{"type":"Selector","all":["🚀节点选择","DIRECT"],"now":"🚀节点选择"},"MiPilot-亚洲优选":{"type":"URLTest","all":["日本01","新加坡01"],"now":"新加坡01"},"香港01":{"type":"Vmess"},"日本01":{"type":"Vmess"},"新加坡01":{"type":"Vmess"}}}'

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
  update_mipilot_selection() {
    printf '%s\n' "$*" >"$saved_selection"
  }
  restart_mihomo_with_progress() {
    fail "rule strategy API selection unexpectedly restarted Mihomo"
    return 1
  }

  manage_rule_nodes >/dev/null || return 1
  grep -Fq '自动选择' "$choices_file" || fail "subscription strategy group was not listed"
  grep -Fq 'MiPilot-亚洲优选' "$choices_file" || fail "custom strategy group was not listed"
  grep -Fq '[推荐] MiPilot-亚洲优选' "$choices_file" || fail "custom strategy group was not marked recommended" || return 1
  if ! grep -Fq '[高级] AI网站' "$choices_file"; then
    sed 's/^/    choice: /' "$choices_file" >&2
    fail "business routing group was not marked advanced"
    return 1
  fi
  grep -Fq '/proxies/MiPilot-%E8%A7%84%E5%88%99%E9%80%89%E6%8B%A9' "$api_calls" || fail "MiPilot rule selector API target was missing" || return 1
  grep -Fq 'MiPilot-亚洲优选' "$api_calls" || fail "custom strategy API selection was missing" || return 1
  assert_equal 'rule 🚀节点选择 MiPilot-亚洲优选' "$(cat "$saved_selection")" "persisted rule strategy selection"
}

test_rule_mode_discovers_config_groups_when_selector_stale() {
  local root
  local api_calls
  local choices_file
  local saved_selection
  local api_response
  local item

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  MANAGER_CONFIG_FILE="$root/config.json"
  REGION_STATE_FILE="$root/region-groups.conf"
  API='http://127.0.0.1:9090'
  api_calls="$root/api-calls"
  choices_file="$root/choices"
  saved_selection="$root/saved-selection"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: "良心云"' \
    '    type: select' \
    '    proxies: ["自动选择"]' \
    '  - name: "自动选择"' \
    '    type: url-test' \
    '    proxies: ["日本01"]' \
    '  - name: "MiPilot-规则选择"' \
    '    type: select' \
    '    proxies: ["DIRECT"]' \
    'rules:' \
    '  - MATCH,MiPilot-规则选择' >"$CONFIG_FILE"
  api_response='{"proxies":{"MiPilot-规则选择":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"良心云":{"type":"Selector","all":["自动选择"],"now":"自动选择"},"自动选择":{"type":"URLTest","all":["日本01"],"now":"日本01"},"日本01":{"type":"Vmess"},"DIRECT":{"type":"Direct"},"GLOBAL":{"type":"Selector","all":["日本01"],"now":"日本01"}}}'

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
      if [[ $item == *'[推荐] 自动选择 ['* ]]; then
        SELECTED="$item"
        return 0
      fi
    done
    return 1
  }
  reconcile_runtime_config_from_mipilot() {
    api_response='{"proxies":{"MiPilot-规则选择":{"type":"Selector","all":["良心云","自动选择"],"now":"DIRECT"},"良心云":{"type":"Selector","all":["自动选择"],"now":"自动选择"},"自动选择":{"type":"URLTest","all":["日本01"],"now":"日本01"},"日本01":{"type":"Vmess"},"DIRECT":{"type":"Direct"},"GLOBAL":{"type":"Selector","all":["日本01"],"now":"日本01"}}}'
  }
  refresh_api_config() {
    :
  }
  update_mipilot_selection() {
    printf '%s\n' "$*" >"$saved_selection"
  }

  manage_rule_nodes >/dev/null || return 1
  grep -Fq '良心云' "$choices_file" || fail "top-level subscription selector was not listed" || return 1
  grep -Fq '自动选择' "$choices_file" || fail "subscription URLTest group outside the stale selector was not listed" || return 1
  grep -Fq '自动选择' "$api_calls" || fail "repaired selector did not switch to the selected subscription group" || return 1
  assert_equal 'rule MiPilot-规则选择 自动选择' "$(cat "$saved_selection")" "selection after stale selector repair"
}

test_direct_rule_strategy_rendering() {
  local root
  local input_file
  local output_file
  local second_output
  local manager_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  second_output="$root/output-second.yaml"
  manager_file="$root/manager.json"
  MANAGER_CONFIG_FILE="$manager_file"
  printf '%s\n' '{"rule_selection":{"parent":"Proxy","group":"Proxy"}}' >"$manager_file"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: Proxy' \
    '    type: select' \
    '  - name: "MiPilot-日本"' \
    '    type: url-test' \
    'rules:' \
    '  - DOMAIN-SUFFIX,example.com,"Proxy" # keep' \
    '  - IP-CIDR,1.1.1.1/32,Proxy,no-resolve' \
    '  - DOMAIN-SUFFIX,internal.example,DIRECT' \
    '  - DOMAIN-SUFFIX,blocked.example,REJECT' \
    '  - MATCH,Proxy' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_rule_selector_to_config "$input_file" "$output_file" Proxy || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .type' select "MiPilot rule selector definition" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "Proxy")' Proxy "subscription strategy selector member" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "MiPilot-日本")' 'MiPilot-日本' "custom strategy selector member" || return 1
  assert_yaml_equal "$output_file" '.rules[0]' 'DOMAIN-SUFFIX,example.com,"Proxy"' "classified rule target preserved" || return 1
  assert_yaml_equal "$output_file" '.rules[1]' 'IP-CIDR,1.1.1.1/32,Proxy,no-resolve' "classified no-resolve target preserved" || return 1
  assert_yaml_equal "$output_file" '.rules[2]' 'DOMAIN-SUFFIX,internal.example,DIRECT' "DIRECT rule preserved" || return 1
  assert_yaml_equal "$output_file" '.rules[3]' 'DOMAIN-SUFFIX,blocked.example,REJECT' "REJECT rule preserved" || return 1
  assert_yaml_equal "$output_file" '.rules[4]' 'MATCH,MiPilot-规则选择' "MATCH rule selector target" || return 1
  apply_rule_selector_to_config "$output_file" "$second_output" Proxy || return 1
  assert_yaml_equal "$second_output" '[."proxy-groups"[] | select(.name == "MiPilot-规则选择")] | length' 1 "idempotent MiPilot rule selector" || return 1
  assert_yaml_equal "$second_output" '.rules[4]' 'MATCH,MiPilot-规则选择' "idempotent rule selector target"
}

test_rule_selector_selection_restore() {
  local root
  local api_calls
  local api_response

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  MANAGER_CONFIG_FILE="$root/config.json"
  api_calls="$root/api-calls"
  printf '%s\n' '{"rule_selection":{"parent":"Proxy","group":"MiPilot-日本"},"selector_selections":{},"global_selection":{"node":""}}' >"$MANAGER_CONFIG_FILE"
  api_response='{"proxies":{"MiPilot-规则选择":{"type":"Selector","all":["Proxy","MiPilot-日本"],"now":"Proxy"},"Proxy":{"type":"Selector","all":["DIRECT"],"now":"DIRECT"},"MiPilot-日本":{"type":"URLTest","all":["日本01"],"now":"日本01"}}}'

  sudo() {
    run_as_mock_sudo "$@"
  }
  mipilot_config_is_valid() {
    return 0
  }
  api_quick() {
    if (( $# == 1 )); then
      printf '%s\n' "$api_response"
    else
      printf '%s\n' "$*" >>"$api_calls"
    fi
  }

  restore_mipilot_selections || return 1
  grep -Fq '/proxies/MiPilot-%E8%A7%84%E5%88%99%E9%80%89%E6%8B%A9' "$api_calls" || fail "rule selector restore API target was missing" || return 1
  grep -Fq 'MiPilot-日本' "$api_calls" || fail "saved rule strategy was not restored"
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

test_subscription_rule_parent_uses_match_target() {
  local root
  local input_file
  local output_file
  local parent
  local selected_group
  local candidates=()

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  MANAGER_CONFIG_FILE="$root/config.json"
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' '{"rule_selection":{"parent":"🚀节点选择","group":""}}' >"$MANAGER_CONFIG_FILE"
  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 🚀节点选择' \
    '    type: select' \
    '    proxies: [DIRECT]' \
    '  - name: 🐟漏网之鱼' \
    '    type: select' \
    '    proxies: [🚀节点选择, DIRECT]' \
    'rules:' \
    '  - DOMAIN-SUFFIX,example.com,🚀节点选择' \
    '  - MATCH,🐟漏网之鱼' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  parent="$(preferred_rule_parent_for_config "$input_file" '🚀节点选择')" || return 1
  assert_equal '🐟漏网之鱼' "$parent" "subscription MATCH strategy target" || return 1
  selected_group="$(preferred_default_rule_group_for_config "$input_file" "$parent")" || return 1
  assert_equal '🚀节点选择' "$selected_group" "initial subscription strategy selection" || return 1
  apply_rule_selector_to_config "$input_file" "$output_file" "$parent" || return 1
  assert_yaml_equal "$output_file" '.rules[-1]' 'MATCH,MiPilot-规则选择' "subscription MATCH selector target" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 🚀节点选择' \
    '    type: select' \
    '    proxies: [DIRECT]' \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"
  selected_group="$(preferred_default_rule_group_for_config "$input_file" DIRECT)" || return 1
  assert_equal 'DIRECT' "$selected_group" "DIRECT subscription fallback" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 🚀节点选择' \
    '    type: select' \
    '    proxies: [DIRECT]' \
    '  - name: 默认出口' \
    '    type: select' \
    '    proxies: [DIRECT]' \
    'rules:' \
    '  - MATCH,默认出口' >"$input_file"
  selected_group="$(preferred_default_rule_group_for_config "$input_file" '默认出口')" || return 1
  assert_equal '默认出口' "$selected_group" "unrelated subscription fallback group" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 节点选择' \
    '    type: select' \
    '    proxies: [DIRECT]' \
    'rules: []' >"$input_file"
  parent="$(preferred_rule_parent_for_config "$input_file" '')" || return 1
  assert_equal '节点选择' "$parent" "subscription selector fallback without MATCH" || return 1
  apply_rule_selector_to_config "$input_file" "$output_file" "$parent" || return 1
  assert_yaml_equal "$output_file" '.rules[-1]' 'MATCH,MiPilot-规则选择' "managed MATCH rule for subscription without rules" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "节点选择")' '节点选择' "subscription selector retained as managed default" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 自动测速' \
    '    type: url-test' \
    '    proxies: [DIRECT]' \
    'rules: []' >"$input_file"
  parent="$(preferred_rule_parent_for_config "$input_file" '')" || return 1
  assert_equal '自动测速' "$parent" "sole non-selector strategy fallback" || return 1

  printf '%s\n' \
    'proxy-groups:' \
    '  - name: 高速线路' \
    '    type: url-test' \
    '    proxies: [DIRECT]' \
    '  - name: 稳定线路' \
    '    type: fallback' \
    '    proxies: [DIRECT]' \
    'rules: []' >"$input_file"
  parent="$(preferred_rule_parent_for_config "$input_file" '')"
  assert_equal '' "$parent" "ambiguous subscription strategies require selection" || return 1
  mapfile -t candidates < <(list_rule_parent_candidates "$input_file")
  assert_equal '高速线路,稳定线路' "$(IFS=,; echo "${candidates[*]}")" "ambiguous subscription strategy candidates"
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
  assert_equal '实际出口' "$REGION_PARENT" "MATCH strategy target"
}

test_custom_region_group_without_subscription_groups() {
  local root
  local input_file
  local output_file
  local state_file
  local with_selector
  local stale_parent_selector

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  state_file="$root/region-groups.conf"
  with_selector="$root/with-selector.yaml"
  stale_parent_selector="$root/stale-parent-selector.yaml"
  MANAGER_CONFIG_FILE="$root/manager.json"
  printf '%s\n' '{"rule_selection":{"parent":"DIRECT","group":"MiPilot-日本优选"}}' >"$MANAGER_CONFIG_FILE"
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

  apply_region_groups_to_config "$input_file" "$output_file" "$state_file" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-日本优选") | .type' url-test "standalone custom group definition" || return 1
  assert_file_has_line "$output_file" '  - GEOIP,CN,DIRECT' "preserved direct rule" || return 1
  assert_file_has_line "$output_file" '  - MATCH,DIRECT' "preserved match rule" || return 1
  apply_rule_selector_to_config "$output_file" "$with_selector" DIRECT || return 1
  assert_yaml_equal "$with_selector" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .type' select "standalone MiPilot rule selector" || return 1
  assert_yaml_equal "$with_selector" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "MiPilot-日本优选")' 'MiPilot-日本优选' "standalone custom strategy selector member" || return 1
  assert_yaml_equal "$with_selector" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "DIRECT")' DIRECT "standalone original rule fallback member" || return 1
  assert_yaml_equal "$with_selector" '.rules[-1]' 'MATCH,MiPilot-规则选择' "standalone rule selector target" || return 1
  apply_rule_selector_to_config "$output_file" "$stale_parent_selector" OldParent || return 1
  if grep -Fq 'OldParent' "$stale_parent_selector"; then
    fail "stale missing rule parent was added to MiPilot rule selector"
    return 1
  fi
  assert_yaml_equal "$stale_parent_selector" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "DIRECT")' DIRECT "stale-parent current rule fallback member"
}

test_empty_inline_proxy_groups_rule_selector_rendering() {
  local root
  local input_file
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'mode: direct' \
    'proxies: []' \
    'proxy-groups: []' \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_rule_selector_to_config "$input_file" "$output_file" 'MiPilot-规则出口' || return 1
  assert_file_has_line "$output_file" 'proxy-groups:' "expanded empty proxy groups" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .type' select "initial rule selector definition" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "DIRECT")' DIRECT "initial direct selector member" || return 1
  assert_yaml_equal "$output_file" '.rules[-1]' 'MATCH,MiPilot-规则选择' "initial rule selector target"
}

test_indentless_proxy_groups_rule_selector_rendering() {
  local root
  local input_file
  local output_file
  local second_output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  second_output="$root/output-second.yaml"
  printf '%s\n' \
    'proxy-groups:' \
    '- name: Proxy' \
    '  type: select' \
    '  proxies:' \
    '  - DIRECT' \
    'rules:' \
    '- MATCH,Proxy' >"$input_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_rule_selector_to_config "$input_file" "$output_file" Proxy || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .type' select "indentless rule selector definition" || return 1
  assert_yaml_equal "$output_file" '.rules[-1]' 'MATCH,MiPilot-规则选择' "indentless rule selector target" || return 1
  apply_rule_selector_to_config "$output_file" "$second_output" Proxy || return 1
  assert_yaml_equal "$second_output" '[."proxy-groups"[] | select(.name == "MiPilot-规则选择")] | length' 1 "idempotent indentless rule selector"
}

test_structured_yaml_subscription_variants() {
  local root
  local input_file
  local grouped_file
  local output_file
  local state_file
  local malformed_file
  local malformed_output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  input_file="$root/input.yaml"
  grouped_file="$root/grouped.yaml"
  output_file="$root/output.yaml"
  state_file="$root/regions.state"
  malformed_file="$root/malformed.yaml"
  malformed_output="$root/malformed-output.yaml"
  printf '%s\n' \
    'defaults: &defaults {type: select, proxies: [DIRECT]}' \
    'proxy-groups: [{name: "Proxy: #1", <<: *defaults}]' \
    'rules: ["DOMAIN-SUFFIX,example.com,Proxy: #1", "MATCH,Proxy: #1"]' >"$input_file"
  printf '%s\n' 'jp;MiPilot-日本优选;日本|Japan|JP;fallback' >"$state_file"

  sudo() {
    run_as_mock_sudo "$@"
  }

  apply_region_groups_to_config "$input_file" "$grouped_file" "$state_file" || return 1
  region_group_rules_current "$grouped_file" "$state_file" || return 1
  assert_yaml_equal "$grouped_file" '."proxy-groups"[] | select(.name == "Proxy: #1") | .type' select "flow-map subscription group" || return 1
  assert_yaml_equal "$grouped_file" '."proxy-groups"[] | select(.name == "MiPilot-日本优选") | .type' fallback "structured custom group" || return 1

  apply_rule_selector_to_config "$grouped_file" "$output_file" 'Proxy: #1' || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-规则选择") | .proxies[] | select(. == "Proxy: #1")' 'Proxy: #1' "special-character selector member" || return 1
  assert_yaml_equal "$output_file" '.rules[-1]' 'MATCH,MiPilot-规则选择' "inline rule list update" || return 1

  printf '%s\n' 'proxy-groups: [{name: broken' >"$malformed_file"
  if apply_region_groups_to_config "$malformed_file" "$malformed_output" "$state_file" >/dev/null 2>&1; then
    fail "malformed YAML unexpectedly accepted"
    return 1
  fi
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
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-日本") | .type' fallback "updated managed group type" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-日本") | .interval' 300 "updated fallback interval" || return 1
  if [[ $("$MIPILOT_YQ_BIN" eval -r '."proxy-groups"[] | select(.name == "MiPilot-日本") | .tolerance // ""' "$output_file") != "" ]]; then
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
  assert_equal 'DIRECT' "$REGION_PARENT" "direct MATCH fallback target"
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

  apply_region_groups_to_config "$input_file" "$output_file" "$state_file" || return 1
  assert_file_has_line "$output_file" '  - name: "订阅自动选择"' "subscription group preserved" || return 1
  assert_yaml_equal "$output_file" '."proxy-groups"[] | select(.name == "MiPilot-日本优选") | .type' url-test "custom group added at same level" || return 1
  assert_file_has_line "$output_file" '  - MATCH,订阅自动选择' "subscription rule target preserved"
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
  assert_file_has_line "$output_file" "  auto-redirect: true" "native Linux redirect mode" || return 1
  assert_file_has_line "$output_file" "    - 192.168.0.0/16" "LAN route exclusion" || return 1
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

  mv -- "$bashrc" "${bashrc}.target" || return 1
  ln -s -- "${bashrc}.target" "$bashrc" || return 1
  if [[ ! -L $bashrc ]]; then
    printf '    symbolic links are unavailable; symlink preservation is covered on Ubuntu CI\n'
    return 0
  fi
  ensure_shell_integration || return 1
  [[ -L $bashrc ]] || fail "shell integration replaced .bashrc symlink"
  assert_line_count "${bashrc}.target" "$SHELL_INTEGRATION_BEGIN" 1 "symlink target managed block count" || return 1
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
  [[ ",$NO_PROXY," == *",internal.example,"* ]] || fail "existing NO_PROXY entry was not merged"
  [[ ",$NO_PROXY," == *",127.0.0.1,"* ]] || fail "MiPilot NO_PROXY defaults were not merged"
  assert_equal '1' "$(tr ',' '\n' <<<"$NO_PROXY" | grep -Fxc 'internal.example')" "deduplicated NO_PROXY entry" || return 1

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

test_progress_runner_preserves_output_streams() {
  local root

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  progress_stream_fixture() {
    printf 'standard-output\n'
    printf 'standard-error\n' >&2
  }

  run_blocking "测试输出流" 3 progress_stream_fixture >"$root/stdout" 2>"$root/stderr" || return 1
  assert_file_has_line "$root/stdout" 'standard-output' "progress stdout" || return 1
  if grep -Fq 'standard-error' "$root/stdout"; then
    fail "progress stderr leaked into stdout"
    return 1
  fi
  assert_file_has_line "$root/stderr" 'standard-error' "progress stderr"
}

test_progress_runner_waits_for_external_command() {
  local root
  local output_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  output_file="$root/external-output"

  run_blocking "测试外部命令等待" 3 \
    sh -c 'sleep 0.2; printf "%s\n" complete >"$1"' sh "$output_file" \
    >/dev/null 2>&1 || return 1
  assert_file_has_line "$output_file" 'complete' "progress runner external command completion"
}

test_progress_timeout_stops_child_processes() {
  local root
  local child_pid_file
  local child_pid
  local status=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  child_pid_file="$root/child.pid"
  progress_child_fixture() {
    trap '' TERM
    sleep 20 &
    printf '%s\n' "$!" >"$child_pid_file"
    wait
  }

  run_blocking "测试超时清理" 1 progress_child_fixture >/dev/null 2>&1 || status=$?
  assert_equal '124' "$status" "progress timeout status" || return 1
  child_pid="$(cat "$child_pid_file")" || return 1
  sleep 0.2
  if kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    fail "progress timeout left a child process running"
  fi
}

test_interactive_menu_requires_tty() {
  local root
  local status=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  require_interactive_terminal </dev/null >"$root/stdout" 2>"$root/stderr" || status=$?
  assert_equal '1' "$status" "non-TTY interactive guard status" || return 1
  assert_equal '' "$(cat "$root/stdout")" "non-TTY interactive guard stdout" || return 1
  grep -Fq '交互菜单需要连接终端' "$root/stderr" || fail "non-TTY interactive guard message was missing"
}

test_service_account_validation() {
  load_manager || return 1
  SERVICE_USER="mipilot"
  SERVICE_GROUP="mipilot"

  getent() {
    case "$1:$2" in
      passwd:mipilot) printf 'mipilot:x:1:998::/nonexistent:/usr/sbin/nologin\n' ;;
      group:mipilot) printf 'mipilot:x:998:\n' ;;
      *) return 1 ;;
    esac
  }
  ensure_service_account || fail "valid dedicated service account was rejected" || return 1

  getent() {
    case "$1:$2" in
      passwd:mipilot) printf 'mipilot:x:1000:998::/home/mipilot:/bin/bash\n' ;;
      group:mipilot) printf 'mipilot:x:998:\n' ;;
      *) return 1 ;;
    esac
  }
  if ensure_service_account >/dev/null 2>&1; then
    fail "interactive pre-existing account was accepted as the service account"
    return 1
  fi
}

test_config_permission_snapshot_restore() {
  local root
  local snapshot

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  SERVICE_USER="mipilot-test-account-does-not-exist"
  # shellcheck disable=SC2034
  SERVICE_ACCOUNT_MARKER="$root/state/service-account-created"
  snapshot="$root/permissions"
  mkdir -p -- "$CONFIG_DIR"
  printf 'mode: direct\n' >"$CONFIG_FILE"
  chmod 755 "$CONFIG_DIR"
  chmod 644 "$CONFIG_FILE"
  sudo() { run_as_mock_sudo "$@"; }

  capture_config_permission_state "$snapshot" || return 1
  chmod 700 "$CONFIG_DIR"
  chmod 600 "$CONFIG_FILE"
  restore_config_permission_state "$snapshot" || return 1
  assert_equal '755' "$(stat -c '%a' "$CONFIG_DIR")" "restored config directory mode" || return 1
  assert_equal '644' "$(stat -c '%a' "$CONFIG_FILE")" "restored config file mode"
}

test_service_runtime_permission_contract() {
  local root
  local calls

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  calls="$root/calls"
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == test ]]; then return 0; fi
    printf '%s\n' "$*" >>"$calls"
  }

  ensure_service_runtime_permissions || return 1
  assert_file_has_line "$calls" "chown root:${SERVICE_GROUP} ${CONFIG_DIR} ${CONFIG_FILE}" "service config ownership" || return 1
  assert_file_has_line "$calls" "chmod 770 ${CONFIG_DIR}" "service config directory mode" || return 1
  assert_file_has_line "$calls" "chmod 640 ${CONFIG_FILE}" "service config file mode"
}

test_terminal_output_sanitization() {
  local root
  local unsafe
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  unsafe=$'节点\e[31m\t名称'
  assert_equal '节点[31m名称' "$(terminal_safe_text "$unsafe")" "terminal-safe text" || return 1
  assert_equal $'第一行[31m\n第二行' "$(printf '第一行\e[31m\r\n第二行' | terminal_safe_output)" "terminal-safe streamed output" || return 1
  read_choice_or_back() {
    MENU_CHOICE=1
  }
  choose_item '测试列表:' "$unsafe" >"$root/output" || return 1
  output="$(cat "$root/output")"
  [[ $output != *$'\e'* && $output != *$'\t'* ]] || fail "control characters leaked into selection output" || return 1
  assert_equal "$unsafe" "$SELECTED" "unsanitized selected value"
}

test_custom_strategy_name_rejects_control_characters() {
  local read_count=0
  local output

  load_manager || return 1
  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then
      INPUT_LINE='3'
    else
      INPUT_LINE=$'日本\t自动'
    fi
  }

  if output="$(create_custom_region_group '{}')"; then
    fail "custom strategy name with a tab was accepted"
    return 1
  fi
  [[ $output == *'策略组名称不能包含制表符或其他控制字符.'* ]] || fail "custom strategy control-character warning was missing"
}

test_utf8_input_locale_fallback() {
  load_manager || return 1
  LC_ALL=C
  export LC_ALL
  locale() {
    [[ ${1:-} == charmap ]] || return 1
    if [[ ${LC_ALL:-} == C.UTF-8 ]]; then
      printf 'UTF-8\n'
    else
      printf 'ANSI_X3.4-1968\n'
    fi
  }

  ensure_utf8_input_locale || return 1
  assert_equal 'C.UTF-8' "${LC_ALL:-}" "deterministic UTF-8 locale fallback"
}

test_sudo_interactive_invocation_guard() {
  load_manager || return 1
  should_reject_sudo_invocation '' 0 alice || fail "sudo default invocation was accepted" || return 1
  should_reject_sudo_invocation --install 0 alice || fail "sudo installer invocation was accepted" || return 1
  should_reject_sudo_invocation --menu 0 alice || fail "sudo menu invocation was accepted" || return 1
  should_reject_sudo_invocation --menu 0 '' || fail "direct-root menu invocation was accepted" || return 1
  if should_reject_sudo_invocation --cleanup 0 alice; then
    fail "system cleanup invocation was rejected"
    return 1
  fi
  if should_reject_sudo_invocation --menu 1000 ''; then
    fail "normal-user menu invocation was rejected"
  fi
}

test_entrypoint_rejects_non_tty_before_sudo() {
  local root
  local status=0
  local sudo_called=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  ensure_sudo_access() {
    sudo_called=1
  }

  entrypoint --install </dev/null >"$root/stdout" 2>"$root/stderr" || status=$?
  assert_equal '1' "$status" "non-TTY installer status" || return 1
  assert_equal '0' "$sudo_called" "non-TTY installer sudo calls" || return 1
  assert_equal '' "$(cat "$root/stdout")" "non-TTY installer stdout" || return 1
  grep -Fq '交互菜单需要连接终端' "$root/stderr" || fail "non-TTY installer guard message was missing"
}

test_service_account_removal_verifies_identity() {
  local root
  local calls

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  SERVICE_USER="mipilot"
  SERVICE_GROUP="mipilot"
  SERVICE_ACCOUNT_MARKER="$root/service-account-created"
  calls="$root/calls"
  printf 'created_by=mipilot\nuid=998\ngid=998\n' >"$SERVICE_ACCOUNT_MARKER"
  getent() {
    case "$1:$2" in
      passwd:mipilot) printf 'mipilot:x:999:998::/nonexistent:/usr/sbin/nologin\n' ;;
      group:mipilot) printf 'mipilot:x:998:\n' ;;
      *) return 1 ;;
    esac
  }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    case "${1:-}" in
      test) [[ -f ${3:-} ]] ;;
      awk) command awk "${@:2}" ;;
      userdel|groupdel) printf '%s\n' "$*" >>"$calls" ;;
      *) "$@" ;;
    esac
  }

  if remove_managed_service_account >/dev/null 2>&1; then
    fail "mismatched service account identity was deleted"
    return 1
  fi
  [[ ! -e $calls ]] || fail "service account deletion ran despite an identity mismatch"
}

test_run_action_refreshes_sudo_access() {
  local checks=0
  local actions=0

  load_manager || return 1
  ensure_sudo_access() {
    checks=$((checks + 1))
  }
  pause() { return 0; }
  action_fixture() {
    actions=$((actions + 1))
  }

  run_action action_fixture || return 1
  assert_equal '1' "$checks" "sudo refresh count" || return 1
  assert_equal '1' "$actions" "action execution count"
}

test_existing_config_asset_preflight_failure() {
  local root
  local core_calls=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  LOCAL_COUNTRY_MMDB="$root/Country.mmdb"
  LOCAL_GEOSITE_DAT="$root/GeoSite.dat"
  STAGED_MIHOMO_BIN="$root/mihomo"
  mkdir -p -- "$CONFIG_DIR"
  printf 'mode: rule\n' >"$CONFIG_FILE"
  : >"$LOCAL_COUNTRY_MMDB"
  : >"$LOCAL_GEOSITE_DAT"
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == install && ${4:-} == "$LOCAL_GEOSITE_DAT" ]]; then
      return 1
    fi
    if [[ ${1:-} == "$STAGED_MIHOMO_BIN" ]]; then
      core_calls=$((core_calls + 1))
      return 0
    fi
    run_as_mock_sudo "$@"
  }

  if validate_existing_config_with_staged_core; then
    fail "asset preflight succeeded after GeoSite copy failure"
    return 1
  fi
  assert_equal '0' "$core_calls" "staged core calls after asset copy failure"
}

test_install_rollback_restores_runtime_state() {
  local root
  local runtime_restores=0
  local runtime_stops=0
  local service_action=""

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  printf 'mode: rule\n' >"$CONFIG_FILE"
  restore_component_rollback() { return 0; }
  service_exists() { return 0; }
  current_core_version() { printf '1.0.0\n'; }
  restore_mihomo_runtime_state() {
    runtime_restores=$((runtime_restores + 1))
  }
  runtime_is_active() { return 0; }
  runtime_stop() { runtime_stops=$((runtime_stops + 1)); }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == systemctl ]]; then
      service_action="${2:-}"
      return 0
    fi
    run_as_mock_sudo "$@"
  }

  rollback_local_install '' 1 0 0 >/dev/null || return 1
  assert_equal '0' "$runtime_restores" "stopped runtime restore count" || return 1
  assert_equal '1' "$runtime_stops" "unexpected runtime stop count" || return 1
  assert_equal 'disable' "$service_action" "disabled service rollback state" || return 1

  runtime_restores=0
  runtime_stops=0
  service_action=""
  service_exists() { return 1; }
  rollback_local_install '' 1 1 0 >/dev/null || return 1
  assert_equal '1' "$runtime_restores" "active manual runtime restore count" || return 1
  assert_equal '0' "$runtime_stops" "active runtime stop count"
}

test_subscription_activation_escape_keeps_saved_url() {
  local read_count=0
  local output

  load_manager || return 1
  SUBSCRIPTION_URLS=()
  load_subscription_urls() { SUBSCRIPTION_URLS=(); }
  append_subscription_url() { return 0; }
  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then
      INPUT_LINE='https://example.test/sub/token'
    else
      INPUT_LINE=''
    fi
  }
  read_yes_no_or_back() { return 130; }
  sudo() {
    while [[ ${1:-} == -n ]]; do shift; done
    if [[ ${1:-} == test ]]; then return 1; fi
    run_as_mock_sudo "$@"
  }

  output="$(add_managed_subscription)" || return 1
  [[ $output == *'订阅已保存, 尚未激活.'* ]] || fail "saved subscription message was missing after Esc"
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
  if create_curl_url_config 'http://example.test/sub' "$config"; then
    fail "unencrypted subscription URL was accepted"
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
  sudo() {
    run_as_mock_sudo "$@"
  }
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'mixed-port: 7890' \
    "external-controller: '127.0.0.1:9191'" \
    "secret: 'stable-secret'" \
    'rules:' \
    '  - MATCH,DIRECT' >"$CONFIG_FILE"
  input_file="$root/input.yaml"
  output_file="$root/output.yaml"
  printf '%s\n' \
    'mixed-port: 7890' \
    "external-controller: '0.0.0.0:9090'" \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  render_local_api_config "$input_file" "$output_file" || return 1
  assert_yaml_equal "$output_file" '."external-controller"' '127.0.0.1:9191' "local API controller enforced" || return 1
  assert_yaml_equal "$output_file" '.secret' 'stable-secret' "API secret preserved" || return 1

  grep -v '^external-controller:' "$input_file" >"$root/without-controller.yaml"
  render_local_api_config "$root/without-controller.yaml" "$output_file" || return 1
  assert_yaml_equal "$output_file" '."external-controller"' '127.0.0.1:9191' "local API controller appended" || return 1
}

test_local_proxy_config_rendering() {
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
  printf '%s\n' \
    'mixed-port: 7890' \
    'allow-lan: true' \
    "bind-address: '*'" \
    'rules:' \
    '  - MATCH,DIRECT' >"$input_file"

  render_local_proxy_config "$input_file" "$output_file" || return 1
  assert_yaml_equal "$output_file" '."allow-lan"' true "explicit LAN proxy setting preserved" || return 1
  assert_yaml_equal "$output_file" '."bind-address"' '*' "explicit proxy bind address preserved" || return 1

  printf '%s\n' 'mixed-port: 7890' 'rules:' '  - MATCH,DIRECT' >"$input_file"
  render_local_proxy_config "$input_file" "$output_file" || return 1
  assert_yaml_equal "$output_file" '."allow-lan"' false "missing LAN proxy setting defaults off" || return 1
  assert_yaml_equal "$output_file" '."bind-address"' '127.0.0.1' "missing proxy bind address defaults to localhost"
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
  local release_yq
  local hash

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  MANAGER_VERSION="1.0.0-dev"
  MANAGER_LIB_DIR="$root/usr/local/lib/mipilot"
  MANAGER_INSTALLED_SCRIPT="$MANAGER_LIB_DIR/mipilot"
  YQ_BIN="$MANAGER_LIB_DIR/yq"
  INSTALL_MARKER="$root/var/lib/mipilot/install-marker"
  ROLLBACK_DIR="$root/var/lib/mipilot/rollback"
  SERVICE_FILE="$root/etc/systemd/system/mihomo.service"
  mkdir -p -- "$MANAGER_LIB_DIR" "$(dirname -- "$INSTALL_MARKER")"
  printf '#!/usr/bin/env bash\nMANAGER_VERSION="1.0.0-dev"\n' >"$MANAGER_INSTALLED_SCRIPT"
  chmod 755 "$MANAGER_INSTALLED_SCRIPT"
  printf 'version=1.0.0-dev\n' >"$INSTALL_MARKER"

  release_script="$root/release-mipilot"
  release_sidecar="$root/release-mipilot.sha256"
  release_yq="${MIPILOT_YQ_BIN:?test yq path is required}"
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
      */yq_linux_amd64) cp -- "$release_yq" "$2" ;;
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
  sync_mipilot_config_from_state() {
    return 0
  }
  installed_runtime_mode() {
    printf 'manual\n'
  }
  YQ_LINUX_AMD64_SHA256="$(sha256sum "$release_yq" | awk '{print $1}')"

  online_update_manager || return 1
  grep -Fq 'MANAGER_VERSION="1.0.0"' "$MANAGER_INSTALLED_SCRIPT" || fail "manager update did not install candidate"
  [[ -x $YQ_BIN ]] || fail "manager update did not install yq"
  grep -Fq 'MANAGER_VERSION="1.0.0-dev"' "$ROLLBACK_DIR/manager/mipilot" || fail "manager rollback copy was not saved"
  assert_equal "1" "$MANAGER_SHOULD_EXIT" "manager update exit flag" || return 1

  MANAGER_SHOULD_EXIT=0
  manual_rollback_manager || return 1
  grep -Fq 'MANAGER_VERSION="1.0.0-dev"' "$MANAGER_INSTALLED_SCRIPT" || fail "manager rollback did not restore previous script"
  assert_equal "1" "$MANAGER_SHOULD_EXIT" "manager rollback exit flag"
}

test_subscription_activation_marker_rollback() {
  local root
  local output
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

  output="$(activate_subscription 'https://new.example/sub' 2>&1)" || status=$?
  [[ $status -ne 0 ]] || {
    fail "failed subscription activation unexpectedly succeeded"
    return 1
  }
  if [[ $output == *'已设为当前激活订阅.'* ]]; then
    fail "failed subscription activation reported success"
    return 1
  fi
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
  local mock_response
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
  assert_equal 'OldParent' "$REGION_PARENT" "saved original rule parent remains available after direct selection"
}

test_inline_rules_supported_for_managed_outlet() {
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

  render_rule_strategy_selection "$input_file" "$output_file" DIRECT Proxy || return 1
  assert_yaml_equal "$output_file" '.rules[0]' 'MATCH,Proxy' "structured inline rule update"
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
  runtime_is_active() {
    return 0
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

test_tun_change_does_not_start_stopped_runtime() {
  local root
  local backup_file

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  MIHOMO_BIN="$root/mihomo"
  backup_file="$root/config-backup"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'tun:' '  enable: false' 'rules:' '  - MATCH,DIRECT' >"$CONFIG_FILE"
  cp -- "$CONFIG_FILE" "$backup_file"

  sudo() {
    run_as_mock_sudo "$@"
  }
  runtime_is_active() {
    return 1
  }
  run_cancellable_named() {
    return 0
  }
  create_config_backup() {
    printf '%s\n' "$backup_file"
  }
  save_tun_state() {
    printf '%s\n' "$1" >"$TUN_STATE_FILE"
  }
  run_tun_routing_action() {
    return 0
  }
  cleanup_legacy_tun_bypass() {
    return 0
  }
  restart_mihomo_with_progress() {
    fail "stopped Mihomo was unexpectedly started"
  }

  apply_tun_setting true "开启" >/dev/null || return 1
  assert_equal true "$(cat "$TUN_STATE_FILE")" "saved stopped-runtime TUN state" || return 1
  assert_yaml_equal "$CONFIG_FILE" '.tun.enable' true "saved stopped-runtime TUN config"
}

test_tun_runtime_api_mismatch_fails() {
  local output

  load_manager || return 1
  # shellcheck disable=SC2034
  API='http://127.0.0.1:9090'

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":false}}'
  }

  if output="$(verify_tun_runtime_network 2>&1)"; then
    fail "TUN runtime check accepted disabled API state"
    return 1
  fi
  [[ $output == *'Mihomo API 显示 TUN 未启用'* ]] || fail "TUN API mismatch reason was not shown"
}

test_tun_runtime_route_failure_is_explained() {
  local output

  load_manager || return 1
  API='http://127.0.0.1:9090'

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true}}'
  }
  ip() {
    return 1
  }

  if output="$(verify_tun_runtime_network 2>&1)"; then
    fail "TUN runtime check accepted missing IPv4 route"
    return 1
  fi
  [[ $output == *'系统无法解析 IPv4 出站路由'* ]] || fail "TUN route failure reason was not shown"
}

test_tun_runtime_uses_mihomo_native_routing() {
  load_manager || return 1
  API='http://127.0.0.1:9090'

  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true}}'
  }
  ip() {
    if [[ ${1:-} == -4 ]]; then
      printf '%s\n' 'default via 192.0.2.1 dev eth0'
    fi
    return 0
  }
  curl() {
    return 0
  }

  verify_tun_runtime_network >/dev/null 2>&1 || fail "TUN runtime still required MiPilot return routing rules"
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
  local output

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
    if [[ ${1:-} == -4 && ${2:-} == route && ${3:-} == get && ${4:-} == 203.0.113.10 ]]; then return 1; fi
    if [[ ${1:-} == -4 ]]; then printf '%s\n' 'default via 192.0.2.1 dev eth0'; fi
    return 0
  }

  output="$(verify_tun_runtime_network)" || return 1
  [[ $output == *'无法解析当前 SSH 客户端'* && $output == *'回程路由'* ]] || fail "missing SSH return route warning was not shown"
}

test_subscription_urls_are_redacted() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  output="$(redact_subscription_url 'https://user:password@example.com/subscription/private-token?key=secret')"
  [[ $output == 'https://example.com/[敏感路径已隐藏]' ]] || return 1

  SUBSCRIPTION_FILE="$root/active-subscription"
  printf '%s\n' 'https://example.com/subscription/private-token?key=secret' >"$SUBSCRIPTION_FILE"
  sudo() {
    run_as_mock_sudo "$@"
  }
  download_and_apply_subscription() {
    return 0
  }
  output="$(refresh_subscription)" || return 1
  [[ $output == *'https://example.com/[敏感路径已隐藏]'* ]] || return 1
  [[ $output != *'private-token'* && $output != *'key=secret'* ]] || fail "refresh output exposed the raw subscription URL"
}

test_subscription_labels() {
  local root
  local output
  local first_url='https://example.test/sub/first-token'
  local second_url='https://example.test/sub/second-token'

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  MANAGER_CONFIG_DIR="$root/etc/mipilot"
  MANAGER_CONFIG_FILE="$MANAGER_CONFIG_DIR/config.json"
  SUBSCRIPTION_LIST_FILE="$CONFIG_DIR/subscriptions.list"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf '%s\n' "$first_url" "$second_url" >"$SUBSCRIPTION_LIST_FILE"
  printf '%s\n' "$first_url" >"$SUBSCRIPTION_FILE"
  jq -n --arg first "$first_url" --arg second "$second_url" '
    {
      schema_version: 1,
      runtime: {type: "manual"},
      mode: "rule",
      tun: {enabled: false},
      subscription: {
        active: $first,
        items: [$first, $second],
        labels: {($first): "主订阅", ($second): "备用订阅"}
      },
      custom_groups: []
    }
  ' >"$MANAGER_CONFIG_FILE" || return 1
  sudo() {
    run_as_mock_sudo "$@"
  }

  output="$(show_subscription_urls)" || return 1
  [[ $output == *'主订阅 [https://example.test/[敏感路径已隐藏]]'* ]] || return 1
  [[ $output == *'备用订阅 [https://example.test/[敏感路径已隐藏]]'* ]] || return 1
  [[ $output != *'first-token'* && $output != *'second-token'* ]] || fail "subscription label list exposed a raw URL"

  update_mipilot_subscription_label "$second_url" "灾备线路" || return 1
  assert_equal "灾备线路" "$(jq -r --arg url "$second_url" '.subscription.labels[$url]' "$MANAGER_CONFIG_FILE")" "updated subscription label" || return 1
  if grep -Eq -- '--arg label([[:space:]]|$)' "$MANAGER_SCRIPT"; then
    fail "reserved jq label keyword was used as an argument name"
  fi
  update_mipilot_subscription_label "$second_url" "" || return 1
  assert_equal "false" "$(jq -r --arg url "$second_url" '.subscription.labels | has($url)' "$MANAGER_CONFIG_FILE")" "removed subscription label" || return 1
  display_text_has_control_characters $'异常\t名称' || fail "subscription label control character was accepted" || return 1
  if display_text_has_control_characters "正常名称"; then
    fail "normal subscription label was rejected"
  fi

  printf '%s\n' "$second_url" "$first_url" "$second_url" >"$SUBSCRIPTION_LIST_FILE"
  sync_mipilot_config_from_state || return 1
  assert_equal "$second_url,$first_url" \
    "$(jq -r '.subscription.items | join(",")' "$MANAGER_CONFIG_FILE")" \
    "stable subscription order"
}

test_subscription_label_failure_rolls_back_add() {
  local root
  local first_url='https://example.test/sub/first'
  local new_url='https://example.test/sub/new'
  local read_count=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  MANAGER_CONFIG_DIR="$root/etc/mipilot"
  MANAGER_CONFIG_FILE="$MANAGER_CONFIG_DIR/config.json"
  SUBSCRIPTION_LIST_FILE="$CONFIG_DIR/subscriptions.list"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf '%s\n' 'mode: rule' >"$CONFIG_FILE"
  printf '%s\n' "$first_url" >"$SUBSCRIPTION_LIST_FILE"
  printf '%s\n' "$first_url" >"$SUBSCRIPTION_FILE"
  printf '%s\n' 'false' >"$TUN_STATE_FILE"

  sudo() { run_as_mock_sudo "$@"; }
  installed_runtime_mode() { printf '%s\n' manual; }
  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then INPUT_LINE="$new_url"; else INPUT_LINE='新订阅'; fi
  }
  update_mipilot_subscription_label() { return 1; }

  if add_managed_subscription >/dev/null; then
    fail "subscription add succeeded after label persistence failure"
    return 1
  fi
  assert_equal "$first_url" "$(cat "$SUBSCRIPTION_LIST_FILE")" "subscription list rolled back after label failure" || return 1
  assert_equal "$first_url" "$(jq -r '.subscription.items | join(",")' "$MANAGER_CONFIG_FILE")" "manager subscription list rolled back"
}

test_nonactive_subscription_delete_rolls_back_on_sync_failure() {
  local root
  local first_url='https://example.test/sub/first'
  local second_url='https://example.test/sub/second'

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  MANAGER_CONFIG_DIR="$root/etc/mipilot"
  MANAGER_CONFIG_FILE="$MANAGER_CONFIG_DIR/config.json"
  SUBSCRIPTION_LIST_FILE="$CONFIG_DIR/subscriptions.list"
  SUBSCRIPTION_FILE="$CONFIG_DIR/subscription.url"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  REGION_PARENT_FILE="$CONFIG_DIR/region-parent.conf"
  TUN_STATE_FILE="$CONFIG_DIR/tun.state"
  INSTALL_MARKER="$root/install-mode"
  PROXY_STATE_FILE="$root/proxy-state"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf '%s\n' 'mode: rule' >"$CONFIG_FILE"
  printf '%s\n' "$first_url" "$second_url" >"$SUBSCRIPTION_LIST_FILE"
  printf '%s\n' "$first_url" >"$SUBSCRIPTION_FILE"
  printf '%s\n' 'false' >"$TUN_STATE_FILE"

  sudo() { run_as_mock_sudo "$@"; }
  installed_runtime_mode() { printf '%s\n' manual; }
  sync_mipilot_config_from_state || return 1
  select_subscription_url() { SELECTED="$second_url"; }
  read_yes_no_or_back() { CONFIRM_RESULT=yes; }
  runtime_is_active() { return 1; }
  apply_proxy_state() { return 0; }
  cleanup_legacy_tun_bypass() { return 0; }
  sync_mipilot_config_from_state() { return 1; }

  if delete_managed_subscription >/dev/null; then
    fail "non-active subscription deletion succeeded after manager sync failure"
    return 1
  fi
  assert_equal "$first_url,$second_url" \
    "$(tr -d '\r' <"$SUBSCRIPTION_LIST_FILE" | paste -sd,)" \
    "non-active subscription list rollback"
}

test_rollback_waits_for_stability() {
  local root
  local backup
  local waits=0

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_FILE="$root/config.yaml"
  backup="$root/backup.yaml"
  printf '%s\n' 'mode: rule' >"$CONFIG_FILE"
  printf '%s\n' 'mode: direct' >"$backup"
  sudo() {
    run_as_mock_sudo "$@"
  }
  restart_mihomo_with_progress() {
    return 0
  }
  wait_mihomo_with_progress() {
    waits=$((waits + 1))
    return 0
  }

  rollback_config "$backup" 1 >/dev/null || return 1
  assert_equal '1' "$waits" "rollback stability wait count" || return 1
  assert_file_has_line "$CONFIG_FILE" 'mode: direct' "rollback config restored"
}

test_runtime_config_apply_preserves_state() {
  local restarts=0
  local waits=0

  load_manager || return 1
  restart_mihomo_with_progress() {
    restarts=$((restarts + 1))
  }
  wait_mihomo_with_progress() {
    waits=$((waits + 1))
  }

  apply_runtime_config_if_active 0 3 || return 1
  assert_equal '0' "$restarts" "stopped runtime restart count" || return 1
  assert_equal '0' "$waits" "stopped runtime wait count" || return 1
  apply_runtime_config_if_active 1 3 || return 1
  assert_equal '1' "$restarts" "active runtime restart count" || return 1
  assert_equal '1' "$waits" "active runtime wait count"
}

test_start_restores_saved_selections() {
  local restored=0

  load_manager || return 1
  ensure_sudo_access() {
    return 0
  }
  runtime_is_active() {
    return 1
  }
  start_mihomo_with_progress() {
    return 0
  }
  wait_mihomo_with_progress() {
    return 0
  }
  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  restore_mipilot_selections() {
    restored=$((restored + 1))
  }
  runtime_status_label() {
    printf '测试状态\n'
  }

  toggle_service_state >/dev/null || return 1
  assert_equal '1' "$restored" "saved selection restore after start"
}

test_delete_selected_group_updates_state_first() {
  local root
  local calls

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  MANAGER_CONFIG_DIR="$root/etc/mipilot"
  MANAGER_CONFIG_FILE="$MANAGER_CONFIG_DIR/config.json"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  calls="$root/calls"
  mkdir -p -- "$CONFIG_DIR" "$MANAGER_CONFIG_DIR"
  printf '%s\n' 'custom-1;MiPilot-日本;日本|Japan;url-test' >"$REGION_STATE_FILE"
  printf '%s\n' 'rules:' '  - MATCH,MiPilot-规则选择' >"$CONFIG_FILE"
  printf '%s\n' '{"rule_selection":{"parent":"Proxy","group":"MiPilot-日本"}}' >"$MANAGER_CONFIG_FILE"
  sudo() {
    run_as_mock_sudo "$@"
  }
  select_managed_region_record() {
    SELECTED_REGION_RECORD='custom-1;MiPilot-日本;日本|Japan;url-test'
  }
  read_yes_no_or_back() {
    CONFIRM_RESULT=yes
  }
  update_mipilot_selection() {
    printf 'update:%s:%s:%s\n' "$1" "$2" "$3" >>"$calls"
  }
  render_without_region_group() {
    cp -- "$1" "$2"
  }
  apply_region_group_state() {
    printf 'apply\n' >>"$calls"
  }

  delete_managed_region_group >/dev/null || return 1
  assert_equal 'update:rule:Proxy:Proxy' "$(sed -n '1p' "$calls")" "selection updated before group delete" || return 1
  assert_equal 'apply' "$(sed -n '2p' "$calls")" "group delete applied after selection update"
}

test_offline_empty_group_warning() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  REGION_STATE_FILE="$CONFIG_DIR/region-groups.conf"
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' \
    'proxies:' \
    '  - name: 新加坡01' \
    '    type: ss' \
    'proxy-groups: []' \
    'rules:' \
    '  - MATCH,DIRECT' >"$CONFIG_FILE"
  printf '%s\n' 'custom-1;MiPilot-日本;日本|Japan;url-test' >"$REGION_STATE_FILE"
  sudo() {
    run_as_mock_sudo "$@"
  }
  runtime_is_active() {
    return 1
  }

  output="$(warn_empty_managed_region_groups)" || true
  [[ $output == *'MiPilot-日本'* && $output == *'没有匹配节点'* ]] || fail "offline empty custom group warning was missing"
}

test_manual_start_detects_early_exit() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  STATE_DIR="$root/state"
  MANUAL_PID_FILE="$root/run/mihomo.pid"
  MANUAL_LOG_FILE="$root/state/mihomo.log"
  CONFIG_DIR="$root/etc/mihomo"
  MIHOMO_BIN="$root/mihomo"
  mkdir -p -- "$CONFIG_DIR"
  manual_is_active() {
    return 1
  }
  run_tun_routing_action() {
    return 0
  }
  sleep() {
    return 0
  }
  sudo() {
    if [[ ${1:-} == install && ${2:-} == -d ]]; then
      shift 2
      while (( $# > 0 )); do
        case "$1" in
          -m) shift 2 ;;
          *) mkdir -p -- "$1"; shift ;;
        esac
      done
      return 0
    fi
    if [[ ${1:-} == rm ]]; then
      return 0
    fi
    return 0
  }

  if output="$(manual_start)"; then
    fail "manual start accepted an immediately exited process"
    return 1
  fi
  [[ $output == *'手动启动后立即退出'* ]] || fail "manual start failure message was not shown"
}

test_global_node_delay_is_opt_in() {
  local root
  local api_calls
  local response
  local read_count=0
  local option

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  api_calls="$root/api-calls"
  API='http://127.0.0.1:9090'
  mock_response='{"proxies":{"GLOBAL":{"type":"Selector","all":["节点A","节点B"],"now":"节点A"},"节点A":{"type":"Vmess"},"节点B":{"type":"Vmess"}}}'
  api() {
    if (( $# == 1 )); then
      printf '%s\n' "$mock_response"
    else
      printf '%s\n' "$*" >>"$api_calls"
    fi
  }
  api_cancellable() {
    fail "delay API was called without user opt-in"
    return 1
  }
  resolve_main_proxy_response() {
    return 1
  }
  read_line_or_back() {
    INPUT_LINE=""
    return 0
  }
  choose_item() {
    SELECTED="$2"
    return 0
  }
  update_mipilot_selection() {
    return 0
  }

  manage_global_nodes >/dev/null || return 1
  if [[ -f $api_calls ]] && grep -Fq '/delay' "$api_calls"; then
    fail "delay API was called by default"
    return 1
  fi

  mock_response="$(jq -nc '
    reduce range(1; 22) as $index (
      {proxies: {GLOBAL: {type: "Selector", all: [], now: "节点1"}}};
      ("节点" + ($index | tostring)) as $name
      | .proxies.GLOBAL.all += [$name]
      | .proxies[$name] = {type: "Vmess"}
    )
  ')" || return 1
  read_line_or_back() {
    read_count=$((read_count + 1))
    if (( read_count == 1 )); then INPUT_LINE="节点2"; else INPUT_LINE=""; fi
    return 0
  }
  choose_item() {
    shift
    for option in "$@"; do
      [[ $option == *节点2* ]] || { fail "global node keyword filter kept an unrelated node: ${option}"; return 1; }
    done
    SELECTED="$1"
  }
  manage_global_nodes >/dev/null || return 1
  assert_equal '2' "$read_count" "node filter and delay prompt count"
}

test_component_runtime_state_restore() {
  local starts=0
  local waits=0

  load_manager || return 1
  start_mihomo_with_progress() {
    starts=$((starts + 1))
  }
  wait_mihomo_with_progress() {
    waits=$((waits + 1))
  }
  stop_mihomo_with_progress() {
    return 1
  }
  runtime_is_active() {
    return 1
  }

  restore_mihomo_runtime_state 0 || return 1
  assert_equal '0' "$starts" "stopped runtime was unexpectedly started" || return 1
  if stop_mihomo_for_update 0; then
    fail "failed stop unexpectedly succeeded"
    return 1
  fi
  assert_equal '0' "$starts" "failed update stop started a previously stopped runtime" || return 1
  restore_mihomo_runtime_state 1 'v1.0.0' || return 1
  assert_equal '1' "$starts" "active runtime was not started" || return 1
  assert_equal '1' "$waits" "active runtime readiness was not checked"
}

test_same_version_local_hotfix_is_offered() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  MANAGER_VERSION='1.0.2'
  SCRIPT_PATH="$MANAGER_SCRIPT"
  MANAGER_INSTALLED_SCRIPT="$root/installed-mipilot"
  INSTALL_MARKER="$root/install-marker"
  printf '%s\n' '#!/usr/bin/env bash' 'MANAGER_VERSION="1.0.2"' '# older build' >"$MANAGER_INSTALLED_SCRIPT"
  printf '%s\n' 'version=1.0.2' >"$INSTALL_MARKER"
  sudo() {
    run_as_mock_sudo "$@"
  }
  yaml_processor_available() {
    return 0
  }
  read_line_or_back() {
    INPUT_LINE='n'
    return 0
  }

  output="$(offer_local_manager_upgrade)" || return 1
  [[ $output == *'同版本修复构建'* ]] || fail "same-version local hotfix was not offered"
}

test_unchanged_subscription_skips_restart() {
  local root
  local output

  root="$(make_temp_dir)" || return 1
  register_temp_dir_cleanup "$root"
  load_manager || return 1
  CONFIG_DIR="$root/etc/mihomo"
  CONFIG_FILE="$CONFIG_DIR/config.yaml"
  TUN_STATE_FILE="$root/tun-state"
  REGION_STATE_FILE="$root/region-state"
  REGION_PARENT_FILE="$root/region-parent"
  MANAGER_CONFIG_FILE="$root/manager.json"
  MIHOMO_BIN='/usr/bin/true'
  mkdir -p -- "$CONFIG_DIR"
  printf '%s\n' 'mode: rule' 'proxy-groups: []' 'rules: []' >"$CONFIG_FILE"
  printf '%s\n' '{"rule_selection":{"parent":"Proxy","group":"Proxy"}}' >"$MANAGER_CONFIG_FILE"
  sudo() {
    run_as_mock_sudo "$@"
  }
  ensure_sudo_access() {
    return 0
  }
  run_cancellable_named() {
    local label="$1"
    local previous=""
    local output_file=""
    shift 2
    if [[ $label == '正在下载订阅' ]]; then
      for argument in "$@"; do
        [[ $previous == -o ]] && output_file="$argument"
        previous="$argument"
      done
      cp -- "$CONFIG_FILE" "$output_file"
    fi
    return 0
  }
  managed_region_parent() {
    printf '%s\n' 'Proxy'
  }
  preferred_rule_parent_for_config() {
    printf '%s\n' 'Proxy'
  }
  config_has_group() {
    return 0
  }
  apply_rule_selector_to_config() {
    cp -- "$1" "$2"
  }
  render_mode_config() {
    cp -- "$1" "$2"
  }
  render_store_selected_config() {
    cp -- "$1" "$2"
  }
  render_local_proxy_config() {
    cp -- "$1" "$2"
  }
  render_local_api_config() {
    cp -- "$1" "$2"
  }
  warn_empty_managed_region_groups() {
    return 0
  }
  create_config_backup() {
    fail "unchanged subscription created a backup"
    return 1
  }
  restart_mihomo_with_progress() {
    fail "unchanged subscription restarted Mihomo"
    return 1
  }

  output="$(download_and_apply_subscription 'https://example.com/sub/token')" || return 1
  [[ $output == *'无需覆盖配置或重启 Mihomo'* ]] || fail "unchanged subscription did not use no-op path"
}

test_tun_ssh_route_through_tun_is_warning() {
  local output

  load_manager || return 1
  API='http://127.0.0.1:9090'
  SSH_CONNECTION='203.0.113.10 50000 192.0.2.10 22'
  refresh_api_config() {
    API='http://127.0.0.1:9090'
  }
  api_quick() {
    printf '%s\n' '{"tun":{"enable":true,"device":"Meta"}}'
  }
  tun_routing_rules_ready() {
    return 0
  }
  ip() {
    if [[ ${1:-} == -4 && ${2:-} == route && ${3:-} == get && ${4:-} == 203.0.113.10 ]]; then
      printf '%s\n' '203.0.113.10 dev Meta table 2022 src 198.18.0.1'
    elif [[ ${1:-} == -4 ]]; then
      printf '%s\n' 'default via 192.0.2.1 dev eth0'
    fi
    return 0
  }
  curl() {
    return 0
  }

  output="$(verify_tun_runtime_network)" || return 1
  [[ $output == *'回程指向 TUN 网卡'* ]] || fail "TUN SSH route warning was missing"
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
run_test "strategy group UI labels" test_strategy_group_ui_labels
run_test "testing source guard" test_source_testing_guard
run_test "source preserves enabled shell options" test_source_preserves_enabled_shell_options
run_test "Linux input normalization" test_linux_input_normalization
run_test "dependency install survives partial APT update failure" test_dependency_install_continues_after_partial_apt_update
run_test "local asset discovery" test_find_local_assets
run_test "configuration backup pruning" test_prune_config_backups
run_test "rollback expiration" test_cleanup_expired_rollbacks
run_test "installation state detection" test_detect_install_state
run_test "MiPilot config migration and materialization" test_mipilot_config_migration_and_materialization
run_test "startup skips semantic-only config changes" test_reconcile_skips_semantic_only_changes
run_test "configuration backup includes MiPilot settings" test_config_backup_bundles_mipilot_settings
run_test "privileged snapshot keeps caller ownership" test_privileged_temp_copy_uses_caller_owned_output
run_test "TUN preserves non-TUN state" test_tun_render_preserves_non_tun_state
run_test "runtime marker precedence" test_runtime_mode_marker_precedence
run_test "runtime backend dispatch" test_runtime_backend_dispatch
run_test "manual install default" test_install_runtime_choice_defaults_manual
run_test "runtime mode switch persists manager config" test_runtime_mode_switch_persists_manager_config
run_test "install rollback restores runtime state" test_install_rollback_restores_runtime_state
run_test "existing config asset preflight failure" test_existing_config_asset_preflight_failure
run_test "service TUN routing lifecycle" test_service_unit_reconciles_tun_routing
run_test "TUN routing action lock" test_tun_routing_action_uses_independent_lock
run_test "manager lock release" test_manager_lock_release
run_test "lock release preserves caller stderr" test_lock_release_preserves_stderr
run_test "curl download follows current system route" test_download_uses_curl_without_forced_proxy
run_test "restored TUN state reconciliation" test_reconcile_tun_runtime_state
run_test "TUN state sync failure restores sidecar" test_tun_state_sync_failure_restores_sidecar
run_test "native Mihomo TUN routing" test_render_tun_native_routing
run_test "legacy TUN bypass cleanup" test_cleanup_legacy_tun_bypass
run_test "legacy MiPilot TUN routing cleanup" test_tun_routing_rules_are_connection_based
run_test "mode switch persistence" test_mode_switch_persists_config
run_test "selected-node persistence rendering" test_render_store_selected_config
run_test "custom region group rendering" test_custom_region_group_rendering
run_test "custom region selection input" test_custom_region_selection_input
run_test "rule mode managed-group selection" test_rule_mode_selects_managed_group
run_test "rule mode stale selector group discovery" test_rule_mode_discovers_config_groups_when_selector_stale
run_test "MiPilot rule selector rendering" test_direct_rule_strategy_rendering
run_test "empty inline proxy groups rule selector rendering" test_empty_inline_proxy_groups_rule_selector_rendering
run_test "indentless proxy groups rule selector rendering" test_indentless_proxy_groups_rule_selector_rendering
run_test "structured YAML subscription variants" test_structured_yaml_subscription_variants
run_test "MiPilot rule selector selection restore" test_rule_selector_selection_restore
run_test "dynamic region parent selection" test_dynamic_region_parent_selection
run_test "subscription rule parent uses MATCH target" test_subscription_rule_parent_uses_match_target
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
run_test "subscription URL redaction" test_subscription_urls_are_redacted
run_test "subscription labels" test_subscription_labels
run_test "subscription label failure rollback" test_subscription_label_failure_rolls_back_add
run_test "subscription activation Esc keeps saved URL" test_subscription_activation_escape_keeps_saved_url
run_test "non-active subscription delete rollback" test_nonactive_subscription_delete_rolls_back_on_sync_failure
run_test "runtime configuration preserves stopped state" test_runtime_config_apply_preserves_state
run_test "runtime start restores saved selections" test_start_restores_saved_selections
run_test "selected strategy group delete transaction" test_delete_selected_group_updates_state_first
run_test "offline empty strategy group warning" test_offline_empty_group_warning
run_test "rollback waits for stable runtime" test_rollback_waits_for_stability
run_test "manual start detects early exit" test_manual_start_detects_early_exit
run_test "global node delay is opt-in" test_global_node_delay_is_opt_in
run_test "component runtime state restore" test_component_runtime_state_restore
run_test "same-version local hotfix" test_same_version_local_hotfix_is_offered
run_test "unchanged subscription skips restart" test_unchanged_subscription_skips_restart
run_test "manager version comparison" test_version_is_newer
run_test "progress runner non-TTY behavior" test_progress_runner_non_tty
run_test "progress runner output streams" test_progress_runner_preserves_output_streams
run_test "progress runner waits for external command" test_progress_runner_waits_for_external_command
run_test "progress timeout stops child processes" test_progress_timeout_stops_child_processes
run_test "terminal output sanitization" test_terminal_output_sanitization
run_test "interactive menu requires TTY" test_interactive_menu_requires_tty
run_test "service account validation" test_service_account_validation
run_test "config permission snapshot restore" test_config_permission_snapshot_restore
run_test "service runtime permission contract" test_service_runtime_permission_contract
run_test "custom strategy name control-character rejection" test_custom_strategy_name_rejects_control_characters
run_test "UTF-8 input locale fallback" test_utf8_input_locale_fallback
run_test "sudo interactive invocation guard" test_sudo_interactive_invocation_guard
run_test "non-TTY installer guard ordering" test_entrypoint_rejects_non_tty_before_sudo
run_test "service account removal identity guard" test_service_account_removal_verifies_identity
run_test "run action refreshes sudo access" test_run_action_refreshes_sudo_access
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
run_test "inline rules supported for managed outlet" test_inline_rules_supported_for_managed_outlet
run_test "region metadata rollback on config failure" test_region_metadata_restored_when_config_commit_fails
run_test "TUN state failure preserves config" test_tun_state_failure_preserves_config
run_test "TUN restart failure restores state" test_tun_restart_failure_restores_state
run_test "TUN change preserves stopped runtime" test_tun_change_does_not_start_stopped_runtime
run_test "TUN API mismatch fails health check" test_tun_runtime_api_mismatch_fails
run_test "TUN route failure explains cause" test_tun_runtime_route_failure_is_explained
run_test "Mihomo native TUN routing health check" test_tun_runtime_uses_mihomo_native_routing
run_test "TUN public probe failure warns" test_tun_public_probe_failure_is_warning
run_test "TUN SSH return route failure" test_tun_ssh_return_route_failure
run_test "TUN SSH tunnel route warns without blocking" test_tun_ssh_route_through_tun_is_warning

printf '\nResult: %s passed, %s failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
