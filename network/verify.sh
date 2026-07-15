#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

check_not_contains() {
  local file="$1" pattern="$2" message="$3"
  if grep -Eq -- "$pattern" "$file"; then
    fail "$message"
  fi
}

check_contains() {
  local file="$1" pattern="$2" message="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$message"
  fi
}

check_ascii_only() {
  local file="$1" message="$2"
  if LC_ALL=C grep -n '[^[:print:][:space:]]' "$file" >/dev/null; then
    fail "$message"
  fi
}

check_not_exact_line() {
  local file="$1" exact="$2" message="$3"
  if grep -Fxq -- "$exact" "$file"; then
    fail "$message"
  fi
}

for script in freedom.sh vps_init_tool.sh xray-1stream-dat.sh; do
  [ -f "$script" ] || fail "missing script: $script"
  bash -n "$script"
done

vps_count="$(find . -maxdepth 1 -type f -name 'vps_init_tool*.sh' | wc -l | awk '{print $1}')"
[ "$vps_count" = "1" ] || fail "expected exactly one vps_init_tool*.sh, found $vps_count"

check_contains vps_init_tool.sh 'TOOL_VERSION="1\.2\.1"' 'vps_init_tool.sh version drifted'
check_ascii_only vps_init_tool.sh 'vps_init_tool.sh must stay ASCII-only while Chinese output uses English-safe fallback'
check_not_contains vps_init_tool.sh '"\): \$\(current_ssh_ports\)\)"\)' 'vps_init_tool.sh must not duplicate SSH port text after m()'
check_not_contains vps_init_tool.sh "'\) before UFW changes to avoid locking you out\." 'vps_init_tool.sh must not duplicate UFW lockout text after m()'
check_not_contains vps_init_tool.sh '"\): \$ssh_ports/tcp\."\)' 'vps_init_tool.sh must not duplicate SSH allow text after m()'
check_not_contains vps_init_tool.sh '"\) \$ssh_ports before enabling\."\)' 'vps_init_tool.sh must not duplicate UFW inactive text after m()'
check_not_contains vps_init_tool.sh '"\): \$ssh_ports, then enable UFW\."\)' 'vps_init_tool.sh must not duplicate UFW safe-init text after m()'
check_not_contains vps_init_tool.sh '"\)\. Review the output before rebooting\."\)' 'vps_init_tool.sh must not duplicate baseline failure text after m()'
check_not_contains vps_init_tool.sh '3x-ui|x-ui|1stream\.dat' 'vps_init_tool.sh must stay focused on generic VPS initialization'
check_contains vps_init_tool.sh 'handle_cli\(\)' 'vps_init_tool.sh missing CLI dispatcher'
check_contains vps_init_tool.sh 'package_manager_detect\(\)' 'vps_init_tool.sh missing package manager compatibility detector'
check_contains vps_init_tool.sh 'os_support_level\(\)' 'vps_init_tool.sh missing OS support level helper'
check_contains vps_init_tool.sh 'derivative-audit' 'vps_init_tool.sh must distinguish Debian/Ubuntu derivatives from fully supported systems'
check_contains vps_init_tool.sh 'ID_LIKE' 'vps_init_tool.sh compatibility report must expose derivative lineage'
check_contains vps_init_tool.sh 'doctor_report\(\)' 'vps_init_tool.sh missing read-only doctor report'
check_contains vps_init_tool.sh 'Doctor report' 'vps_init_tool.sh doctor output should have a clear title'
check_contains vps_init_tool.sh 'Read-only module readiness' 'vps_init_tool.sh doctor output should include module readiness'
check_contains vps_init_tool.sh 'Recommended commands' 'vps_init_tool.sh doctor output should include command suggestions'
check_contains vps_init_tool.sh '--doctor' 'vps_init_tool.sh missing doctor CLI'
check_contains vps_init_tool.sh '--doctor\) doctor_report; exit 0 ;;' 'vps_init_tool.sh doctor must run before root-only gates'
check_contains vps_init_tool.sh 'optimization_assessment\(\)' 'vps_init_tool.sh missing layered optimization assessment'
check_contains vps_init_tool.sh 'automatic_optimize\(\)' 'vps_init_tool.sh missing safe automatic optimization entry point'
check_contains vps_init_tool.sh 'guided_optimization\(\)' 'vps_init_tool.sh missing guided optimization workflow'
check_contains vps_init_tool.sh 'bbr_available_readonly\(\)' 'vps_init_tool.sh missing read-only BBR availability helper'
check_contains vps_init_tool.sh 'security_updates_fully_enabled\(\)' 'vps_init_tool.sh optimization assessment must verify the complete automatic updates state'
check_contains vps_init_tool.sh 'Automatic optimization' 'vps_init_tool.sh assessment must expose automatic optimization tier'
check_contains vps_init_tool.sh 'Optional optimization' 'vps_init_tool.sh assessment must expose optional optimization tier'
check_contains vps_init_tool.sh 'Reference optimization' 'vps_init_tool.sh assessment must expose reference optimization tier'
check_contains vps_init_tool.sh '--optimize-check' 'vps_init_tool.sh missing read-only optimization assessment CLI'
check_contains vps_init_tool.sh '--optimize-auto' 'vps_init_tool.sh missing safe automatic optimization CLI'
check_contains vps_init_tool.sh '--optimize-check\) optimization_assessment; exit 0 ;;' 'vps_init_tool.sh optimization assessment must run before root-only gates'
check_contains vps_init_tool.sh '--optimize-auto\) automatic_optimize "cli" ;;' 'vps_init_tool.sh automatic optimization CLI must use explicit cli mode'
check_contains vps_init_tool.sh 'Optimization assessment / guided setup' 'vps_init_tool.sh menu must expose guided optimization'
check_contains vps_init_tool.sh 'apply_safe_automatic_optimizations\(\)' 'vps_init_tool.sh automatic and baseline flows must share one safe implementation'
check_contains vps_init_tool.sh 'print_recommended_workflow\(\)' 'vps_init_tool.sh missing recommended workflow guidance'
check_contains vps_init_tool.sh 'Recommended workflow' 'vps_init_tool.sh compatibility report should include actionable workflow guidance'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --preflight' 'vps_init_tool.sh recommended workflow must start with preflight'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --audit' 'vps_init_tool.sh recommended workflow must include full audit'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --optimize-auto --yes' 'vps_init_tool.sh recommended workflow must include safe automatic optimization'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --ssh-audit' 'vps_init_tool.sh recommended workflow must include SSH audit'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --ufw-audit' 'vps_init_tool.sh recommended workflow must include UFW audit'
check_contains vps_init_tool.sh 'bash vps_init_tool.sh --ufw-cf-sync --ports 80,443 --yes' 'vps_init_tool.sh recommended workflow must include Cloudflare UFW sync example'
check_contains vps_init_tool.sh 'compatibility_report\(\)' 'vps_init_tool.sh missing read-only compatibility report'
check_contains vps_init_tool.sh '--compat' 'vps_init_tool.sh missing compatibility report CLI'
check_contains vps_init_tool.sh '--compat\) compatibility_report; exit 0 ;;' 'vps_init_tool.sh compatibility report must run before root-only gates'
check_contains vps_init_tool.sh '--memory-audit' 'vps_init_tool.sh missing memory audit CLI'
check_contains vps_init_tool.sh '--ssh-audit' 'vps_init_tool.sh missing SSH audit CLI'
check_contains vps_init_tool.sh '--fail2ban-audit' 'vps_init_tool.sh missing Fail2ban audit CLI'
check_contains vps_init_tool.sh '--dns-audit' 'vps_init_tool.sh missing DNS audit CLI'
check_contains vps_init_tool.sh '--logs-audit' 'vps_init_tool.sh missing logs audit CLI'
check_contains vps_init_tool.sh '--updates-audit' 'vps_init_tool.sh missing automatic security updates audit CLI'
check_contains vps_init_tool.sh '--updates-enable' 'vps_init_tool.sh missing automatic security updates enable CLI'
check_contains vps_init_tool.sh '--updates-disable' 'vps_init_tool.sh missing automatic security updates disable CLI'
check_contains vps_init_tool.sh '--list-backups' 'vps_init_tool.sh missing backup listing CLI'
check_contains vps_init_tool.sh '--memory-audit\) memory_report ;;' 'vps_init_tool.sh memory audit CLI must call memory_report'
check_contains vps_init_tool.sh '--ssh-audit\) ssh_audit ;;' 'vps_init_tool.sh SSH audit CLI must call ssh_audit'
check_contains vps_init_tool.sh '--fail2ban-audit\) fail2ban_audit ;;' 'vps_init_tool.sh Fail2ban audit CLI must call fail2ban_audit'
check_contains vps_init_tool.sh 'require_systemd \|\| return 1' 'vps_init_tool.sh Fail2ban setup must stop early without systemd'
check_contains vps_init_tool.sh '--dns-audit\) dns_audit ;;' 'vps_init_tool.sh DNS audit CLI must call dns_audit'
check_contains vps_init_tool.sh '--logs-audit\) logs_audit ;;' 'vps_init_tool.sh logs audit CLI must call logs_audit'
check_contains vps_init_tool.sh '--updates-audit\) security_updates_audit; exit 0 ;;' 'vps_init_tool.sh security updates audit must run before root-only gates'
check_contains vps_init_tool.sh '--updates-enable\) security_updates_enable ;;' 'vps_init_tool.sh security updates enable CLI must call its module'
check_contains vps_init_tool.sh '--updates-disable\) security_updates_disable ;;' 'vps_init_tool.sh security updates disable CLI must call its module'
check_contains vps_init_tool.sh '--list-backups\) list_backups ;;' 'vps_init_tool.sh backup listing CLI must call list_backups'
check_contains vps_init_tool.sh 'ufw_parse_cloudflare_ports "\$UFW_CF_PORTS" \|\| \{ red "Invalid --ports value: \$UFW_CF_PORTS"; show_help; exit 2; \}' 'vps_init_tool.sh CLI must validate --ports before running Cloudflare sync'
check_contains vps_init_tool.sh 'comma-separated single ports only, no ranges' 'vps_init_tool.sh help must explain --ports format'
check_contains vps_init_tool.sh 'Missing value for --lang' 'vps_init_tool.sh CLI must report a missing --lang value'
check_contains vps_init_tool.sh 'Chinese alias \(English-safe fallback\)' 'vps_init_tool.sh language menu must explain Chinese fallback mode'
check_contains vps_init_tool.sh 'cn currently uses English-safe output' 'vps_init_tool.sh help must explain cn language fallback'
check_contains vps_init_tool.sh 'zh\|zh-cn\|zh_CN\|cn\|CN\|chinese\|Chinese\) echo "en" ;;' 'vps_init_tool.sh Chinese language aliases must normalize to English-safe output'
check_contains vps_init_tool.sh '2\|cn\|CN\|zh\|chinese\|Chinese\) LANG_MODE="en" ;;' 'vps_init_tool.sh Chinese menu choice must use English-safe language state'
check_contains vps_init_tool.sh 'Missing value for --ports' 'vps_init_tool.sh CLI must report a missing --ports value'
check_contains vps_init_tool.sh 'Only one command may be specified' 'vps_init_tool.sh CLI must reject multiple commands'
check_contains vps_init_tool.sh 'original_args="\$[*]"' 'vps_init_tool.sh CLI logging must preserve original arguments before shifting'
check_contains vps_init_tool.sh 'log_action "cli" "command=\$cmd args=\$original_args"' 'vps_init_tool.sh CLI log must use preserved original arguments'
check_contains vps_init_tool.sh 'local cmd="" original_args="\$[*]" rc=0' 'vps_init_tool.sh CLI must track command return code'
check_contains vps_init_tool.sh 'set \+e' 'vps_init_tool.sh CLI must disable errexit while capturing command rc'
check_contains vps_init_tool.sh '^    set -e$' 'vps_init_tool.sh CLI commands must run in an errexit-enabled subshell'
check_contains vps_init_tool.sh 'log_action "cli" "command=\$cmd complete rc=\$rc"' 'vps_init_tool.sh CLI completion log must include rc'
check_contains vps_init_tool.sh 'exit "\$rc"' 'vps_init_tool.sh CLI must exit with captured rc'
check_not_exact_line vps_init_tool.sh '  log_action "cli" "command=$cmd complete"' 'vps_init_tool.sh CLI completion log must not omit rc'
check_contains vps_init_tool.sh 'LOG_FILE=' 'vps_init_tool.sh missing operation log file setting'
check_contains vps_init_tool.sh 'log_action\(\)' 'vps_init_tool.sh missing operation logger'
check_contains vps_init_tool.sh 'restore_managed_file\(\)' 'vps_init_tool.sh missing managed configuration rollback helper'
check_contains vps_init_tool.sh 'require_systemd\(\)' 'vps_init_tool.sh missing systemd requirement helper'
check_contains vps_init_tool.sh 'systemd is required for this module' 'vps_init_tool.sh systemd helper must explain unsupported service modules'
check_not_contains vps_init_tool.sh 'is_systemd \|\| \{ red "\$\(m '\''systemd not detected\.'\''' 'vps_init_tool.sh service modules must use require_systemd helper'
check_contains vps_init_tool.sh 'normalize_yes_no\(\)' 'vps_init_tool.sh missing y/n normalization helper'
check_contains vps_init_tool.sh 'input_yes_no\(\)' 'vps_init_tool.sh missing y/n compatible yes/no prompt helper'
check_contains vps_init_tool.sh 'normalize_password_policy\(\)' 'vps_init_tool.sh missing y/n compatible SSH password policy helper'
check_contains vps_init_tool.sh 'valid_permit_root_login\(\)' 'vps_init_tool.sh missing PermitRootLogin validator'
check_contains vps_init_tool.sh 'yes\|prohibit-password\|without-password\|forced-commands-only\|no' 'vps_init_tool.sh PermitRootLogin validator must allow only OpenSSH policies'
check_contains vps_init_tool.sh 'valid_permit_root_login "\$permit_root" \|\| \{ red "\$\(m '\''Invalid PermitRootLogin policy\. Use yes, prohibit-password, forced-commands-only, no, or without-password\.'\''' 'vps_init_tool.sh must validate PermitRootLogin before writing SSH hardening'
check_contains vps_init_tool.sh 'valid_allow_users_value\(\)' 'vps_init_tool.sh missing AllowUsers validator'
check_contains vps_init_tool.sh 'valid_allow_users_value "\$allow_user".*Invalid AllowUsers value' 'vps_init_tool.sh must validate AllowUsers before writing SSH hardening'
check_contains vps_init_tool.sh 'ssh_effective_value_from_text\(\)' 'vps_init_tool.sh missing effective sshd value parser'
check_contains vps_init_tool.sh 'ssh_verify_hardening_effective\(\)' 'vps_init_tool.sh missing effective SSH hardening verification'
check_contains vps_init_tool.sh 'fragment_tmp="\$\(mktemp "/etc/ssh/sshd_config\.d/\.00-vps-init-hardening\.conf\.XXXXXX"\)"' 'vps_init_tool.sh must stage SSH hardening in the target directory'
check_contains vps_init_tool.sh 'mv -f -- "\$fragment_tmp" "\$SSH_HARDENING_FRAGMENT"' 'vps_init_tool.sh must atomically replace the SSH hardening fragment'
check_not_contains vps_init_tool.sh 'cat > "\$SSH_HARDENING_FRAGMENT"' 'vps_init_tool.sh must not truncate the live SSH hardening fragment directly'
check_contains vps_init_tool.sh 'ssh_verify_hardening_effective "\$port" "\$password_policy" "\$permit_root" "\$strict_forwarding" "\$allow_tcp" "\$allow_user"' 'vps_init_tool.sh must verify effective SSH settings after staging the fragment'
check_contains vps_init_tool.sh 'SSH hardening did not become effective\. Restoring the previous fragment\.' 'vps_init_tool.sh must explain effective SSH verification rollback'
check_contains vps_init_tool.sh 'APT_LOCK_TIMEOUT=' 'vps_init_tool.sh missing apt lock timeout setting'
check_contains vps_init_tool.sh 'APT_RETRIES=' 'vps_init_tool.sh missing apt retry setting'
check_contains vps_init_tool.sh 'apt_get_retry\(\)' 'vps_init_tool.sh missing apt retry helper'
check_contains vps_init_tool.sh 'DPkg::Lock::Timeout=' 'vps_init_tool.sh apt operations must wait for dpkg locks'
check_contains vps_init_tool.sh 'errexit_was_set=0' 'vps_init_tool.sh apt retry must preserve errexit state'
check_contains vps_init_tool.sh 'case "\$-" in' 'vps_init_tool.sh apt retry must inspect shell option state'
check_contains vps_init_tool.sh '\*e\*\) errexit_was_set=1' 'vps_init_tool.sh apt retry must detect errexit'
check_contains vps_init_tool.sh '\[ "\$errexit_was_set" -eq 1 \] && set -e' 'vps_init_tool.sh apt retry must restore errexit'
check_contains vps_init_tool.sh 'apt_get_retry update' 'vps_init_tool.sh apt update must use retry helper'
check_contains vps_init_tool.sh 'apt_get_retry install -y "\$@"' 'vps_init_tool.sh apt install must use retry helper'
check_contains vps_init_tool.sh 'apt_get_retry update \|\| return 1' 'vps_init_tool.sh apt update failures must propagate explicitly'
check_contains vps_init_tool.sh 'apt_update_once \|\| return 1' 'vps_init_tool.sh apt install must stop when apt update fails'
check_not_contains vps_init_tool.sh 'systemctl enable cron >/dev/null 2>&1 \|\| true' 'vps_init_tool.sh must not silently hide cron enable failures'
check_not_contains vps_init_tool.sh 'systemctl enable sysstat >/dev/null 2>&1 \|\| true' 'vps_init_tool.sh must not silently hide sysstat enable failures'
check_contains vps_init_tool.sh 'Failed to enable cron service' 'vps_init_tool.sh should warn if cron enable fails'
check_contains vps_init_tool.sh 'Failed to enable sysstat service' 'vps_init_tool.sh should warn if sysstat enable fails'
check_contains vps_init_tool.sh 'if \[ "\$max_by_disk_mb" -lt 512 \]; then echo "0M"; return 0; fi' 'vps_init_tool.sh must skip swapfile recommendation when disk space is too low'
check_contains vps_init_tool.sh 'valid_size_mb_gb\(\)' 'vps_init_tool.sh missing size validation helper'
check_contains vps_init_tool.sh 'valid_uint_range\(\)' 'vps_init_tool.sh missing numeric range validation helper'
check_contains vps_init_tool.sh 'valid_ip_or_cidr\(\)' 'vps_init_tool.sh missing IP/CIDR validation helper'
check_contains vps_init_tool.sh 'valid_ipv4_literal "\$addr" && valid_uint_range "\$prefix" 0 32' 'vps_init_tool.sh IPv4 CIDR validator must enforce /0-/32'
check_contains vps_init_tool.sh 'valid_ipv6_literal "\$addr" && valid_uint_range "\$prefix" 0 128' 'vps_init_tool.sh IPv6 CIDR validator must enforce /0-/128'
check_contains vps_init_tool.sh 'Invalid swapfile size' 'vps_init_tool.sh must reject invalid swapfile sizes'
check_contains vps_init_tool.sh 'cleanup_failed_swapfile_creation\(\)' 'vps_init_tool.sh missing swapfile creation cleanup helper'
check_contains vps_init_tool.sh 'restore_previous_swapfile\(\)' 'vps_init_tool.sh missing previous swapfile restore helper'
check_contains vps_init_tool.sh 'rollback_new_swapfile\(\)' 'vps_init_tool.sh missing new swapfile rollback helper'
check_contains vps_init_tool.sh 'old_swap_backup=' 'vps_init_tool.sh must preserve an existing swapfile while replacing it'
check_contains vps_init_tool.sh 'new_swap_tmp=' 'vps_init_tool.sh must prepare a new swapfile before replacing the old one'
check_contains vps_init_tool.sh 'fstab_backup=' 'vps_init_tool.sh must track fstab backup while persisting swapfile'
check_contains vps_init_tool.sh 'new_swap_tmp="\$\(mktemp "\$\{SWAPFILE\}\.new\.XXXXXX"\)" \|\| return 1' 'vps_init_tool.sh must use mktemp for new swapfile staging path'
check_contains vps_init_tool.sh 'old_swap_backup="\$\(mktemp "\$\{SWAPFILE\}\.old\.XXXXXX"\)"' 'vps_init_tool.sh must use mktemp for previous swapfile backup path'
check_contains vps_init_tool.sh 'cleanup_files "\$old_swap_backup" "\$new_swap_tmp"' 'vps_init_tool.sh must cleanup reserved old swap backup path if swapoff fails'
check_contains vps_init_tool.sh 'cleanup_files "\$old_swap_backup"' 'vps_init_tool.sh must cleanup reserved old swap backup path if preserving previous swapfile fails'
check_not_contains vps_init_tool.sh 'new_swap_tmp="\$\{SWAPFILE\}\.new\.\$\$"' 'vps_init_tool.sh must not use predictable pid-based new swapfile path'
check_not_contains vps_init_tool.sh 'old_swap_backup="\$\{SWAPFILE\}\.old\.\$\$"' 'vps_init_tool.sh must not use predictable pid-based old swapfile path'
check_contains vps_init_tool.sh 'mv "\$SWAPFILE" "\$old_swap_backup"' 'vps_init_tool.sh must rename the previous swapfile before replacement'
check_contains vps_init_tool.sh 'restore_previous_swapfile "\$old_swap_backup" "\$swap_was_active"' 'vps_init_tool.sh must restore the previous swapfile if replacement fails'
check_contains vps_init_tool.sh 'restore_managed_file /etc/fstab "\$fstab_backup"' 'vps_init_tool.sh must restore fstab if swap persistence fails'
check_contains vps_init_tool.sh 'rollback_new_swapfile "\$old_swap_backup" "\$swap_was_active"' 'vps_init_tool.sh must rollback the new swapfile if persistence fails'
check_contains vps_init_tool.sh 'Failed to update /etc/fstab. Restoring previous swapfile.' 'vps_init_tool.sh must report fstab persistence failure'
check_contains vps_init_tool.sh 'Swapfile is active, but VM sysctl tuning failed.' 'vps_init_tool.sh must clearly report post-swap sysctl failures'
check_contains vps_init_tool.sh 'if ! apply_memory_sysctl "\$swappiness" "\$vfs_cache_pressure"; then' 'vps_init_tool.sh must handle post-swap sysctl failures explicitly'
check_contains vps_init_tool.sh 'Failed to create swapfile data. Cleaning up partial file.' 'vps_init_tool.sh must cleanup partial swapfile data after dd failure'
check_contains vps_init_tool.sh 'Failed to activate swapfile. Cleaning up partial file.' 'vps_init_tool.sh must cleanup partial swapfile after swapon failure'
check_contains vps_init_tool.sh 'if ! dd if=/dev/zero of="\$new_swap_tmp" bs=1M count="\$mb" status=progress; then' 'vps_init_tool.sh must handle swapfile dd failures explicitly'
check_contains vps_init_tool.sh 'if ! chmod 600 "\$new_swap_tmp"; then' 'vps_init_tool.sh must handle swapfile chmod failures explicitly'
check_contains vps_init_tool.sh 'if ! mkswap "\$new_swap_tmp"; then' 'vps_init_tool.sh must handle mkswap failures explicitly'
check_contains vps_init_tool.sh 'if ! swapon -p 10 "\$SWAPFILE"; then' 'vps_init_tool.sh must handle swapon failures explicitly'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/99-memory-tuning\.conf' 'vps_init_tool.sh must apply and validate its memory sysctl file directly'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/90-bbr\.conf' 'vps_init_tool.sh must apply and validate its BBR sysctl file directly'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/99-proxy-tuning\.conf' 'vps_init_tool.sh must apply and validate its proxy sysctl file directly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/99-memory-tuning\.conf >/dev/null; then' 'vps_init_tool.sh memory sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/90-bbr\.conf >/dev/null; then' 'vps_init_tool.sh BBR sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/99-proxy-tuning\.conf >/dev/null; then' 'vps_init_tool.sh proxy sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'restore_managed_file "\$config_file" "\$config_backup"' 'vps_init_tool.sh persistent configuration failures must restore the previous file'
check_contains vps_init_tool.sh 'restore_sysctl_file\(\)' 'vps_init_tool.sh missing sysctl rollback apply helper'
check_contains vps_init_tool.sh 'Failed to re-apply restored sysctl file' 'vps_init_tool.sh must warn if restored sysctl config cannot be applied'
check_not_contains vps_init_tool.sh 'sysctl -p "\$config_file" >/dev/null 2>&1 \|\| true' 'vps_init_tool.sh must not silently hide restored sysctl apply failures'
check_not_contains vps_init_tool.sh 'sysctl --system >/dev/null \|\| true' 'vps_init_tool.sh must not hide sysctl application failures'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-zram-setup@zram0\.service 2>/dev/null \|\| systemctl start systemd-zram-setup@zram0\.service 2>/dev/null \|\| true' 'vps_init_tool.sh must not hide zram-generator activation failures'
check_not_contains vps_init_tool.sh 'systemctl restart zramswap\.service 2>/dev/null \|\| systemctl restart zram-config\.service 2>/dev/null \|\| true' 'vps_init_tool.sh must not hide zram-tools activation failures'
check_contains vps_init_tool.sh 'ZRAM generator activation failed\. Restoring the previous configuration\.' 'vps_init_tool.sh must report zram-generator rollback'
check_contains vps_init_tool.sh 'ZRAM tools activation failed\. Restoring the previous configuration\.' 'vps_init_tool.sh must report zram-tools rollback'
check_contains vps_init_tool.sh 'restore_managed_file "\$config_file" "\$config_backup"' 'vps_init_tool.sh ZRAM backends must restore previous managed configuration on failure'
check_not_contains vps_init_tool.sh 'setup_zram_generator \|\| \{ stop_known_zram_services; setup_zram_fallback; \}' 'vps_init_tool.sh must not layer fallback ZRAM over a failed generator backend'
check_not_contains vps_init_tool.sh 'setup_zram_tools "\$size_hint" \|\| \{ stop_known_zram_services; setup_zram_fallback; \}' 'vps_init_tool.sh must not layer fallback ZRAM over failed zram-tools'
check_contains vps_init_tool.sh 'setup_zram_generator \|\| return 1' 'vps_init_tool.sh must propagate zram-generator activation failure'
check_contains vps_init_tool.sh 'setup_zram_tools "\$size_hint" \|\| return 1' 'vps_init_tool.sh must propagate zram-tools activation failure'
check_contains vps_init_tool.sh '--baseline' 'vps_init_tool.sh missing low-risk baseline CLI'
check_contains vps_init_tool.sh '--preflight' 'vps_init_tool.sh missing read-only preflight CLI'
check_contains vps_init_tool.sh 'preflight_check\(\)' 'vps_init_tool.sh missing read-only preflight helper'
check_contains vps_init_tool.sh '--preflight\) preflight_check; exit 0 ;;' 'vps_init_tool.sh preflight must run before root-only CLI gates'
check_contains vps_init_tool.sh 'low_risk_baseline "cli"' 'vps_init_tool.sh CLI baseline must use explicit cli mode'
check_not_exact_line vps_init_tool.sh '  setup_swapfile || true' 'vps_init_tool.sh low-risk baseline must not recreate swapfile automatically'
check_not_exact_line vps_init_tool.sh '  setup_zram || true' 'vps_init_tool.sh low-risk baseline must not reconfigure ZRAM automatically'
check_not_exact_line vps_init_tool.sh '  if ! apply_proxy_sysctl; then failures=$((failures + 1)); fi' 'vps_init_tool.sh low-risk baseline must not apply global proxy sysctl tuning'
check_not_exact_line vps_init_tool.sh '  if ! raise_nofile_limits; then failures=$((failures + 1)); fi' 'vps_init_tool.sh low-risk baseline must not raise global nofile limits'
check_contains vps_init_tool.sh 'Advanced proxy sysctl tuning changes global TCP behavior' 'vps_init_tool.sh advanced proxy sysctl tuning must warn before applying'
check_contains vps_init_tool.sh 'Apply advanced global proxy sysctl tuning\?' 'vps_init_tool.sh advanced proxy sysctl tuning must require confirmation'
check_contains vps_init_tool.sh 'Global nofile tuning affects all users and default systemd service limits' 'vps_init_tool.sh global nofile tuning must warn before applying'
check_contains vps_init_tool.sh 'Raise global nofile defaults\?' 'vps_init_tool.sh global nofile tuning must require confirmation'
check_contains vps_init_tool.sh 'Baseline completed with' 'vps_init_tool.sh baseline must report partial failures'
check_contains vps_init_tool.sh '--ufw-cf-sync' 'vps_init_tool.sh missing Cloudflare UFW sync CLI'
check_contains vps_init_tool.sh 'UFW_CF_STATE_FILE=' 'vps_init_tool.sh missing Cloudflare UFW state file'
check_contains vps_init_tool.sh 'UFW_CF_LOCK_FILE=' 'vps_init_tool.sh missing Cloudflare UFW lock file'
check_contains vps_init_tool.sh 'UFW_CF_LOCK_TIMEOUT=' 'vps_init_tool.sh missing Cloudflare UFW lock timeout'
check_contains vps_init_tool.sh 'UFW_CF_LOCK_FD=""' 'vps_init_tool.sh Cloudflare UFW lock fd must be held globally'
check_contains vps_init_tool.sh 'ufw_cf_lock_acquire\(\)' 'vps_init_tool.sh missing Cloudflare UFW lock helper'
check_contains vps_init_tool.sh 'flock is required for safe Cloudflare UFW sync' 'vps_init_tool.sh must fail safely when flock is unavailable'
check_contains vps_init_tool.sh 'exec \{UFW_CF_LOCK_FD\}>"\$UFW_CF_LOCK_FILE"' 'vps_init_tool.sh Cloudflare UFW lock must use a dynamic fd held globally'
check_contains vps_init_tool.sh 'flock -w "\${UFW_CF_LOCK_TIMEOUT:-120}" "\$UFW_CF_LOCK_FD"' 'vps_init_tool.sh Cloudflare UFW sync must use flock with timeout'
check_contains vps_init_tool.sh 'exec \{UFW_CF_LOCK_FD\}>&- 2>/dev/null \|\| true' 'vps_init_tool.sh must close Cloudflare UFW lock fd if flock acquisition fails'
check_not_contains vps_init_tool.sh 'exec 9>"\$UFW_CF_LOCK_FILE"' 'vps_init_tool.sh Cloudflare UFW lock must not reserve fixed fd 9'
check_not_contains vps_init_tool.sh 'local lock_fd' 'vps_init_tool.sh Cloudflare UFW lock fd must not be local to acquire helper'
check_contains vps_init_tool.sh 'ufw_cf_lock_release\(\)' 'vps_init_tool.sh missing Cloudflare UFW lock release helper'
check_contains vps_init_tool.sh 'flock -u "\$UFW_CF_LOCK_FD"' 'vps_init_tool.sh Cloudflare UFW lock release must unlock fd'
check_contains vps_init_tool.sh 'exec \{UFW_CF_LOCK_FD\}>&-' 'vps_init_tool.sh Cloudflare UFW lock release must close fd'
check_contains vps_init_tool.sh 'ufw_cf_lock_release' 'vps_init_tool.sh Cloudflare UFW sync must release lock explicitly'
check_contains vps_init_tool.sh 'ufw_cf_lock_acquire || return 1' 'vps_init_tool.sh Cloudflare UFW sync must acquire lock before mutating rules'
check_contains vps_init_tool.sh 'ufw_cf_sync_cleanup\(\)' 'vps_init_tool.sh missing Cloudflare UFW sync RETURN cleanup helper'
check_contains vps_init_tool.sh 'cleanup_files "\$@"' 'vps_init_tool.sh Cloudflare UFW cleanup helper must use explicit path arguments'
check_contains vps_init_tool.sh 'local ports desired="" current="" adds="" deletes=""' 'vps_init_tool.sh Cloudflare UFW temp paths must initialize empty before cleanup'
check_contains vps_init_tool.sh 'ufw_ensure_ssh_access \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh must cleanup Cloudflare UFW sync if SSH allow check fails'
check_contains vps_init_tool.sh 'cf_fetch_ranges \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh must cleanup Cloudflare UFW sync if Cloudflare ranges fetch fails'
check_contains vps_init_tool.sh 'desired="\$\(mktemp\)" \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh Cloudflare UFW sync must cleanup if desired temp creation fails'
check_contains vps_init_tool.sh 'cleanup_files\(\)' 'vps_init_tool.sh missing temp-file cleanup helper'
check_contains vps_init_tool.sh 'rm -f -- "\$@"' 'vps_init_tool.sh cleanup helper must use rm -- for path safety'
check_contains vps_init_tool.sh 'v4_tmp="\$\(mktemp "\$\(dirname "\$UFW_CF_IPV4_FILE"\)/cloudflare-ips-v4\.txt\.XXXXXX"\)" \|\| return 1' 'vps_init_tool.sh Cloudflare v4 temp creation must fail safely'
check_contains vps_init_tool.sh 'v6_tmp="\$\(mktemp "\$\(dirname "\$UFW_CF_IPV6_FILE"\)/cloudflare-ips-v6\.txt\.XXXXXX"\)" \|\| \{ cleanup_files "\$v4_tmp"; return 1; \}' 'vps_init_tool.sh Cloudflare v6 temp creation must cleanup v4 temp on failure'
check_contains vps_init_tool.sh 'cleanup_files "\$v4_tmp" "\$v6_tmp"' 'vps_init_tool.sh Cloudflare range fetch must cleanup temp downloads on failure'
check_contains vps_init_tool.sh 'if ! mv "\$v4_tmp" "\$UFW_CF_IPV4_FILE"; then cleanup_files "\$v4_tmp" "\$v6_tmp"; return 1; fi' 'vps_init_tool.sh must cleanup temp Cloudflare v4 file if mv fails'
check_contains vps_init_tool.sh 'if ! mv "\$v6_tmp" "\$UFW_CF_IPV6_FILE"; then cleanup_files "\$v4_tmp" "\$v6_tmp"; return 1; fi' 'vps_init_tool.sh must cleanup temp Cloudflare v6 file if mv fails'
check_contains vps_init_tool.sh 'validate_cloudflare_range_file\(\)' 'vps_init_tool.sh must validate every downloaded Cloudflare range'
check_contains vps_init_tool.sh 'Cloudflare IPv\$\{family\} entry is not a CIDR' 'vps_init_tool.sh must reject non-CIDR Cloudflare entries'
check_contains vps_init_tool.sh 'ufw_cf_state_commit\(\)' 'vps_init_tool.sh missing atomic Cloudflare managed-state writer'
check_contains vps_init_tool.sh 'ufw_cf_state_add "\$current" "\$cidr" "\$p"' 'vps_init_tool.sh must persist successful Cloudflare additions immediately'
check_contains vps_init_tool.sh 'ufw_cf_state_remove "\$current" "\$cidr" "\$p"' 'vps_init_tool.sh must persist successful Cloudflare deletions immediately'
check_contains vps_init_tool.sh 'rm -f -- "\$UFW_CF_STATE_FILE"' 'vps_init_tool.sh UFW reset must clear managed Cloudflare state'
check_not_contains vps_init_tool.sh 'ufw allow proto tcp from "\$cidr" to any port "\$p" comment "cloudflare-\$p" \|\| true' 'vps_init_tool.sh must not record failed Cloudflare UFW additions as synced'
check_not_contains vps_init_tool.sh 'ufw --force delete allow proto tcp from "\$cidr" to any port "\$port" >/dev/null 2>&1 \|\| true' 'vps_init_tool.sh must not record failed Cloudflare UFW deletions as synced'
check_contains vps_init_tool.sh 'ufw --force delete allow proto tcp from "\$cidr" to any port "\$port" comment "cloudflare-\$port"' 'vps_init_tool.sh must delete only Cloudflare UFW rules marked by this tool'
check_contains vps_init_tool.sh 'Cloudflare UFW add failed' 'vps_init_tool.sh must report failed Cloudflare UFW additions'
check_contains vps_init_tool.sh 'Cloudflare UFW delete failed' 'vps_init_tool.sh must report failed Cloudflare UFW deletions'
check_contains vps_init_tool.sh 'ssh_reload_or_restart\(\)' 'vps_init_tool.sh missing SSH reload/restart helper'
check_contains vps_init_tool.sh 'ssh_remove_hardening_fragment\(\)' 'vps_init_tool.sh missing SSH hardening rollback helper'
check_contains vps_init_tool.sh 'ssh_restore_hardening_backup\(\)' 'vps_init_tool.sh missing SSH hardening backup restore helper'
check_contains vps_init_tool.sh 'fragment_backup="\$BACKUP_LAST_PATH"' 'vps_init_tool.sh must retain the previous SSH hardening fragment backup path'
check_contains vps_init_tool.sh 'ssh_restore_hardening_backup "\$fragment_backup"' 'vps_init_tool.sh must restore the previous SSH hardening fragment on failure'
check_contains vps_init_tool.sh 'ssh_key_line_valid\(\)' 'vps_init_tool.sh missing authorized_keys line validator'
check_contains vps_init_tool.sh 'ssh_path_secure_for_user\(\)' 'vps_init_tool.sh missing SSH key-path permission validator'
check_contains vps_init_tool.sh '8#022' 'vps_init_tool.sh must reject group/world-writable SSH key paths'
check_contains vps_init_tool.sh 'user_has_authorized_key\(\)' 'vps_init_tool.sh missing key-login readiness helper'
check_contains vps_init_tool.sh 'ssh_require_key_login_ready\(\)' 'vps_init_tool.sh must verify usable public keys before disabling SSH passwords'
check_contains vps_init_tool.sh '\[ "\$password_policy" = "no" \] \|\| \[ "\$permit_root" != "yes" \]' 'vps_init_tool.sh must verify key access when restricting root or password login'
check_contains vps_init_tool.sh 'valid_ssh_public_key\(\)' 'vps_init_tool.sh missing SSH public key format validation helper'
check_contains vps_init_tool.sh 'ssh-keygen -l -f' 'vps_init_tool.sh must validate SSH public keys with ssh-keygen when available'
check_contains vps_init_tool.sh 'valid_ssh_public_key "\$key"' 'vps_init_tool.sh must validate SSH public keys before installing'
check_contains vps_init_tool.sh 'group="\$\(id -gn "\$user" 2>/dev/null \|\| echo "\$user"\)"' 'vps_init_tool.sh must chown SSH keys using the user primary group'
check_contains vps_init_tool.sh 'SSH_CONNECTION' 'vps_init_tool.sh must include the current SSH session port when protecting firewall access'
check_contains vps_init_tool.sh 'ufw_ensure_ssh_access \|\| \{ ssh_restore_hardening_backup "\$fragment_backup"; return 1; \}' 'vps_init_tool.sh SSH hardening must protect current SSH ports before reload'
check_contains vps_init_tool.sh 'SSH firewall allow failed' 'vps_init_tool.sh must abort SSH hardening if the firewall rule cannot be added'
check_not_contains vps_init_tool.sh 'if has_cmd ufw; then ufw allow "\$port/tcp" comment "SSH" \|\| true; fi' 'vps_init_tool.sh must not ignore SSH firewall allow failures'
check_contains vps_init_tool.sh 'SSH service reload/restart failed' 'vps_init_tool.sh must report failed SSH activation'
check_not_contains vps_init_tool.sh 'PasswordAuthentication yes' 'vps_init_tool.sh must not force SSH password login on'
check_not_contains vps_init_tool.sh 'systemctl reload ssh 2>/dev/null \|\| systemctl reload sshd 2>/dev/null \|\| systemctl restart ssh 2>/dev/null \|\| systemctl restart sshd 2>/dev/null \|\| true' 'vps_init_tool.sh must not silently ignore SSH reload/restart failures'
check_contains vps_init_tool.sh 'fail2ban-client -t' 'vps_init_tool.sh must validate Fail2ban configuration before activation'
check_contains vps_init_tool.sh 'Fail2ban configuration test failed' 'vps_init_tool.sh must report invalid Fail2ban configuration'
check_contains vps_init_tool.sh "ufw status 2>/dev/null \| grep -q '\^Status: active'" 'vps_init_tool.sh must use the UFW Fail2ban action only when UFW is active'
check_contains vps_init_tool.sh 'valid_ip_literal\(\)' 'vps_init_tool.sh missing IP literal validation helper'
check_contains vps_init_tool.sh 'valid_ip_list\(\)' 'vps_init_tool.sh missing DNS server list validation helper'
check_contains vps_init_tool.sh 'Invalid primary DNS server list' 'vps_init_tool.sh must reject invalid systemd-resolved DNS server lists'
check_contains vps_init_tool.sh 'valid_ip_or_cidr "\$ip".*Invalid source IP/CIDR' 'vps_init_tool.sh UFW source allow must accept and validate CIDR sources'
check_contains vps_init_tool.sh '\[ -L /etc/resolv\.conf \]' 'vps_init_tool.sh must not directly overwrite a managed resolv.conf symlink'
check_contains vps_init_tool.sh 'dns_restore_resolved_backup\(\)' 'vps_init_tool.sh missing systemd-resolved rollback helper'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-resolved 2>/dev/null \|\| true' 'vps_init_tool.sh must not silently hide DNS rollback restart failures'
check_contains vps_init_tool.sh 'Failed to restart systemd-resolved after restoring backup' 'vps_init_tool.sh must warn if DNS rollback restart fails'
check_not_contains vps_init_tool.sh 'DNSSEC=no' 'vps_init_tool.sh must not force DNSSEC off'
check_contains vps_init_tool.sh 'valid_systemd_size\(\)' 'vps_init_tool.sh missing journald size validation helper'
check_contains vps_init_tool.sh 'valid_systemd_timespan\(\)' 'vps_init_tool.sh missing journald retention validation helper'
check_contains vps_init_tool.sh 'apt_config_value_from_text\(\)' 'vps_init_tool.sh missing APT configuration value parser'
check_contains vps_init_tool.sh 'security_updates_audit\(\)' 'vps_init_tool.sh missing automatic security updates audit'
check_contains vps_init_tool.sh 'security_updates_write_policy\(\)' 'vps_init_tool.sh missing transactional automatic updates policy writer'
check_contains vps_init_tool.sh 'security_updates_policy_effective\(\)' 'vps_init_tool.sh missing effective automatic updates policy verification'
check_contains vps_init_tool.sh 'security_updates_enable\(\)' 'vps_init_tool.sh missing automatic security updates enable function'
check_contains vps_init_tool.sh 'security_updates_disable\(\)' 'vps_init_tool.sh missing automatic security updates disable function'
check_contains vps_init_tool.sh 'Unattended-Upgrade::Automatic-Reboot "false";' 'vps_init_tool.sh automatic security updates must not reboot by default'
check_contains vps_init_tool.sh 'APT::Periodic::Update-Package-Lists "\$enabled";' 'vps_init_tool.sh automatic updates policy must control package-list refresh'
check_contains vps_init_tool.sh 'APT::Periodic::Unattended-Upgrade "\$enabled";' 'vps_init_tool.sh automatic updates policy must control unattended upgrades'
check_not_contains vps_init_tool.sh 'Unattended-Upgrade::Allowed-Origins|Unattended-Upgrade::Origins-Pattern' 'vps_init_tool.sh must preserve distro-provided security origin policy'
check_contains vps_init_tool.sh 'policy_dir="\$\(dirname "\$AUTO_UPGRADES_CONFIG"\)"' 'vps_init_tool.sh automatic updates policy must derive its managed directory'
check_contains vps_init_tool.sh 'policy_tmp="\$\(mktemp "\$policy_dir/\.52-vps-init-auto-upgrades\.XXXXXX"\)"' 'vps_init_tool.sh must stage automatic updates policy atomically'
check_contains vps_init_tool.sh 'mv -f -- "\$policy_tmp" "\$AUTO_UPGRADES_CONFIG"' 'vps_init_tool.sh must atomically install automatic updates policy'
check_contains vps_init_tool.sh 'apt-config dump >/dev/null' 'vps_init_tool.sh must validate APT configuration after policy changes'
check_contains vps_init_tool.sh 'security_updates_policy_effective "\$enabled"' 'vps_init_tool.sh must verify automatic updates settings are effective after writing'
check_contains vps_init_tool.sh 'systemctl enable --now apt-daily\.timer apt-daily-upgrade\.timer' 'vps_init_tool.sh must enable standard APT timers'
check_not_exact_line vps_init_tool.sh '  security_updates_enable || true' 'vps_init_tool.sh low-risk baseline must not silently enable automatic security updates'
check_contains vps_init_tool.sh 'It does NOT change SSH, UFW, DNS, Fail2ban, automatic security updates, global proxy sysctl/nofile tuning, swapfile, or ZRAM\.' 'vps_init_tool.sh baseline must clearly exclude high-impact modules'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-journald \|\| true' 'vps_init_tool.sh must not hide journald restart failures'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-journald 2>/dev/null \|\| true' 'vps_init_tool.sh must not silently hide journald rollback restart failures'
check_contains vps_init_tool.sh 'Failed to restart systemd-journald after restoring backup' 'vps_init_tool.sh must warn if journald rollback restart fails'
check_not_contains vps_init_tool.sh 'backup_path .* >/dev/null \|\| true' 'vps_init_tool.sh must not overwrite managed configuration after a failed backup'
check_not_contains vps_init_tool.sh 'ufw limit "\$p/tcp" comment "rate-limit-ssh" \|\| true' 'vps_init_tool.sh must not hide SSH rate-limit rule failures'
check_not_contains vps_init_tool.sh 'fail2ban-client set "\$jail" unbanip "\$ip" \|\| true' 'vps_init_tool.sh must not hide Fail2ban unban failures'
check_not_contains vps_init_tool.sh 'systemctl restart fail2ban 2>/dev/null \|\| true' 'vps_init_tool.sh must not silently hide Fail2ban rollback restart failures'
check_contains vps_init_tool.sh 'Failed to restart fail2ban after restoring jail' 'vps_init_tool.sh must warn if Fail2ban rollback restart fails'
check_contains vps_init_tool.sh 'Swapfile size verification failed' 'vps_init_tool.sh must verify swapfile allocation size'
check_contains vps_init_tool.sh 'valid_ip_literal "\$ip"' 'vps_init_tool.sh must validate Fail2ban unban IP addresses'
check_contains vps_init_tool.sh 'Invalid IP to unban' 'vps_init_tool.sh must report invalid Fail2ban unban IP addresses'

