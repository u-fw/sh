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

check_contains vps_init_tool.sh 'TOOL_VERSION="1\.0\.4"' 'vps_init_tool.sh version drifted'
check_not_contains vps_init_tool.sh '3x-ui|x-ui|1stream\.dat' 'vps_init_tool.sh must stay focused on generic VPS initialization'
check_contains vps_init_tool.sh 'handle_cli\(\)' 'vps_init_tool.sh missing CLI dispatcher'
check_contains vps_init_tool.sh 'Missing value for --lang' 'vps_init_tool.sh CLI must report a missing --lang value'
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
check_contains vps_init_tool.sh 'if \[ "\$max_by_disk_mb" -lt 512 \]; then echo "0M"; return 0; fi' 'vps_init_tool.sh must skip swapfile recommendation when disk space is too low'
check_contains vps_init_tool.sh 'valid_size_mb_gb\(\)' 'vps_init_tool.sh missing size validation helper'
check_contains vps_init_tool.sh 'valid_uint_range\(\)' 'vps_init_tool.sh missing numeric range validation helper'
check_contains vps_init_tool.sh 'Invalid swapfile size' 'vps_init_tool.sh must reject invalid swapfile sizes'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/99-memory-tuning\.conf' 'vps_init_tool.sh must apply and validate its memory sysctl file directly'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/90-bbr\.conf' 'vps_init_tool.sh must apply and validate its BBR sysctl file directly'
check_contains vps_init_tool.sh 'sysctl -p /etc/sysctl\.d/99-proxy-tuning\.conf' 'vps_init_tool.sh must apply and validate its proxy sysctl file directly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/99-memory-tuning\.conf >/dev/null; then' 'vps_init_tool.sh memory sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/90-bbr\.conf >/dev/null; then' 'vps_init_tool.sh BBR sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'if ! sysctl -p /etc/sysctl\.d/99-proxy-tuning\.conf >/dev/null; then' 'vps_init_tool.sh proxy sysctl failures must propagate explicitly'
check_contains vps_init_tool.sh 'restore_managed_file "\$config_file" "\$config_backup"' 'vps_init_tool.sh persistent configuration failures must restore the previous file'
check_not_contains vps_init_tool.sh 'sysctl --system >/dev/null \|\| true' 'vps_init_tool.sh must not hide sysctl application failures'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-zram-setup@zram0\.service 2>/dev/null \|\| systemctl start systemd-zram-setup@zram0\.service 2>/dev/null \|\| true' 'vps_init_tool.sh must not hide zram-generator activation failures'
check_not_contains vps_init_tool.sh 'systemctl restart zramswap\.service 2>/dev/null \|\| systemctl restart zram-config\.service 2>/dev/null \|\| true' 'vps_init_tool.sh must not hide zram-tools activation failures'
check_contains vps_init_tool.sh '--baseline' 'vps_init_tool.sh missing low-risk baseline CLI'
check_contains vps_init_tool.sh '--preflight' 'vps_init_tool.sh missing read-only preflight CLI'
check_contains vps_init_tool.sh 'preflight_check\(\)' 'vps_init_tool.sh missing read-only preflight helper'
check_contains vps_init_tool.sh '--preflight\) preflight_check; exit 0 ;;' 'vps_init_tool.sh preflight must run before root-only CLI gates'
check_contains vps_init_tool.sh 'low_risk_baseline "cli"' 'vps_init_tool.sh CLI baseline must use explicit cli mode'
check_not_exact_line vps_init_tool.sh '  setup_swapfile || true' 'vps_init_tool.sh low-risk baseline must not recreate swapfile automatically'
check_not_exact_line vps_init_tool.sh '  setup_zram || true' 'vps_init_tool.sh low-risk baseline must not reconfigure ZRAM automatically'
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
check_contains vps_init_tool.sh 'local ports desired="" current="" adds="" deletes="" state_tmp=""' 'vps_init_tool.sh Cloudflare UFW temp paths must initialize empty before cleanup trap'
check_contains vps_init_tool.sh 'ufw_ensure_ssh_access \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh must cleanup Cloudflare UFW sync if SSH allow check fails'
check_contains vps_init_tool.sh 'cf_fetch_ranges \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh must cleanup Cloudflare UFW sync if Cloudflare ranges fetch fails'
check_contains vps_init_tool.sh 'desired="\$\(mktemp\)" \|\| \{ ufw_cf_sync_cleanup "\$desired"' 'vps_init_tool.sh Cloudflare UFW sync must cleanup if desired temp creation fails'
check_contains vps_init_tool.sh 'cleanup_files\(\)' 'vps_init_tool.sh missing temp-file cleanup helper'
check_contains vps_init_tool.sh 'rm -f -- "\$@"' 'vps_init_tool.sh cleanup helper must use rm -- for path safety'
check_contains vps_init_tool.sh 'v4_tmp="\$\(mktemp /var/lib/vps-init/cloudflare-ips-v4\.txt\.XXXXXX\)" \|\| return 1' 'vps_init_tool.sh Cloudflare v4 temp creation must fail safely'
check_contains vps_init_tool.sh 'v6_tmp="\$\(mktemp /var/lib/vps-init/cloudflare-ips-v6\.txt\.XXXXXX\)" \|\| \{ cleanup_files "\$v4_tmp"; return 1; \}' 'vps_init_tool.sh Cloudflare v6 temp creation must cleanup v4 temp on failure'
check_contains vps_init_tool.sh 'cleanup_files "\$v4_tmp" "\$v6_tmp"' 'vps_init_tool.sh Cloudflare range fetch must cleanup temp downloads on failure'
check_contains vps_init_tool.sh 'if ! mv "\$v4_tmp" /var/lib/vps-init/cloudflare-ips-v4.txt; then cleanup_files "\$v4_tmp" "\$v6_tmp"; return 1; fi' 'vps_init_tool.sh must cleanup temp Cloudflare v4 file if mv fails'
check_contains vps_init_tool.sh 'if ! mv "\$v6_tmp" /var/lib/vps-init/cloudflare-ips-v6.txt; then cleanup_files "\$v4_tmp" "\$v6_tmp"; return 1; fi' 'vps_init_tool.sh must cleanup temp Cloudflare v6 file if mv fails'
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
check_contains vps_init_tool.sh 'valid_ssh_public_key\(\)' 'vps_init_tool.sh missing SSH public key format validation helper'
check_contains vps_init_tool.sh 'valid_ssh_public_key "\$key"' 'vps_init_tool.sh must validate SSH public keys before installing'
check_contains vps_init_tool.sh 'group="\$\(id -gn "\$user" 2>/dev/null \|\| echo "\$user"\)"' 'vps_init_tool.sh must chown SSH keys using the user primary group'
check_contains vps_init_tool.sh 'SSH_CONNECTION' 'vps_init_tool.sh must include the current SSH session port when protecting firewall access'
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
check_contains vps_init_tool.sh '\[ -L /etc/resolv\.conf \]' 'vps_init_tool.sh must not directly overwrite a managed resolv.conf symlink'
check_contains vps_init_tool.sh 'dns_restore_resolved_backup\(\)' 'vps_init_tool.sh missing systemd-resolved rollback helper'
check_not_contains vps_init_tool.sh 'DNSSEC=no' 'vps_init_tool.sh must not force DNSSEC off'
check_contains vps_init_tool.sh 'valid_systemd_size\(\)' 'vps_init_tool.sh missing journald size validation helper'
check_contains vps_init_tool.sh 'valid_systemd_timespan\(\)' 'vps_init_tool.sh missing journald retention validation helper'
check_not_contains vps_init_tool.sh 'systemctl restart systemd-journald \|\| true' 'vps_init_tool.sh must not hide journald restart failures'
check_not_contains vps_init_tool.sh 'backup_path .* >/dev/null \|\| true' 'vps_init_tool.sh must not overwrite managed configuration after a failed backup'
check_not_contains vps_init_tool.sh 'ufw limit "\$p/tcp" comment "rate-limit-ssh" \|\| true' 'vps_init_tool.sh must not hide SSH rate-limit rule failures'
check_not_contains vps_init_tool.sh 'fail2ban-client set "\$jail" unbanip "\$ip" \|\| true' 'vps_init_tool.sh must not hide Fail2ban unban failures'