check_contains freedom.sh 'SCRIPT_VERSION="v10\.2-xray"' 'freedom.sh version drifted'
check_contains freedom.sh 'DEFAULT_SNI="v1-dy\.ixigua\.com"' 'freedom.sh default SNI drifted'
check_contains freedom.sh 'ipv6_is_non_global\(\)' 'freedom.sh missing precise non-global IPv6 classifier'
check_contains freedom.sh 'first_value >= 16#fe80 && first_value <= 16#febf' 'freedom.sh must cover the complete IPv6 link-local fe80::/10 range'
check_contains freedom.sh 'first_value >= 16#fc00 && first_value <= 16#fdff' 'freedom.sh must cover IPv6 ULA fc00::/7 precisely'
check_not_contains freedom.sh 'fe80:\*\|fc\*\|fd\*' 'freedom.sh must not use overbroad IPv6 prefix globs'
check_contains freedom.sh 'ensure_xray_installed\(\)' 'freedom.sh must install/configure Xray-core only'
check_contains freedom.sh 'ensure_xray_capabilities\(\)' 'freedom.sh must validate selected-profile Xray capabilities before deployment'
check_contains freedom.sh 'missing_xray_capabilities\(\)' 'freedom.sh missing testable Xray capability detector'
check_contains freedom.sh 'printf .*tls-ping' 'freedom.sh must detect missing xray tls ping support separately'
check_contains freedom.sh '--update-xray' 'freedom.sh missing explicit official Xray update option'
check_contains freedom.sh 'FREEDOM_UPDATE_XRAY=' 'freedom.sh missing Xray update environment option'
check_contains freedom.sh 'write_xray_config\(\)' 'freedom.sh missing Xray config writer'
check_contains freedom.sh 'preflight_check\(\)' 'freedom.sh missing read-only preflight check'
check_contains freedom.sh 'validate_domain_name\(\)' 'freedom.sh missing SNI domain validator'
check_contains freedom.sh 'probe_sni_domain\(\)' 'freedom.sh missing SNI reachability probe'
check_contains freedom.sh 'check_reality_target_asn\(\)' 'freedom.sh missing read-only REALITY target ASN comparison'
check_contains freedom.sh 'https://api\.ip\.sb/geoip/' 'freedom.sh ASN comparison must use an explicit HTTPS lookup endpoint'
check_contains freedom.sh '--skip-asn-check' 'freedom.sh missing ASN check bypass option'
check_contains freedom.sh 'openssl s_client' 'freedom.sh SNI probe must use openssl s_client for TLS capability checks'
check_contains freedom.sh '-tls1_3' 'freedom.sh SNI probe must explicitly test TLS 1.3 support'
check_contains freedom.sh '-alpn h2,http/1\.1' 'freedom.sh SNI probe must explicitly test ALPN/H2 support'
check_contains freedom.sh 'ALPN protocol: h2' 'freedom.sh SNI probe must recognize negotiated HTTP/2'
check_contains freedom.sh 'SNI_CHECK=' 'freedom.sh missing SNI check toggle'
check_contains freedom.sh '--skip-sni-check' 'freedom.sh missing SNI check bypass option'
check_contains freedom.sh 'validate_link_host\(\)' 'freedom.sh missing server/link host validator'
check_contains freedom.sh 'host:port is not accepted' 'freedom.sh must reject server host:port inputs'
check_contains freedom.sh 'validate_domain_name "\$host"' 'freedom.sh server host validator must accept only valid domain names for hostname input'
check_contains freedom.sh 'ip_to_int "\$host"' 'freedom.sh server host validator must validate IPv4 input'
check_contains freedom.sh 'validate_ipv6_literal\(\)' 'freedom.sh missing IPv6 literal validator'
check_contains freedom.sh 'local -a left_parts right_parts parts' 'freedom.sh IPv6 validator must keep arrays local'
check_contains freedom.sh 'validate_ipv6_literal "\$host"' 'freedom.sh server host validator must use IPv6 literal validator'
check_contains freedom.sh 'return 1 # malformed hostname' 'freedom.sh server host validator must reject malformed hostnames'
check_contains freedom.sh 'ip_to_int\(\)' 'freedom.sh missing IPv4 integer conversion helper'
check_contains freedom.sh '10#\$a' 'freedom.sh IPv4 parsing must force decimal arithmetic'
check_contains freedom.sh 'ip_in_range\(\)' 'freedom.sh missing IPv4 CIDR range helper'
check_contains freedom.sh 'ip_in_range "\$ip_num"' 'freedom.sh private/local IPv4 detection must use numeric ranges'
check_contains freedom.sh 'is_private_or_local_ip\(\)' 'freedom.sh missing private/local IP detector'
check_contains freedom.sh 'auto_detected_server=1' 'freedom.sh must track auto-detected server address'
check_contains freedom.sh 'is_private_or_local_ip "\$SERVER_IP"' 'freedom.sh must reject private/local auto-detected server addresses'
check_contains freedom.sh '2001:db8' 'freedom.sh must treat IPv6 documentation addresses as non-public'
check_contains freedom.sh 'first_value >= 16#ff00 && first_value <= 16#ffff' 'freedom.sh must treat IPv6 multicast addresses as non-public'
check_contains freedom.sh 'secure_config_permissions\(\)' 'freedom.sh missing secure config permissions helper'
check_contains freedom.sh 'download_and_run_installer\(\)' 'freedom.sh missing safer installer runner'
check_contains freedom.sh '--xray-encryption' 'freedom.sh missing Xray encryption CLI option'
check_contains freedom.sh 'XRAY_ENCRYPTION_CHOICE="\$\{FREEDOM_XRAY_ENCRYPTION:-x25519\}"' 'freedom.sh must default VLESS Encryption auth to X25519'
check_contains freedom.sh 'extract_vlessenc_value\(\)' 'freedom.sh must select X25519 or ML-KEM-768 auth from xray vlessenc output'
check_contains freedom.sh 'alg="X25519"' 'freedom.sh must support X25519 auth selection'
check_contains freedom.sh 'alg="ML-KEM-768"' 'freedom.sh must support ML-KEM-768 auth selection'
check_contains freedom.sh 'extract_vlessenc_value "\$out" "\$alg" "decryption"' 'freedom.sh must extract selected auth decryption from xray vlessenc output'
check_contains freedom.sh 'extract_vlessenc_value "\$out" "\$alg" "encryption"' 'freedom.sh must extract selected auth encryption from xray vlessenc output'
check_contains freedom.sh 'xray_tls_ping_probe\(\)' 'freedom.sh missing official xray tls ping SNI probe'
check_contains freedom.sh 'tls ping "\$host"' 'freedom.sh SNI probe should prefer official xray tls ping'
check_contains freedom.sh 'generate_spider_x\(\)' 'freedom.sh missing randomized REALITY spiderX generator'
check_contains freedom.sh 'validate_mldsa_target\(\)' 'freedom.sh must validate REALITY target suitability before enabling ML-DSA'
check_contains freedom.sh 'chain_length <= 3500' 'freedom.sh must reject undersized REALITY target chains for ML-DSA'
check_contains freedom.sh 'TLS Post-Quantum key exchange:' 'freedom.sh must report whether the REALITY target supports post-quantum key exchange'
check_contains freedom.sh 'token="\$\(gen_uuid' 'freedom.sh spiderX randomness should prefer official xray uuid generator'
check_contains freedom.sh 'SPIDER_X=' 'freedom.sh missing spiderX state'
check_contains freedom.sh 'encoded_spider_x="\$\(url_encode "\$SPIDER_X"\)"' 'freedom.sh share link must URL-encode generated spiderX'
check_contains freedom.sh 'spx=\$\{encoded_spider_x\}' 'freedom.sh share link must use generated spiderX'
check_contains freedom.sh 'network: "raw"' 'freedom.sh REALITY transport should use official raw network'
check_contains freedom.sh 'type=raw' 'freedom.sh share link must use raw network'
check_not_contains freedom.sh 'network: "tcp"' 'freedom.sh should not use legacy tcp network spelling for REALITY'
check_not_contains freedom.sh 'type=tcp' 'freedom.sh share link should not use legacy tcp type'
check_not_contains freedom.sh 'spx=%2F' 'freedom.sh should not pin spiderX to root path'
check_contains freedom.sh '--check, --preflight' 'freedom.sh missing read-only preflight CLI option'
check_contains freedom.sh 'clear_screen\(\)' 'freedom.sh missing non-interactive clear guard'
check_contains freedom.sh 'listener_protocol\(\)' 'freedom.sh missing listener protocol selector'
check_contains freedom.sh 'port_listener_summary "\$PORT" "\$proto"' 'freedom.sh port checks must honor TCP/UDP listener protocol'
check_contains freedom.sh 'ss -H -lunp "sport = :\$\{port\}"' 'freedom.sh H3 listener checks must inspect UDP sockets'
check_contains freedom.sh 'verify_service_port_listening\(\)' 'freedom.sh missing post-restart port listener verification'
check_contains freedom.sh 'verify_service_port_listening' 'freedom.sh restart flow must verify the service port is listening'
check_contains freedom.sh 'not listening on \$\{proto\^\^\} port' 'freedom.sh must report missing post-restart listener using the expected protocol'
check_contains freedom.sh 'Xray config install failed' 'freedom.sh must handle config install failures explicitly'
check_contains freedom.sh 'umask 077' 'freedom.sh must protect temporary files containing private key material'
check_contains freedom.sh 'install_generated_config_atomically\(\)' 'freedom.sh missing atomic generated-config installer'
check_contains freedom.sh 'if ! install_generated_config_atomically "\$tmp"; then' 'freedom.sh config install must not rely on errexit'
check_contains freedom.sh 'mv -f -- "\$tmp" "\$CONFIG_PATH"' 'freedom.sh must replace generated config atomically within its directory'
check_contains freedom.sh 'fallback: xray -test -config' 'freedom.sh config validation must preserve fallback test diagnostics'
check_contains freedom.sh 'usage_error\(\)' 'freedom.sh missing CLI usage error helper'
check_contains freedom.sh 'require_option_value\(\)' 'freedom.sh missing CLI option value validator'
check_contains freedom.sh 'require_option_value "--sni"' 'freedom.sh CLI must validate --sni values'
check_contains freedom.sh 'require_option_value "--xray-encryption"' 'freedom.sh CLI must validate --xray-encryption values'
check_contains freedom.sh '--mode MODE' 'freedom.sh missing deployment mode CLI option'
check_contains freedom.sh '--cdn-xhttp-tls' 'freedom.sh missing CDN XHTTP TLS shortcut option'
check_contains freedom.sh 'Deployment profile: 1=REALITY-VISION \(direct\), 2=XHTTP-TLS-VISION \(CDN\)' 'freedom.sh deployment prompt should use polished uppercase profile names'
check_contains freedom.sh 'FREEDOM_MODE=reality\|cdn-xhttp-tls' 'freedom.sh missing deployment mode environment option'
check_contains freedom.sh 'FREEDOM_XHTTP_PATH=' 'freedom.sh missing XHTTP path environment option'
check_contains freedom.sh 'FREEDOM_XHTTP_PROFILE=' 'freedom.sh missing XHTTP transport profile environment option'
check_contains freedom.sh 'FREEDOM_ROUTE_PROFILE=' 'freedom.sh missing routing profile environment option'
check_contains freedom.sh 'FREEDOM_TLS_CERT_FILE=' 'freedom.sh missing TLS certificate environment option'
check_contains freedom.sh 'FREEDOM_TLS_KEY_FILE=' 'freedom.sh missing TLS key environment option'
check_contains freedom.sh 'FREEDOM_TLS_CERT_MODE=' 'freedom.sh missing TLS certificate mode environment option'
check_contains freedom.sh 'normalize_deploy_mode\(\)' 'freedom.sh missing deployment mode normalizer'
check_contains freedom.sh 'normalize_tls_cert_mode\(\)' 'freedom.sh missing TLS certificate mode normalizer'
check_contains freedom.sh 'normalize_xhttp_transport_profile\(\)' 'freedom.sh missing XHTTP transport profile normalizer'
check_contains freedom.sh 'warn_cloudflare_origin_ca_scope\(\)' 'freedom.sh missing reusable Cloudflare Origin CA warning helper'
check_contains freedom.sh 'Cloudflare Origin CA requires Cloudflare proxy with Full\(strict\)' 'freedom.sh must clearly explain Cloudflare Origin CA trust scope'
check_contains freedom.sh 'CDN mode defaults the share address to the TLS/SNI domain' 'freedom.sh CDN mode must avoid defaulting share links to the origin IP'
check_contains freedom.sh 'Use --server for a preferred CDN IP or hostname' 'freedom.sh CDN mode must explain explicit CDN share address override'
check_contains freedom.sh 'CDN XHTTP TLS mode will default the share address to the TLS/SNI domain' 'freedom.sh preflight must preview CDN share address default'
check_contains freedom.sh 'REALITY target SNI or XHTTP-TLS certificate/SNI domain' 'freedom.sh help must describe SNI semantics for both deploy modes'
check_contains freedom.sh 'In XHTTP-TLS mode, omit this to use SNI; set it for preferred CDN IP/hostname' 'freedom.sh help must explain CDN mode --server semantics'
check_contains freedom.sh 'Certificate profile: 1=PUBLIC CA, 2=CLOUDFLARE ORIGIN CA' 'freedom.sh TLS certificate prompt must support polished numeric choices'
check_contains freedom.sh 'Transport profile: 1=CDN-STABLE, 2=CDN-H2, 3=CDN-H3' 'freedom.sh transport prompt must separate CDN edge ALPN from origin ALPN'
check_not_contains freedom.sh 'Transport profile: 1=CDN-STABLE, 2=CDN-H2, 3=CDN-H3, 4=DIRECT-H3' 'freedom.sh normal transport prompt must not advertise direct H3'
check_contains freedom.sh 'CDN-H3 keeps the Xray origin on TCP H1/H2' 'freedom.sh must explain CDN H3 origin conversion'
check_contains freedom.sh 'DIRECT-H3 makes Xray listen on UDP' 'freedom.sh help/preflight must warn about direct Xray H3'
check_contains freedom.sh 'enforce_reality_port_policy\(\)' 'freedom.sh missing REALITY port policy helper'
check_contains freedom.sh '--allow-nonstandard-reality-port' 'freedom.sh missing explicit non-443 REALITY override'
check_contains freedom.sh 'REALITY is expected to listen on TCP/443' 'freedom.sh must explain the non-443 REALITY risk'
check_contains freedom.sh 'validate_xhttp_path\(\)' 'freedom.sh missing XHTTP path validator'
check_contains freedom.sh 'xhttp_origin_alpn_json\(\)' 'freedom.sh missing XHTTP origin ALPN helper'
check_contains freedom.sh 'xhttp_client_alpn_json\(\)' 'freedom.sh missing XHTTP client ALPN helper'
check_contains freedom.sh 'check_tls_cert_files\(\)' 'freedom.sh missing non-fatal TLS certificate checker'
check_contains freedom.sh 'validate_tls_cert_files\(\)' 'freedom.sh missing fatal TLS certificate validation wrapper'
check_contains freedom.sh 'openssl is required to validate TLS certificate files' 'freedom.sh TLS certificate checker must fail clearly when openssl is missing'
check_contains freedom.sh 'check_tls_cert_files "\$SNI" \|\| fatal "TLS certificate validation failed"' 'freedom.sh deploy-time TLS cert validator must pass SNI explicitly'
check_contains freedom.sh 'check_tls_cert_files "\$sni" \|\| failures=\$\(\(failures \+ 1\)\)' 'freedom.sh preflight must pass its local SNI to certificate checks'
check_contains freedom.sh 'cert_covers_domain\(\)' 'freedom.sh missing TLS certificate SAN/CN coverage checker'
check_contains freedom.sh 'openssl x509 -in "\$cert_file" -noout -checkhost "\$domain"' 'freedom.sh certificate hostname checks must honor SAN precedence'
check_contains freedom.sh 'check_tls_files_service_readable\(\)' 'freedom.sh must verify the Xray service account can read TLS files'
check_contains freedom.sh 'cloudflare_https_port_supported\(\)' 'freedom.sh missing Cloudflare HTTPS port validation'
check_contains freedom.sh 'openssl x509 -checkend 0 -noout -in "\$TLS_CERT_FILE"' 'freedom.sh must reject expired TLS certificates'
check_contains freedom.sh 'TLS private key does not match certificate' 'freedom.sh must reject TLS key/certificate mismatches'
check_contains freedom.sh 'TLS certificate does not cover SNI domain' 'freedom.sh must verify certificate covers the configured SNI domain'
check_contains freedom.sh 'TLS certificate expires within 14 days' 'freedom.sh should warn before near-expiring TLS certificates'
check_contains freedom.sh 'write_xray_config_xhttp_tls\(\)' 'freedom.sh missing XHTTP TLS config writer'
check_contains freedom.sh 'network: "xhttp"' 'freedom.sh CDN mode must use XHTTP network'
check_contains freedom.sh 'security: "tls"' 'freedom.sh CDN mode must use TLS security'
check_contains freedom.sh 'rejectUnknownSni: true' 'freedom.sh CDN TLS mode must reject SNI values not covered by its certificate'
check_contains freedom.sh 'minVersion: "1\.2"' 'freedom.sh CDN TLS mode must reject TLS versions older than 1.2'
check_contains freedom.sh 'maxVersion: "1\.3"' 'freedom.sh CDN TLS mode must cap TLS at the supported 1.3 version'
check_contains freedom.sh 'xhttpSettings' 'freedom.sh CDN mode missing xhttpSettings'
check_contains freedom.sh 'certificateFile: \$tls_cert_file' 'freedom.sh CDN mode must use certificate file paths'
check_contains freedom.sh 'keyFile: \$tls_key_file' 'freedom.sh CDN mode must use key file paths'
check_contains freedom.sh 'clients: \[ \{ id: \$uuid, flow: "xtls-rprx-vision" \} \]' 'freedom.sh CDN mode must enable Vision flow with modern VLESS Encryption/XHTTP'
check_contains freedom.sh 'type=xhttp' 'freedom.sh CDN share link must use XHTTP type'
check_contains freedom.sh 'security=tls' 'freedom.sh CDN share link must use TLS security'
check_contains freedom.sh 'mode=auto' 'freedom.sh CDN share link should use XHTTP auto mode'
check_contains freedom.sh 'alpn=\$\{encoded_alpn\}&flow=xtls-rprx-vision&encryption=' 'freedom.sh CDN share link must advertise Vision flow'
check_contains freedom.sh 'Cloudflare Origin CA requires Cloudflare proxy with Full\(strict\)' 'freedom.sh must warn about Cloudflare Origin CA trust scope'
check_contains freedom.sh 'validate_generated_config "\$tmp"' 'freedom.sh must validate generated temp config before installing it'
check_contains freedom.sh 'mktemp --suffix=\.json "\$\{CONFIG_DIR\}/config\.tmp\.XXXXXX"' 'freedom.sh generated Xray temp configs must retain a .json suffix'
check_not_contains freedom.sh 'config\.json\.tmp\.XXXXXX' 'freedom.sh must not use temp config names whose final extension is unknown to Xray'
check_contains freedom.sh '"\$BIN" run -test -c "\$config_file"' 'freedom.sh temp config validation must use xray run -test before install'
check_contains freedom.sh 'H2 is recommended, not mandatory' 'freedom.sh must treat missing H2 as a warning instead of a hard failure'
check_not_contains freedom.sh '\[\[ "\$tls_ok" -ne 1 \|\| "\$h2_ok" -ne 1 \]\]' 'freedom.sh must not require H2 for SNI usability'
check_contains freedom.sh '\{"type":"field","ip":\["geoip:private"\],"outboundTag":"block"\}' 'freedom.sh route must block private IP first'
check_contains freedom.sh '\{"type":"field","protocol":\["bittorrent"\],"outboundTag":"block"\}' 'freedom.sh route must block bittorrent traffic through Xray'
check_contains freedom.sh '\{"type":"field","domain":\["geosite:cn"\],"outboundTag":"block"\}' 'freedom.sh route must block CN domains'
check_contains freedom.sh '\{"type":"field","ip":\["geoip:cn"\],"outboundTag":"block"\}' 'freedom.sh route must block CN IP'
check_not_contains freedom.sh '\{"type":"field","domain":\["geosite:geolocation-!cn"\],"outboundTag":"direct"\}' 'freedom.sh should rely on default direct instead of explicit geolocation-!cn direct'
check_not_contains freedom.sh '\{"type":"field","ip":\["geoip:private","geoip:cn"\],"outboundTag":"block"\}' 'freedom.sh route must keep private and CN IP blocks ordered separately'
check_contains freedom.sh 'routing_domain_strategy\(\)' 'freedom.sh missing routing strategy profile helper'
check_contains freedom.sh 'IPIfNonMatch' 'freedom.sh strict routing profile must resolve unmatched domains for IP rules'
check_contains freedom.sh 'Non-interactive failure; restoring the previous configuration automatically' 'freedom.sh must rollback safely when stdin is unavailable'
check_contains freedom.sh 'Fresh deployment failed; removing the new configuration' 'freedom.sh must clean up a failed first deployment'
check_contains freedom.sh 'decryption\|encryption\|privateKey\|mldsa65Seed' 'freedom.sh diagnostic redaction must cover generated authentication secrets'