check_contains freedom.sh 'SCRIPT_VERSION="v9\.11-xray"' 'freedom.sh version drifted'
check_contains freedom.sh 'DEFAULT_SNI="v1-dy\.ixigua\.com"' 'freedom.sh default SNI drifted'
check_contains freedom.sh 'ensure_xray_installed\(\)' 'freedom.sh must install/configure Xray-core only'
check_contains freedom.sh 'write_xray_config\(\)' 'freedom.sh missing Xray config writer'
check_contains freedom.sh 'preflight_check\(\)' 'freedom.sh missing read-only preflight check'
check_contains freedom.sh 'validate_domain_name\(\)' 'freedom.sh missing SNI domain validator'
check_contains freedom.sh 'probe_sni_domain\(\)' 'freedom.sh missing SNI reachability probe'
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
check_contains freedom.sh 'ip_in_range\(\)' 'freedom.sh missing IPv4 CIDR range helper'
check_contains freedom.sh 'ip_in_range "\$ip_num"' 'freedom.sh private/local IPv4 detection must use numeric ranges'
check_contains freedom.sh 'is_private_or_local_ip\(\)' 'freedom.sh missing private/local IP detector'
check_contains freedom.sh 'auto_detected_server=1' 'freedom.sh must track auto-detected server address'
check_contains freedom.sh 'is_private_or_local_ip "\$SERVER_IP"' 'freedom.sh must reject private/local auto-detected server addresses'
check_contains freedom.sh '2001:db8' 'freedom.sh must treat IPv6 documentation addresses as non-public'
check_contains freedom.sh 'ff\*' 'freedom.sh must treat IPv6 multicast addresses as non-public'
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
check_contains freedom.sh 'verify_service_port_listening\(\)' 'freedom.sh missing post-restart port listener verification'
check_contains freedom.sh 'verify_service_port_listening' 'freedom.sh restart flow must verify the service port is listening'
check_contains freedom.sh 'not listening on TCP port' 'freedom.sh must report missing post-restart listener'
check_contains freedom.sh 'Xray config install failed' 'freedom.sh must handle config install failures explicitly'
check_contains freedom.sh 'if ! install -m 600 "\$tmp" "\$CONFIG_PATH"; then' 'freedom.sh config install must not rely on errexit'
check_contains freedom.sh 'fallback: xray -test -config' 'freedom.sh config validation must preserve fallback test diagnostics'
check_contains freedom.sh '\{"type":"field","ip":\["geoip:private"\],"outboundTag":"block"\}' 'freedom.sh route must block private IP first'
check_contains freedom.sh '\{"type":"field","protocol":\["bittorrent"\],"outboundTag":"block"\}' 'freedom.sh route must block bittorrent traffic through Xray'
check_contains freedom.sh '\{"type":"field","domain":\["geosite:geolocation-!cn"\],"outboundTag":"direct"\}' 'freedom.sh route must direct known non-CN domains before CN blocks'
check_contains freedom.sh '\{"type":"field","domain":\["geosite:cn"\],"outboundTag":"block"\}' 'freedom.sh route must block CN domains'
check_contains freedom.sh '\{"type":"field","ip":\["geoip:cn"\],"outboundTag":"block"\}' 'freedom.sh route must block CN IP'
check_not_contains freedom.sh '\{"type":"field","ip":\["geoip:private","geoip:cn"\],"outboundTag":"block"\}' 'freedom.sh route must keep private and CN IP blocks ordered separately'