check_not_contains freedom.sh 'sing-box|singbox|--kernel|FREEDOM_KERNEL|write_singbox_config|install_singbox_official|gen_reality_keys_singbox|choose_kernel' 'freedom.sh still contains sing-box/core-selection support'
check_not_contains freedom.sh 'BLOCK_CN=' 'freedom.sh must not keep an unused routing toggle when CN blocking is unconditional'
check_not_contains freedom.sh '> "\$CONFIG_PATH"' 'freedom.sh must write config atomically instead of truncating config path directly'
check_not_contains freedom.sh 'chmod 644 "\$CONFIG_PATH"' 'freedom.sh must not make Xray config world-readable'
check_not_contains freedom.sh '/tmp/freedom-' 'freedom.sh must not use predictable /tmp log paths'
check_not_contains freedom.sh 'curl .*[|] sh' 'freedom.sh must not pipe installer downloads to sh'
check_not_contains freedom.sh 'bash -c "\$\(curl' 'freedom.sh must not execute downloaded installer inline'
check_not_contains freedom.sh 'xargs -r rm -f' 'freedom.sh backup cleanup must not use ls/xargs deletion'
check_not_contains freedom.sh 'systemctl enable xray >/dev/null 2>&1 \|\| true' 'freedom.sh must not hide Xray enable failures after installation'
check_contains freedom.sh 'systemctl enable xray >/dev/null 2>&1 \|\| fatal "Xray service enable failed"' 'freedom.sh must fail clearly when Xray service enable fails'

expect_rc() {
  local expected="$1" rc
  shift
  if "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [ "$rc" -eq "$expected" ] || fail "expected rc=$expected from: $*; got rc=$rc"
}

vps_lib="$(mktemp)"
trap 'rm -f "$vps_lib"' EXIT
sed '/^handle_cli "\$@"/,$d' vps_init_tool.sh > "$vps_lib"
# shellcheck source=/dev/null
source "$vps_lib"

modprobe() { fail 'bbr_available_readonly must not load kernel modules'; }
bbr_available_readonly >/dev/null 2>&1 || true
unset -f modprobe

(
  basic_tools_missing() { echo ""; }
  bbr_profile_current() { return 0; }
  memory_profile_current() { return 0; }
  is_systemd() { return 0; }
  journald_profile_current() { return 0; }
  for forbidden in ssh_write_hardening ufw_init_safe fail2ban_setup_sshd security_updates_enable \
    setup_swapfile setup_zram dns_apply_resolved apply_proxy_sysctl raise_nofile_limits; do
    eval "$forbidden() { fail 'safe automatic tier called forbidden module: $forbidden'; }"
  done
  apply_safe_automatic_optimizations >/dev/null \
    || fail 'safe automatic tier failed when every managed profile was already current'
)

(
  essential_calls=0 memory_calls=0 journal_calls=0
  basic_tools_missing() { echo "curl"; }
  install_essential_tools() { essential_calls=$((essential_calls + 1)); }
  bbr_profile_current() { return 1; }
  bbr_supported() { return 1; }
  memory_profile_current() { return 1; }
  apply_memory_sysctl() { memory_calls=$((memory_calls + 1)); }
  is_systemd() { return 0; }
  journald_profile_current() { return 1; }
  logs_limit_journald() { journal_calls=$((journal_calls + 1)); }
  apply_safe_automatic_optimizations >/dev/null || fail 'safe automatic tier rejected successful pending operations'
  [ "$essential_calls" -eq 1 ] || fail 'safe automatic tier did not install essential tools exactly once'
  [ "$memory_calls" -eq 1 ] || fail 'safe automatic tier did not apply the memory profile exactly once'
  [ "$journal_calls" -eq 1 ] || fail 'safe automatic tier did not apply the journald profile exactly once'
)