check_not_contains freedom.sh 'sing-box|singbox|--kernel|FREEDOM_KERNEL|write_singbox_config|install_singbox_official|gen_reality_keys_singbox|choose_kernel' 'freedom.sh still contains sing-box/core-selection support'
check_not_contains freedom.sh '> "\$CONFIG_PATH"' 'freedom.sh must write config atomically instead of truncating config path directly'
check_not_contains freedom.sh 'chmod 644 "\$CONFIG_PATH"' 'freedom.sh must not make Xray config world-readable'
check_not_contains freedom.sh '/tmp/freedom-' 'freedom.sh must not use predictable /tmp log paths'
check_not_contains freedom.sh 'curl .*[|] sh' 'freedom.sh must not pipe installer downloads to sh'
check_not_contains freedom.sh 'bash -c "\$\(curl' 'freedom.sh must not execute downloaded installer inline'
check_not_contains freedom.sh 'xargs -r rm -f' 'freedom.sh backup cleanup must not use ls/xargs deletion'

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

valid_port 22 || fail 'valid_port rejected port 22'
if valid_port 0; then fail 'valid_port accepted port 0'; fi
valid_size_mb_gb 512M || fail 'valid_size_mb_gb rejected 512M'
if valid_size_mb_gb 1T; then fail 'valid_size_mb_gb accepted unsupported size 1T'; fi
valid_ip_literal 1.1.1.1 || fail 'valid_ip_literal rejected IPv4'
valid_ip_literal 2606:4700:4700::1111 || fail 'valid_ip_literal rejected IPv6'
if valid_ip_literal 999.1.1.1; then fail 'valid_ip_literal accepted invalid IPv4'; fi

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

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck vps_init_tool.sh verify.sh
  shellcheck -S error freedom.sh xray-1stream-dat.sh
else
  printf '[WARN] shellcheck not found; skipped shellcheck lint.\n'
fi

printf '[OK] verification passed\n'