(
  optimization_assessment() { :; }
  apply_safe_automatic_optimizations() { fail 'automatic CLI changed the system without confirmation'; }
  NONINTERACTIVE=1
  ASSUME_YES=0
  set +e
  automatic_optimize cli >/dev/null 2>&1
  auto_rc=$?
  set -e
  [ "$auto_rc" -eq 2 ] || fail "automatic CLI without --yes must return 2, got $auto_rc"
)

(
  has_cmd() { return 0; }
  dpkg-query() { printf '%s\n' 'install ok installed'; }
  security_updates_policy_effective() { return 0; }
  is_systemd() { return 0; }
  systemctl() { [ "$1" = "is-enabled" ] && [ "${3:-}" != "apt-daily-upgrade.timer" ]; }
  if security_updates_fully_enabled; then
    fail 'security_updates_fully_enabled accepted a disabled apt-daily-upgrade timer'
  fi
)

valid_port 22 || fail 'valid_port rejected port 22'
if valid_port 0; then fail 'valid_port accepted port 0'; fi
valid_size_mb_gb 512M || fail 'valid_size_mb_gb rejected 512M'
if valid_size_mb_gb 1T; then fail 'valid_size_mb_gb accepted unsupported size 1T'; fi
valid_ip_literal 1.1.1.1 || fail 'valid_ip_literal rejected IPv4'
valid_ip_literal 2606:4700:4700::1111 || fail 'valid_ip_literal rejected IPv6'
if valid_ip_literal 999.1.1.1; then fail 'valid_ip_literal accepted invalid IPv4'; fi
valid_ip_or_cidr 192.0.2.0/24 || fail 'valid_ip_or_cidr rejected IPv4 CIDR'
valid_ip_or_cidr 2001:db8::/32 || fail 'valid_ip_or_cidr rejected IPv6 CIDR'
if valid_ip_or_cidr 192.0.2.0/33; then fail 'valid_ip_or_cidr accepted invalid IPv4 CIDR prefix'; fi
if valid_ip_or_cidr 2001:db8::/129; then fail 'valid_ip_or_cidr accepted invalid IPv6 CIDR prefix'; fi
[ "$(normalize_yes_no y)" = "yes" ] || fail 'normalize_yes_no rejected y'
[ "$(normalize_yes_no N)" = "no" ] || fail 'normalize_yes_no rejected N'
if normalize_yes_no maybe >/dev/null 2>&1; then fail 'normalize_yes_no accepted invalid text'; fi
[ "$(normalize_password_policy k)" = "keep" ] || fail 'normalize_password_policy rejected k'
[ "$(normalize_password_policy n)" = "no" ] || fail 'normalize_password_policy rejected n'
[ "$(normalize_password_policy Y)" = "yes" ] || fail 'normalize_password_policy rejected Y'
if normalize_password_policy maybe >/dev/null 2>&1; then fail 'normalize_password_policy accepted invalid text'; fi

load_os_release() { :; }
ID=debian
ID_LIKE=''
[ "$(os_support_level)" = "full" ] || fail 'os_support_level did not fully support Debian'
ID=linuxmint
ID_LIKE='ubuntu debian'
[ "$(os_support_level)" = "derivative-audit" ] || fail 'os_support_level did not classify Debian/Ubuntu derivative as audit-only'
ID=alpine
ID_LIKE=''
[ "$(os_support_level)" = "audit-only" ] || fail 'os_support_level did not keep unrelated OS audit-only'
unset -f load_os_release

apt_dump='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";'
[ "$(apt_config_value_from_text "$apt_dump" 'APT::Periodic::Unattended-Upgrade')" = "1" ] \
  || fail 'apt_config_value_from_text failed to parse unattended-upgrade state'
[ "$(apt_config_value_from_text "$apt_dump" 'Unattended-Upgrade::Automatic-Reboot')" = "false" ] \
  || fail 'apt_config_value_from_text failed to parse automatic reboot state'

updates_tmp="$(mktemp -d)"
AUTO_UPGRADES_CONFIG="$updates_tmp/52-vps-init-auto-upgrades"
BACKUP_ROOT="$updates_tmp/backups"
apt-config() { cat "$AUTO_UPGRADES_CONFIG"; }
systemctl() { return 0; }
security_updates_write_policy 1 || fail 'security_updates_write_policy failed in isolated enable test'
security_updates_policy_effective 1 || fail 'security_updates_policy_effective rejected enabled isolated policy'
grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' "$AUTO_UPGRADES_CONFIG" \
  || fail 'security_updates_write_policy did not enable unattended upgrades'
grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' "$AUTO_UPGRADES_CONFIG" \
  || fail 'security_updates_write_policy enabled automatic reboot'
security_updates_write_policy 0 || fail 'security_updates_write_policy failed in isolated disable test'
security_updates_policy_effective 0 || fail 'security_updates_policy_effective rejected disabled isolated policy'
grep -Fq 'APT::Periodic::Unattended-Upgrade "0";' "$AUTO_UPGRADES_CONFIG" \
  || fail 'security_updates_write_policy did not disable unattended upgrades'
printf '%s\n' 'previous-policy' > "$AUTO_UPGRADES_CONFIG"
apt-config() {
  printf '%s\n' \
    'APT::Periodic::Update-Package-Lists "0";' \
    'APT::Periodic::Unattended-Upgrade "0";' \
    'Unattended-Upgrade::Automatic-Reboot "false";'
}
if security_updates_write_policy 1 >/dev/null 2>&1; then
  fail 'security_updates_write_policy accepted an overridden ineffective policy'
fi
grep -Fxq 'previous-policy' "$AUTO_UPGRADES_CONFIG" \
  || fail 'security_updates_write_policy did not restore previous policy after effective-value failure'
unset -f apt-config systemctl
rm -rf "$updates_tmp"

sshd() {
  cat <<'EOF_SSHD_EFFECTIVE'
port 2222
pubkeyauthentication yes
permitrootlogin prohibit-password
passwordauthentication no
kbdinteractiveauthentication no
maxauthtries 3
maxsessions 3
maxstartups 10:30:60
logingracetime 30
permitemptypasswords no
usepam yes
x11forwarding no
allowagentforwarding no
gatewayports no
permittunnel no
allowstreamlocalforwarding no
allowtcpforwarding yes
allowusers admin deploy@203.0.113.*
EOF_SSHD_EFFECTIVE
}
ssh_verify_hardening_effective 2222 no prohibit-password yes yes 'admin deploy@203.0.113.*' >/dev/null \
  || fail 'ssh_verify_hardening_effective rejected matching effective settings'
if ssh_verify_hardening_effective 2200 no prohibit-password yes yes 'admin deploy@203.0.113.*' >/dev/null 2>&1; then
  fail 'ssh_verify_hardening_effective accepted an ineffective SSH port'
fi
unset -f sshd

ssh_permissions_tmp="$(mktemp -d)"
chmod 700 "$ssh_permissions_tmp"
touch "$ssh_permissions_tmp/authorized_keys"
chmod 600 "$ssh_permissions_tmp/authorized_keys"
ssh_path_secure_for_user "$ssh_permissions_tmp/authorized_keys" "$(id -un)" \
  || fail 'ssh_path_secure_for_user rejected secure key-file permissions'
chmod 666 "$ssh_permissions_tmp/authorized_keys"
if ssh_path_secure_for_user "$ssh_permissions_tmp/authorized_keys" "$(id -un)"; then
  fail 'ssh_path_secure_for_user accepted a group/world-writable key file'
fi
rm -rf "$ssh_permissions_tmp"

(
  user_has_authorized_key() { [ "$1" = "root" ]; }
  interactive_users() { printf '%s\n' 'admin:1000:/bin/bash'; }
  ssh_key_login_ready "" prohibit-password \
    || fail 'ssh_key_login_ready rejected a usable root key with prohibit-password'
  if ssh_key_login_ready "" no; then
    fail 'ssh_key_login_ready accepted a root key when root login would be disabled'
  fi
)

cf_validation_tmp="$(mktemp -d)"
printf '%s\n' '173.245.48.0/20' '103.21.244.0/22' > "$cf_validation_tmp/v4"
printf '%s\n' '2400:cb00::/32' > "$cf_validation_tmp/v6"
validate_cloudflare_range_file "$cf_validation_tmp/v4" 4 \
  || fail 'validate_cloudflare_range_file rejected valid IPv4 CIDRs'
validate_cloudflare_range_file "$cf_validation_tmp/v6" 6 \
  || fail 'validate_cloudflare_range_file rejected valid IPv6 CIDRs'
printf '%s\n' '173.245.48.1' > "$cf_validation_tmp/not-cidr"
if validate_cloudflare_range_file "$cf_validation_tmp/not-cidr" 4 >/dev/null 2>&1; then
  fail 'validate_cloudflare_range_file accepted a non-CIDR Cloudflare entry'
fi
printf '%s\n' '2400:cb00::/32' > "$cf_validation_tmp/wrong-family"
if validate_cloudflare_range_file "$cf_validation_tmp/wrong-family" 4 >/dev/null 2>&1; then
  fail 'validate_cloudflare_range_file accepted an IPv6 range in the IPv4 list'
fi
rm -rf "$cf_validation_tmp"

(
  cf_sync_tmp="$(mktemp -d)"
  UFW_CF_STATE_FILE="$cf_sync_tmp/state.tsv"
  UFW_CF_IPV4_FILE="$cf_sync_tmp/v4"
  UFW_CF_IPV6_FILE="$cf_sync_tmp/v6"
  UFW_CF_PORTS=80
  printf '%s\n' '173.245.48.0/20' > "$UFW_CF_IPV4_FILE"
  printf '%s\n' '2400:cb00::/32' > "$UFW_CF_IPV6_FILE"
  printf '%s\t%s\n' '198.51.100.0/24' '80' > "$UFW_CF_STATE_FILE"
  : > "$cf_sync_tmp/add-calls"
  delete_should_fail=1

  ufw_install() { :; }
  confirm_yes() { return 0; }
  ufw_cf_lock_acquire() { return 0; }
  ufw_cf_lock_release() { return 0; }
  ufw_ensure_ssh_access() { return 0; }
  cf_fetch_ranges() { return 0; }
  ufw() {
    case "$1" in
      status) printf '%s\n' 'Status: active'; return 0 ;;
      allow) printf '%s\n' "$*" >> "$cf_sync_tmp/add-calls"; return 0 ;;
      --force)
        if [ "${2:-}" = "delete" ] && [ "$delete_should_fail" -eq 1 ]; then return 1; fi
        return 0
        ;;
    esac
    return 0
  }

  set +e
  ufw_sync_cloudflare_web >/dev/null 2>&1
  first_sync_rc=$?
  set -e
  [ "$first_sync_rc" -eq 1 ] || fail 'Cloudflare sync mock should fail on stale-rule deletion'
  grep -Fqx $'173.245.48.0/20\t80' "$UFW_CF_STATE_FILE" \
    || fail 'Cloudflare sync did not persist a successful IPv4 addition before later failure'
  grep -Fqx $'2400:cb00::/32\t80' "$UFW_CF_STATE_FILE" \
    || fail 'Cloudflare sync did not persist a successful IPv6 addition before later failure'
  grep -Fqx $'198.51.100.0/24\t80' "$UFW_CF_STATE_FILE" \
    || fail 'Cloudflare sync lost an undeleted stale rule after partial failure'

  delete_should_fail=0
  ufw_sync_cloudflare_web >/dev/null \
    || fail 'Cloudflare sync did not recover after the simulated deletion failure'
  [ "$(wc -l < "$cf_sync_tmp/add-calls" | awk '{print $1}')" -eq 2 ] \
    || fail 'Cloudflare sync repeated already-persisted additions during recovery'
  if grep -Fqx $'198.51.100.0/24\t80' "$UFW_CF_STATE_FILE"; then
    fail 'Cloudflare sync retained stale managed state after successful recovery'
  fi

  ufw_reset_safe >/dev/null || fail 'ufw_reset_safe failed in isolated state cleanup test'
  [ ! -e "$UFW_CF_STATE_FILE" ] || fail 'ufw_reset_safe left stale Cloudflare managed state behind'
  rm -rf "$cf_sync_tmp"
)

get_mem_mb() { echo 1024; }
get_root_avail_mb() { echo 100; }
[ "$(recommend_swap_size)" = "0M" ] || fail 'recommend_swap_size must skip low-disk systems'

export SSH_CONNECTION='203.0.113.10 50000 192.0.2.10 2222'
printf '%s\n' "$(current_ssh_ports)" | grep -qw 2222 || fail 'current_ssh_ports must include current SSH session port'

rm -f "$vps_lib"
trap - EXIT

expect_rc 2 bash ./vps_init_tool.sh --lang
expect_rc 2 bash ./vps_init_tool.sh --ports
expect_rc 2 bash ./vps_init_tool.sh --status --audit
bash ./vps_init_tool.sh --preflight >/dev/null || fail 'vps_init_tool.sh --preflight failed'
bash ./vps_init_tool.sh --compat >/dev/null || fail 'vps_init_tool.sh --compat failed'
bash ./vps_init_tool.sh --doctor >/dev/null || fail 'vps_init_tool.sh --doctor failed'
bash ./vps_init_tool.sh --optimize-check >/dev/null || fail 'vps_init_tool.sh --optimize-check failed'
bash ./vps_init_tool.sh --updates-audit >/dev/null || fail 'vps_init_tool.sh --updates-audit failed'

freedom_lib="$(mktemp)"
trap 'rm -f "$vps_lib" "$freedom_lib"' EXIT
sed '/^handle_cli "\$@"/,$d' freedom.sh > "$freedom_lib"
# shellcheck source=/dev/null
source "$freedom_lib"
if ip_to_int 08.8.8.8 >/dev/null 2>&1; then fail 'freedom.sh ip_to_int accepted ambiguous leading-zero IPv4'; fi
if validate_link_host 08.8.8.8 >/dev/null 2>&1; then fail 'freedom.sh validate_link_host accepted ambiguous leading-zero IPv4'; fi
validate_link_host 1.2.3.4 || fail 'freedom.sh validate_link_host rejected IPv4'
validate_link_host example.com || fail 'freedom.sh validate_link_host rejected domain'
validate_link_host 2001:4860:4860::8888 || fail 'freedom.sh validate_link_host rejected IPv6'
is_private_or_local_ip fe90::1 || fail 'freedom.sh missed IPv6 link-local fe80::/10 boundary'
is_private_or_local_ip febf::1 || fail 'freedom.sh missed upper IPv6 link-local fe80::/10 boundary'
is_private_or_local_ip fc00::1 || fail 'freedom.sh missed IPv6 ULA fc00::/7'
is_private_or_local_ip fdff::1 || fail 'freedom.sh missed upper IPv6 ULA fc00::/7 boundary'
is_private_or_local_ip ff02::1 || fail 'freedom.sh missed IPv6 multicast ff00::/8'
if is_private_or_local_ip fe7f::1; then fail 'freedom.sh overmatched IPv6 address below fe80::/10'; fi
if is_private_or_local_ip fc::1; then fail 'freedom.sh overmatched fc:: outside fc00::/7'; fi
if is_private_or_local_ip 2606:4700:4700::1111; then fail 'freedom.sh classified public IPv6 as non-global'; fi
tls_ping_sample="Pinging with SNI
TLS Post-Quantum key exchange: true (X25519MLKEM768)
Certificate chain's total length: 3688 (certs count: 3)"
[ "$(tls_ping_sni_chain_length "$tls_ping_sample")" = "3688" ] || fail 'freedom.sh failed to parse Xray TLS ping SNI chain length'
tls_ping_sni_has_pq_kex "$tls_ping_sample" || fail 'freedom.sh failed to parse Xray TLS ping post-quantum KEX result'
if tls_ping_sni_has_pq_kex "${tls_ping_sample/true/false}"; then fail 'freedom.sh treated a non-PQ REALITY target as post-quantum'; fi
[ "$(parse_asn_response '{"asn":13335,"asn_organization":"Cloudflare, Inc."}')" = '13335|Cloudflare, Inc.' ] || fail 'freedom.sh failed to parse ASN lookup response'
reality_port_is_standard 443 || fail 'freedom.sh must accept REALITY TCP/443 as standard'
if reality_port_is_standard 8443; then fail 'freedom.sh treated non-443 REALITY port as standard'; fi
if (DEPLOY_MODE=reality; PORT=8443; NONINTERACTIVE=1; ALLOW_NONSTANDARD_REALITY_PORT=0; enforce_reality_port_policy) >/dev/null 2>&1; then
  fail 'freedom.sh allowed non-443 REALITY without an explicit override'
fi
(DEPLOY_MODE=reality; PORT=8443; NONINTERACTIVE=1; ALLOW_NONSTANDARD_REALITY_PORT=1; enforce_reality_port_policy) >/dev/null 2>&1 \
  || fail 'freedom.sh rejected an explicit non-443 REALITY override'
(ASN_CHECK=1; LAST_SNI_REMOTE_IP=8.8.8.8; get_public_ip() { echo 1.1.1.1; }; lookup_ip_asn() { echo '13335|test-asn'; }; check_reality_target_asn example.com) >/dev/null 2>&1 \
  || fail 'freedom.sh rejected a mocked same-ASN REALITY target'
if (ASN_CHECK=1; LAST_SNI_REMOTE_IP=8.8.8.8; get_public_ip() { echo 1.1.1.1; }; lookup_ip_asn() { if [ "$1" = 1.1.1.1 ]; then echo '13335|one'; else echo '15169|two'; fi; }; check_reality_target_asn example.com) >/dev/null 2>&1; then
  fail 'freedom.sh treated different mocked ASNs as a preferred REALITY target'
fi
xray_help_sample=$'The commands are:\n\trun Run Xray\n\tuuid Generate UUID\n\tx25519 Generate key pair\n\tvlessenc Generate pair'
[ "$(missing_xray_capabilities "$xray_help_sample" run uuid x25519 vlessenc)" = '' ] || fail 'freedom.sh capability detector rejected available commands'
[ "$(missing_xray_capabilities "$xray_help_sample" run uuid mldsa65)" = 'mldsa65' ] || fail 'freedom.sh capability detector missed unavailable command'
[ "$(normalize_deploy_mode 1)" = "reality" ] || fail 'freedom.sh normalize_deploy_mode rejected 1'
[ "$(normalize_deploy_mode cdn)" = "cdn-xhttp-tls" ] || fail 'freedom.sh normalize_deploy_mode rejected cdn'
[ "$(normalize_deploy_mode XHTTP-TLS)" = "cdn-xhttp-tls" ] || fail 'freedom.sh normalize_deploy_mode rejected XHTTP-TLS'
[ "$(normalize_tls_cert_mode 1)" = "public" ] || fail 'freedom.sh normalize_tls_cert_mode rejected 1'
[ "$(normalize_tls_cert_mode 2)" = "cloudflare-origin" ] || fail 'freedom.sh normalize_tls_cert_mode rejected 2'
[ "$(normalize_tls_cert_mode cf-origin)" = "cloudflare-origin" ] || fail 'freedom.sh normalize_tls_cert_mode rejected cf-origin'
[ "$(normalize_tls_cert_mode PUBLIC)" = "public" ] || fail 'freedom.sh normalize_tls_cert_mode rejected PUBLIC'
if normalize_tls_cert_mode maybe >/dev/null 2>&1; then fail 'freedom.sh normalize_tls_cert_mode accepted invalid mode'; fi
[ "$(normalize_xhttp_transport_profile 1)" = "cdn-stable" ] || fail 'freedom.sh transport profile rejected 1'
[ "$(normalize_xhttp_transport_profile 2)" = "cdn-h2" ] || fail 'freedom.sh transport profile rejected 2'
[ "$(normalize_xhttp_transport_profile 3)" = "cdn-h3" ] || fail 'freedom.sh transport profile rejected 3'
[ "$(normalize_xhttp_transport_profile 4)" = "direct-h3" ] || fail 'freedom.sh transport profile rejected 4'
[ "$(normalize_xhttp_transport_profile H3)" = "direct-h3" ] || fail 'freedom.sh legacy H3 profile must preserve direct-H3 behavior'
if normalize_xhttp_transport_profile h4 >/dev/null 2>&1; then fail 'freedom.sh transport profile accepted invalid mode'; fi
validate_xhttp_path /cdn-abc123 || fail 'freedom.sh validate_xhttp_path rejected valid path'
if validate_xhttp_path / >/dev/null 2>&1; then fail 'freedom.sh validate_xhttp_path accepted root path'; fi
if validate_xhttp_path cdn-abc >/dev/null 2>&1; then fail 'freedom.sh validate_xhttp_path accepted path without slash'; fi
if validate_xhttp_path '/bad path' >/dev/null 2>&1; then fail 'freedom.sh validate_xhttp_path accepted path with spaces'; fi
[ "$(xhttp_origin_alpn_json cdn-stable)" = '["h2","http/1.1"]' ] || fail 'freedom.sh stable origin ALPN drifted'
[ "$(xhttp_origin_alpn_json cdn-h3)" = '["h2","http/1.1"]' ] || fail 'freedom.sh CDN-H3 must retain a TCP H1/H2 origin'
[ "$(xhttp_client_alpn_json cdn-h3)" = '["h3"]' ] || fail 'freedom.sh CDN-H3 client ALPN drifted'
[ "$(xhttp_origin_alpn_json direct-h3)" = '["h3"]' ] || fail 'freedom.sh direct-H3 origin ALPN drifted'
DEPLOY_MODE=reality
XHTTP_TRANSPORT_PROFILE=cdn-stable
[ "$(listener_protocol)" = "tcp" ] || fail 'freedom.sh listener_protocol must use TCP for REALITY'
DEPLOY_MODE=cdn-xhttp-tls
XHTTP_TRANSPORT_PROFILE=cdn-h3
[ "$(listener_protocol)" = "tcp" ] || fail 'freedom.sh CDN-H3 origin listener must use TCP'
XHTTP_TRANSPORT_PROFILE=direct-h3
[ "$(listener_protocol)" = "udp" ] || fail 'freedom.sh direct-H3 listener must use UDP'
[ "$(routing_domain_strategy compatible)" = "AsIs" ] || fail 'freedom.sh compatible route profile drifted'
[ "$(routing_domain_strategy strict)" = "IPIfNonMatch" ] || fail 'freedom.sh strict route profile drifted'
cloudflare_https_port_supported 443 || fail 'freedom.sh must accept Cloudflare HTTPS port 443'
if cloudflare_https_port_supported 444; then fail 'freedom.sh accepted unsupported Cloudflare HTTPS port 444'; fi
DEPLOY_MODE=cdn-xhttp-tls
UUID=11111111-1111-4111-8111-111111111111
SERVER_HOST_FOR_LINK=example.com
PORT=443
SNI=cdn.example.com
XHTTP_PATH=/cdn-test
XHTTP_CLIENT_ALPN_JSON='["h2","http/1.1"]'
VLESS_ENC=none
NODE_NAME=test-node
cdn_link="$(build_link)"
printf '%s\n' "$cdn_link" | grep -q 'type=xhttp' || fail 'freedom.sh CDN link missing type=xhttp'
printf '%s\n' "$cdn_link" | grep -q 'security=tls' || fail 'freedom.sh CDN link missing security=tls'
printf '%s\n' "$cdn_link" | grep -q 'path=%2Fcdn-test' || fail 'freedom.sh CDN link must URL-encode XHTTP path'
printf '%s\n' "$cdn_link" | grep -q 'alpn=h2%2Chttp%2F1.1' || fail 'freedom.sh CDN link must URL-encode ALPN list'
printf '%s\n' "$cdn_link" | grep -q 'mode=auto' || fail 'freedom.sh CDN link missing mode=auto'
printf '%s\n' "$cdn_link" | grep -q 'flow=xtls-rprx-vision' || fail 'freedom.sh CDN link missing Vision flow'
XHTTP_CLIENT_ALPN_JSON='["h3"]'
cdn_h3_link="$(build_link)"
printf '%s\n' "$cdn_h3_link" | grep -q 'alpn=h3' || fail 'freedom.sh CDN-H3 link must request H3 at the client/CDN edge'

cert_dir="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=cdn.example.com' -addext 'subjectAltName=DNS:other.example.com' \
  -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" >/dev/null 2>&1
if cert_covers_domain "$cert_dir/cert.pem" cdn.example.com; then
  fail 'freedom.sh certificate matcher ignored a conflicting SAN and fell back to CN'
fi
cert_covers_domain "$cert_dir/cert.pem" other.example.com || fail 'freedom.sh certificate matcher rejected matching SAN'
TLS_CERT_FILE="$cert_dir/cert.pem"
TLS_KEY_FILE="$cert_dir/key.pem"
TLS_CERT_MODE=cloudflare-origin
SNI=''
check_tls_cert_files other.example.com || fail 'freedom.sh explicit certificate domain check failed'
rm -rf "$cert_dir"

rollback_dir="$(mktemp -d)"
CONFIG_PATH="$rollback_dir/config.json"
BACKUP_FILE="$rollback_dir/config.backup.json"
printf 'old\n' > "$BACKUP_FILE"
printf 'new\n' > "$CONFIG_PATH"
SERVICE_NAME=xray
NONINTERACTIVE=1
CONFIG_WRITTEN_THIS_RUN=1
service_unit_exists() { return 1; }
if (fatal_with_rollback 'forced rollback test') >/dev/null 2>&1; then
  fail 'freedom.sh rollback failure path unexpectedly succeeded'
fi
[ "$(cat "$CONFIG_PATH")" = "old" ] || fail 'freedom.sh non-interactive rollback did not restore the previous config'
BACKUP_FILE=''
printf 'new\n' > "$CONFIG_PATH"
if (fatal_with_rollback 'forced first-deploy failure test') >/dev/null 2>&1; then
  fail 'freedom.sh first-deploy failure path unexpectedly succeeded'
fi
[ ! -e "$CONFIG_PATH" ] || fail 'freedom.sh failed first deployment did not remove the new config'
rm -rf "$rollback_dir"
expect_rc 2 bash ./freedom.sh --sni
expect_rc 2 bash ./freedom.sh --sni --no-qr
expect_rc 2 bash ./freedom.sh --port --sni example.com
expect_rc 2 bash ./freedom.sh --xray-encryption
expect_rc 2 bash ./freedom.sh --xray-encryption --no-qr
expect_rc 2 bash ./freedom.sh --mode
expect_rc 2 bash ./freedom.sh --mode invalid
expect_rc 2 bash ./freedom.sh --xhttp-path
expect_rc 2 bash ./freedom.sh --tls-cert-file
expect_rc 2 bash ./freedom.sh --tls-key-file
expect_rc 2 bash ./freedom.sh --tls-cert-mode invalid
expect_rc 2 bash ./freedom.sh --xhttp-alpn invalid
expect_rc 2 bash ./freedom.sh --xhttp-profile invalid
expect_rc 2 bash ./freedom.sh --route-profile invalid
expect_rc 2 bash ./freedom.sh --allow-nonstandard-reality-port=value
expect_rc 2 bash ./freedom.sh --update-xray=value

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck vps_init_tool.sh verify.sh
  shellcheck -S error freedom.sh xray-1stream-dat.sh
else
  printf '[WARN] shellcheck not found; skipped shellcheck lint.\n'
fi

printf '[OK] verification passed\n'
