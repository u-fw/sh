#!/usr/bin/env bash
set -Eeuo pipefail

# VPS Init Tool v1.2.1
# Debian/Ubuntu VPS bootstrap, audit and maintenance helper.
# Scope: memory, SSH, UFW firewall, Fail2ban, DNS, logs, basic network tuning.
# Principle: audit first, confirm before risky changes.

TOOL_VERSION="1.2.1"
SCRIPT_NAME="VPS Init Tool"
BACKUP_ROOT="/root/vps-init-backups"
SWAPFILE="/swapfile"
AUTO_UPGRADES_CONFIG="/etc/apt/apt.conf.d/52-vps-init-auto-upgrades"
CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
UFW_CF_STATE_FILE="/var/lib/vps-init/cloudflare-ufw-managed.tsv"
UFW_CF_LOCK_FILE="/var/lib/vps-init/cloudflare-ufw.lock"
UFW_CF_IPV4_FILE="${VPS_INIT_CF_IPV4_FILE:-/var/lib/vps-init/cloudflare-ips-v4.txt}"
UFW_CF_IPV6_FILE="${VPS_INIT_CF_IPV6_FILE:-/var/lib/vps-init/cloudflare-ips-v6.txt}"
UFW_CF_LOCK_TIMEOUT="${VPS_INIT_CF_LOCK_TIMEOUT:-120}"
SSH_HARDENING_FRAGMENT="/etc/ssh/sshd_config.d/00-vps-init-hardening.conf"
LOG_FILE="${VPS_INIT_LOG:-/var/log/vps-init-tool.log}"
APT_LOCK_TIMEOUT="${VPS_INIT_APT_LOCK_TIMEOUT:-120}"
APT_RETRIES="${VPS_INIT_APT_RETRIES:-3}"
LANG_MODE="${VPS_INIT_LANG:-en}"
ASSUME_YES="${VPS_INIT_YES:-0}"
NONINTERACTIVE=0
UFW_CF_PORTS="${VPS_INIT_CF_PORTS:-}"
UFW_CF_LOCK_FD=""
BACKUP_LAST_PATH=""

# ---------- i18n / UI ----------
normalize_lang() {
  case "${1:-}" in
    zh|zh-cn|zh_CN|cn|CN|chinese|Chinese) echo "en" ;;
    en|EN|english|English) echo "en" ;;
    *) echo "en" ;;
  esac
}

m() {
  # m "English" "Chinese"
  if [ "${LANG_MODE:-en}" = "cn" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

red() { printf '[BAD] %s\n' "$*"; }
green() { printf '[OK] %s\n' "$*"; }
yellow() { printf '[WARN] %s\n' "$*"; }
blue() { printf '%s\n' "$*"; }
muted() { printf '%s\n' "$*"; }

term_width() {
  local w
  w="$(tput cols 2>/dev/null || echo 88)"
  [ "$w" -gt 120 ] && w=120
  [ "$w" -lt 72 ] && w=72
  echo "$w"
}

hr() {
  local w
  w="$(term_width)"
  printf '%*s\n' "$w" '' | tr ' ' '-'
}

title() {
  echo
  hr
  blue "$1"
  hr
}

section() {
  echo
  blue "[$1]"
  printf '%s\n' '------------------------------------------'
}

kv() {
  local k="$1" v="${2:-}"
  printf '  %-30s %s\n' "$k" "$v"
}

status_ok() { printf '  %-8s %s\n' "OK" "$*"; }
status_warn() { printf '  %-8s %s\n' "WARN" "$*"; }
status_bad() { printf '  %-8s %s\n' "BAD" "$*"; }
status_info() { printf '  %-8s %s\n' "INFO" "$*"; }
print_block() { sed 's/^/    /'; }

cleanup_files() {
  [ "$#" -eq 0 ] || rm -f -- "$@"
}

log_action() {
  local action="$1" detail="${2:-}"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s action=%s user=%s detail=%s\n' \
    "$(date '+%F %T %Z')" "$action" "$(id -un 2>/dev/null || echo unknown)" "$detail" >> "$LOG_FILE" 2>/dev/null || true
}

clear_screen() { clear 2>/dev/null || true; }

pause() {
  echo
  read -r -p "$(m 'Press Enter to continue...' 'Press Enter to continue...')" _ || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_systemd() { has_cmd systemctl && [ -d /run/systemd/system ]; }

require_systemd() {
  is_systemd && return 0
  red "$(m 'systemd is required for this module; use read-only audit on non-systemd systems.' 'systemd is required for this module; use read-only audit on non-systemd systems.')"
  return 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    red "$(m "Please run as root: sudo bash $0" "Please run as root: sudo bash $0")"
    exit 1
  fi
}

choose_language() {
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  if [ -t 0 ] && [ -z "${VPS_INIT_LANG:-}" ]; then
    echo "Language / language:"
    echo "1) English"
    echo "2) Chinese alias (English-safe fallback)"
    read -r -p "Choose [1/2, default 1]: " ans || true
    case "$ans" in
      2|cn|CN|zh|chinese|Chinese) LANG_MODE="en" ;;
      *) LANG_MODE="en" ;;
    esac
  fi
}

load_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    ID="unknown"; PRETTY_NAME="unknown"
  fi
}

package_manager_detect() {
  if has_cmd apt-get; then echo "apt"; return 0; fi
  if has_cmd dnf; then echo "dnf"; return 0; fi
  if has_cmd yum; then echo "yum"; return 0; fi
  if has_cmd apk; then echo "apk"; return 0; fi
  echo "unknown"
}

os_support_level() {
  load_os_release
  case "${ID:-}" in
    debian|ubuntu) echo "full" ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) echo "derivative-audit" ;;
        *) echo "audit-only" ;;
      esac
      ;;
  esac
}

require_debian_family() {
  load_os_release
  case "${ID:-}" in
    debian|ubuntu) return 0 ;;
    *)
      red "$(m "Mutating commands officially support Debian and Ubuntu only. Detected: ${PRETTY_NAME:-unknown}" "Mutating commands officially support Debian and Ubuntu only. Detected: ${PRETTY_NAME:-unknown}")"
      if [ "$(os_support_level)" = "derivative-audit" ]; then
        status_info "$(m 'A Debian/Ubuntu derivative was detected; read-only audit commands remain available.' 'A Debian/Ubuntu derivative was detected; read-only audit commands remain available.')"
      fi
      exit 1
      ;;
  esac
}

confirm_yes() {
  local prompt="$1" ans
  case "${ASSUME_YES:-0}" in
    1|yes|YES|true|TRUE)
      status_info "$(m "Auto-confirmed: $prompt" "Auto-confirmed: $prompt")"
      return 0
      ;;
  esac
  echo
  yellow "$prompt"
  if [ "${NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    status_warn "$(m 'Confirmation required; use --yes or VPS_INIT_YES=1 for non-interactive execution.' 'Confirmation required; use --yes or VPS_INIT_YES=1 for non-interactive execution.')"
    return 1
  fi
  read -r -p "$(m 'Type YES to continue: ' 'Type YES to continue: ')" ans || true
  [ "$ans" = "YES" ]
}

input_default() {
  local prompt="$1" default="$2" value
  if [ "${NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    printf '%s\n' "$default"
    return 0
  fi
  read -r -p "$prompt [$default]: " value || true
  printf '%s\n' "${value:-$default}"
}

normalize_yes_no() {
  case "${1:-}" in
    y|Y|yes|YES|Yes) printf 'yes\n' ;;
    n|N|no|NO|No) printf 'no\n' ;;
    *) return 1 ;;
  esac
}

input_yes_no() {
  local prompt="$1" default="$2" value normalized_default
  normalized_default="$(normalize_yes_no "$default")" || return 1
  if [ "${NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    printf '%s\n' "$normalized_default"
    return 0
  fi
  while true; do
    read -r -p "$prompt [$normalized_default, y/n]: " value || true
    value="${value:-$normalized_default}"
    if normalize_yes_no "$value"; then
      return 0
    fi
    red "$(m 'Please enter y or n.' 'Please enter y or n.')"
  done
}

normalize_password_policy() {
  case "${1:-}" in
    keep|KEEP|Keep|k|K) printf 'keep\n' ;;
    no|NO|No|n|N) printf 'no\n' ;;
    yes|YES|Yes|y|Y) printf 'yes\n' ;;
    *) return 1 ;;
  esac
}

valid_permit_root_login() {
  case "${1:-}" in
    yes|prohibit-password|without-password|forced-commands-only|no) return 0 ;;
    *) return 1 ;;
  esac
}

valid_allow_users_value() {
  local value="${1:-}" item count=0
  [ -n "$value" ] || return 0
  for item in $value; do
    [[ "$item" =~ ^[A-Za-z0-9._@%*?+-]+$ ]] || return 1
    count=$((count + 1))
  done
  [ "$count" -gt 0 ]
}

make_backup_dir() { mkdir -p "$BACKUP_ROOT"; }
backup_path() {
  local p="$1" safe dest
  BACKUP_LAST_PATH=""
  [ -e "$p" ] || return 0
  make_backup_dir
  safe="$(echo "$p" | sed 's#/#_#g; s#^_##')"
  dest="$BACKUP_ROOT/${safe}.$(date +%F-%H%M%S-%N).bak"
  cp -a "$p" "$dest"
  BACKUP_LAST_PATH="$dest"
  echo "Backup: $dest"
}

restore_managed_file() {
  local target="$1" backup="${2:-}"
  if [ -n "$backup" ] && [ -e "$backup" ]; then
    cp -a "$backup" "$target"
  else
    rm -f "$target"
  fi
}

restore_sysctl_file() {
  local config_file="$1"
  [ -e "$config_file" ] || return 0
  sysctl -p "$config_file" >/dev/null 2>&1 || status_warn "$(m "Failed to re-apply restored sysctl file: $config_file" "Failed to re-apply restored sysctl file: $config_file")"
}

# ---------- package helpers ----------
apt_update_done=0
apt_get_retry() {
  local attempt=1 delay=3 rc=0 errexit_was_set=0
  while true; do
    errexit_was_set=0
    case "$-" in
      *e*) errexit_was_set=1; set +e ;;
    esac
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT:-120}" \
      -o "Acquire::Retries=3" \
      "$@"
    rc=$?
    [ "$errexit_was_set" -eq 1 ] && set -e
    [ "$rc" -eq 0 ] && return 0
    [ "$attempt" -ge "${APT_RETRIES:-3}" ] && break
    yellow "$(m "apt-get $* failed with rc=$rc; retrying in ${delay}s..." "apt-get $* failed with rc=$rc; retrying in ${delay}s...")"
    log_action "apt" "command=$* attempt=$attempt rc=$rc"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  log_action "apt" "command=$* failed rc=$rc"
  return "$rc"
}

apt_update_once() {
  if [ "$apt_update_done" -eq 0 ]; then
    apt_get_retry update || return 1
    apt_update_done=1
  fi
}

apt_install() {
  apt_update_once || return 1
  apt_get_retry install -y "$@"
}

# ---------- common helpers ----------
get_mem_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
get_root_avail_mb() { df -Pm / | awk 'NR==2 {print $4}'; }

parse_size_to_mb() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $((BASH_REMATCH[1] * 1024)); return 0; fi
  if [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "$s" =~ ^([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

valid_port_or_range() {
  local value="$1" start end
  if [[ "$value" =~ ^([0-9]+)$ ]]; then
    valid_port "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^([0-9]+):([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    valid_port "$start" && valid_port "$end" && ((10#$start <= 10#$end))
  else
    return 1
  fi
}

valid_proto() {
  case "${1:-}" in
    tcp|udp) return 0 ;;
    *) return 1 ;;
  esac
}

valid_size_mb_gb() {
  [[ "${1:-}" =~ ^[1-9][0-9]*([MmGg])?$ ]]
}

valid_uint_range() {
  local value="${1:-}" min="$2" max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] && ((10#$value >= min && 10#$value <= max))
}

valid_positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

valid_fail2ban_time() {
  [[ "${1:-}" =~ ^-1$|^[0-9]+[smhdw]?$ ]]
}

valid_ipv4_literal() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

valid_ipv6_literal() {
  local ip="$1" left right part count_left count_right total
  local -a left_parts right_parts parts
  [[ -n "$ip" && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$ip" != *:::* ]] || return 1
  if [[ "$ip" == *::* ]]; then
    [[ "${ip#*::}" != *::* ]] || return 1
    left="${ip%%::*}"
    right="${ip#*::}"
    count_left=0
    count_right=0
    if [[ -n "$left" ]]; then
      IFS=: read -ra left_parts <<< "$left"
      for part in "${left_parts[@]}"; do [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; count_left=$((count_left + 1)); done
    fi
    if [[ -n "$right" ]]; then
      IFS=: read -ra right_parts <<< "$right"
      for part in "${right_parts[@]}"; do [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; count_right=$((count_right + 1)); done
    fi
    total=$((count_left + count_right))
    ((total < 8))
    return $?
  fi
  IFS=: read -ra parts <<< "$ip"
  [ "${#parts[@]}" -eq 8 ] || return 1
  for part in "${parts[@]}"; do [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
}

valid_ip_literal() {
  valid_ipv4_literal "$1" || valid_ipv6_literal "$1"
}

valid_ip_or_cidr() {
  local value="$1" addr prefix
  if [[ "$value" == */* ]]; then
    addr="${value%/*}"
    prefix="${value##*/}"
    if [[ "$addr" == *:* ]]; then
      valid_ipv6_literal "$addr" && valid_uint_range "$prefix" 0 128
    else
      valid_ipv4_literal "$addr" && valid_uint_range "$prefix" 0 32
    fi
    return $?
  fi
  valid_ip_literal "$value"
}

valid_ip_list() {
  local list="$1" ip count=0
  for ip in $list; do
    valid_ip_literal "$ip" || return 1
    count=$((count + 1))
  done
  [ "$count" -gt 0 ]
}

valid_systemd_size() {
  [[ "${1:-}" =~ ^[0-9]+[KMGTP]?$ ]]
}

valid_systemd_timespan() {
  [[ "${1:-}" =~ ^[0-9]+(s|min|h|day|week|month|year)$ ]]
}

apt_config_value_from_text() {
  local text="$1" key="$2"
  awk -v key="$key" '
    $1 == key {
      value=$2
      sub(/^"/, "", value)
      sub(/";$/, "", value)
      print value
      exit
    }
  ' <<< "$text"
}

listening_ports_compact() {
  local tmp
  tmp="$(mktemp)"
  if ss -tulpen >"$tmp" 2>/dev/null; then
    awk '
      NR==1 {printf "%-5s %-7s %-24s %-36s %s\n", "Proto", "State", "Local", "Process", "Extra"; next}
      {
        proto=$1; state=$2; local=$5; proc="-"; extra="";
        if (match($0, /users:\(\([^)]*\)\)/)) {
          proc=substr($0, RSTART, RLENGTH);
          gsub(/^users:\(\(/, "", proc);
          gsub(/\)\)$/, "", proc);
        }
        if (match($0, /uid:[0-9]+/)) extra=substr($0, RSTART, RLENGTH);
        printf "%-5s %-7s %-24s %-36s %s\n", proto, state, local, proc, extra;
      }
    ' "$tmp" | sed -n '1,80p'
    rm -f "$tmp"
  else
    rm -f "$tmp"
    ss -tuln 2>/dev/null | sed -n '1,80p' || true
  fi
}

# ---------- recommendations ----------
recommend_swap_size() {
  local mem_mb avail_mb rec_mb max_by_disk_mb
  mem_mb="$(get_mem_mb)"
  avail_mb="$(get_root_avail_mb)"
  max_by_disk_mb="$((avail_mb * 75 / 100))"

  if [ "$mem_mb" -le 1024 ]; then rec_mb=1024
  elif [ "$mem_mb" -le 2048 ]; then rec_mb=2048
  elif [ "$mem_mb" -le 4096 ]; then rec_mb=2048
  elif [ "$mem_mb" -le 8192 ]; then rec_mb=4096
  else rec_mb=4096
  fi

  if [ "$max_by_disk_mb" -lt 512 ]; then echo "0M"; return 0; fi
  if [ "$max_by_disk_mb" -lt "$rec_mb" ]; then rec_mb="$max_by_disk_mb"; fi
  echo "${rec_mb}M"
}

recommend_zram_size() {
  local mem_mb rec_mb
  mem_mb="$(get_mem_mb)"
  if [ "$mem_mb" -le 1024 ]; then rec_mb=512
  elif [ "$mem_mb" -le 2048 ]; then rec_mb=1024
  elif [ "$mem_mb" -le 4096 ]; then rec_mb=1536
  elif [ "$mem_mb" -le 8192 ]; then rec_mb=2048
  else rec_mb=4096
  fi
  echo "${rec_mb}M"
}

recommend_swappiness() {
  local mem_mb
  mem_mb="$(get_mem_mb)"
  if [ "$mem_mb" -le 4096 ]; then echo 10; else echo 1; fi
}

apply_memory_sysctl() {
  local swappiness="${1:-10}" vfs_cache_pressure="${2:-50}"
  local config_file="/etc/sysctl.d/99-memory-tuning.conf" config_backup=""
  valid_uint_range "$swappiness" 0 200 || { red "$(m 'Invalid vm.swappiness. Use 0-200.' 'Invalid vm.swappiness. Use 0-200.')"; return 1; }
  valid_uint_range "$vfs_cache_pressure" 0 1000 || { red "$(m 'Invalid vm.vfs_cache_pressure. Use 0-1000.' 'Invalid vm.vfs_cache_pressure. Use 0-1000.')"; return 1; }
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<EOF2 || return 1
vm.swappiness=$swappiness
vm.vfs_cache_pressure=$vfs_cache_pressure
EOF2
  if ! sysctl -p /etc/sysctl.d/99-memory-tuning.conf >/dev/null; then
    red "$(m 'Failed to apply memory sysctl settings. Restoring the previous configuration.' 'Failed to apply memory sysctl settings. Restoring the previous configuration.')"
    restore_managed_file "$config_file" "$config_backup"
    restore_sysctl_file "$config_file"
    return 1
  fi
}

# ---------- system / audit ----------
basic_tools_missing() {
  local cmd missing=()
  for cmd in curl jq openssl lsof dig ss flock rsync unzip; do
    has_cmd "$cmd" || missing+=("$cmd")
  done
  if [ ! -d /etc/ssl/certs ]; then missing+=("ca-certificates"); fi
  printf '%s\n' "${missing[*]:-}"
}

install_essential_tools() {
  blue "$(m 'Installing essential administration tools...' 'Installing essential administration tools...')"
  apt_install \
    curl ca-certificates jq openssl lsof dnsutils iproute2 util-linux rsync unzip || return 1
  green "$(m 'Essential administration tools installed.' 'Essential administration tools installed.')"
}

install_basic_tools() {
  blue "$(m 'Installing basic tools...' 'Installing basic tools...')"
  apt_install \
    curl wget ca-certificates gnupg lsb-release apt-transport-https \
    vim nano less unzip zip tar gzip xz-utils zstd \
    jq sqlite3 cron socat lsof \
    dnsutils iproute2 net-tools \
    htop iotop sysstat \
    openssl rsync screen tmux || return 1

  if is_systemd; then
    systemctl enable cron >/dev/null 2>&1 || status_warn "$(m 'Failed to enable cron service; scheduled jobs may not run after reboot.' 'Failed to enable cron service; scheduled jobs may not run after reboot.')"
    systemctl enable sysstat >/dev/null 2>&1 || status_warn "$(m 'Failed to enable sysstat service; historical system metrics may be unavailable after reboot.' 'Failed to enable sysstat service; historical system metrics may be unavailable after reboot.')"
  fi
  green "$(m 'Basic tools installed.' 'Basic tools installed.')"
}

show_system_status() {
  load_os_release
  title "$(m 'System Status' 'System Status')"
  kv "Tool" "$SCRIPT_NAME $TOOL_VERSION"
  kv "Language" "$LANG_MODE"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Kernel" "$(uname -r)"
  kv "Arch" "$(uname -m)"
  kv "Hostname" "$(hostname)"
  kv "Systemd" "$(is_systemd && echo yes || echo no)"

  section "$(m 'Memory / Swap' 'Memory / Swap')"
  free -h | print_block || true
  echo
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true

  section "$(m 'Disk' 'Disk')"
  df -hT / | print_block || true

  section "$(m 'Network / BBR' 'Network / BBR')"
  kv "tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  kv "default_qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  kv "available algorithms" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"

  section "$(m 'Listening ports' 'Listening ports')"
  listening_ports_compact | print_block || true
}

print_recommended_workflow() {
  local support="${1:-$(os_support_level)}"
  section "$(m 'Recommended workflow' 'Recommended workflow')"
  if [ "$support" = "full" ]; then
    status_info "1. bash vps_init_tool.sh --preflight"
    status_info "2. bash vps_init_tool.sh --optimize-check"
    status_info "3. sudo bash vps_init_tool.sh --optimize-auto --yes"
    status_info "4. sudo bash vps_init_tool.sh --audit"
    status_info "5. sudo bash vps_init_tool.sh --ssh-audit"
    status_info "6. sudo bash vps_init_tool.sh --ufw-audit"
    status_info "7. sudo bash vps_init_tool.sh --ufw-cf-sync --ports 80,443 --yes"
    status_info "8. bash vps_init_tool.sh --updates-audit"
    status_info "$(m 'Apply SSH/UFW/Fail2ban changes only after confirming current SSH access is protected.' 'Apply SSH/UFW/Fail2ban changes only after confirming current SSH access is protected.')"
  else
    status_warn "$(m 'Do not run mutating commands on this OS. Use read-only checks only:' 'Do not run mutating commands on this OS. Use read-only checks only:')"
    status_info "bash vps_init_tool.sh --compat"
    status_info "bash vps_init_tool.sh --preflight"
    status_info "$(m 'For full automation, use a Debian/Ubuntu VPS or port the package/service/firewall modules first.' 'For full automation, use a Debian/Ubuntu VPS or port the package/service/firewall modules first.')"
  fi
}

compatibility_report() {
  local support pm
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  load_os_release
  support="$(os_support_level)"
  pm="$(package_manager_detect)"

  title "$(m 'Compatibility report' 'Compatibility report')"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "ID" "${ID:-unknown}"
  kv "ID_LIKE" "${ID_LIKE:-none}"
  kv "Package manager" "$pm"
  kv "Support level" "$support"

  echo
  case "$support" in
    full)
      status_ok "$(m 'Full support: official Debian or Ubuntu with apt-get.' 'Full support: official Debian or Ubuntu with apt-get.')"
      ;;
    derivative-audit)
      status_warn "$(m 'Derivative detected: read-only audits are supported, but mutating modules are intentionally blocked.' 'Derivative detected: read-only audits are supported, but mutating modules are intentionally blocked.')"
      ;;
    *)
      status_warn "$(m 'Audit-only support: mutating modules are intentionally blocked outside Debian/Ubuntu.' 'Audit-only support: mutating modules are intentionally blocked outside Debian/Ubuntu.')"
      ;;
  esac

  if is_systemd; then
    status_ok "$(m 'systemd detected; service modules can operate.' 'systemd detected; service modules can operate.')"
  else
    status_warn "$(m 'systemd not detected; service reload/start modules may be unavailable.' 'systemd not detected; service reload/start modules may be unavailable.')"
  fi

  if has_cmd sshd; then status_ok "sshd: available"; else status_warn "sshd: missing"; fi
  if has_cmd ufw; then status_ok "ufw: available"; else status_info "ufw: missing; install module requires full support"; fi
  if has_cmd fail2ban-client; then status_ok "fail2ban: available"; else status_info "fail2ban: missing; install module requires full support"; fi
  if has_cmd unattended-upgrade; then status_ok "unattended-upgrades: available"; else status_info "unattended-upgrades: missing; security updates module can install it"; fi
  if has_cmd sysctl; then status_ok "sysctl: available"; else status_warn "sysctl: missing"; fi
  if has_cmd ss; then status_ok "ss: available"; else status_info "ss: missing; port diagnostics are reduced"; fi

  echo
  status_info "$(m 'This report is read-only. Use --preflight for broader environment checks.' 'This report is read-only. Use --preflight for broader environment checks.')"
  print_recommended_workflow "$support"
}

doctor_report() {
  local support pm root_state systemd_state
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  load_os_release
  support="$(os_support_level)"
  pm="$(package_manager_detect)"
  root_state="$([ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] && echo yes || echo no)"
  systemd_state="$(is_systemd && echo yes || echo no)"

  title "$(m 'Doctor report' 'Doctor report')"
  kv "Tool" "$SCRIPT_NAME $TOOL_VERSION"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Support level" "$support"
  kv "Package manager" "$pm"
  kv "Root" "$root_state"
  kv "Systemd" "$systemd_state"

  section "$(m 'Read-only module readiness' 'Read-only module readiness')"
  if [ "$support" = "full" ]; then status_ok "OS support: full"; else status_warn "OS support: audit-only"; fi
  if [ "$pm" = "apt" ]; then status_ok "Package installs: apt available"; else status_warn "Package installs: unavailable for this script"; fi
  if [ "$systemd_state" = "yes" ]; then status_ok "Service management: systemd available"; else status_warn "Service management: systemd unavailable"; fi
  if has_cmd sshd; then status_ok "SSH audit: sshd available"; else status_warn "SSH audit: sshd missing"; fi
  if has_cmd ufw; then status_ok "UFW audit: ufw available"; else status_info "UFW audit: ufw missing"; fi
  if has_cmd fail2ban-client; then status_ok "Fail2ban audit: fail2ban-client available"; else status_info "Fail2ban audit: fail2ban-client missing"; fi
  if has_cmd unattended-upgrade; then status_ok "Security updates: unattended-upgrade available"; else status_info "Security updates: unattended-upgrades not installed"; fi
  if has_cmd resolvectl; then status_ok "DNS audit: resolvectl available"; else status_info "DNS audit: resolvectl missing; /etc/resolv.conf still checked"; fi
  if has_cmd journalctl; then status_ok "Logs audit: journalctl available"; else status_info "Logs audit: journalctl missing; /var/log still checked"; fi
  if has_cmd ss; then status_ok "Port diagnostics: ss available"; else status_info "Port diagnostics: ss missing"; fi

  section "$(m 'Recommended commands' 'Recommended commands')"
  status_info "bash vps_init_tool.sh --compat"
  status_info "bash vps_init_tool.sh --preflight"
  status_info "bash vps_init_tool.sh --optimize-check"
  if [ "$root_state" = "yes" ]; then
    status_info "bash vps_init_tool.sh --optimize-auto --yes"
    status_info "bash vps_init_tool.sh --audit"
  else
    status_info "sudo bash vps_init_tool.sh --optimize-auto --yes"
    status_info "sudo bash vps_init_tool.sh --audit"
  fi
  print_recommended_workflow "$support"
}

preflight_check() {
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  load_os_release

  title "$(m 'VPS init preflight' 'VPS init preflight')"
  kv "Time" "$(date '+%F %T %Z' 2>/dev/null || echo unknown)"
  kv "User" "$(id -un 2>/dev/null || echo unknown)"
  kv "Root" "$([ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] && echo yes || echo no)"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Support level" "$(os_support_level)"
  kv "Package manager" "$(package_manager_detect)"
  kv "Kernel" "$(uname -r 2>/dev/null || echo unknown)"
  kv "Arch" "$(uname -m 2>/dev/null || echo unknown)"
  kv "Memory" "$(get_mem_mb 2>/dev/null || echo unknown) MB"
  kv "Root disk available" "$(get_root_avail_mb 2>/dev/null || echo unknown) MB"

  echo
  case "${ID:-}" in
    debian|ubuntu) status_ok "$(m 'Debian/Ubuntu family detected.' 'Debian/Ubuntu family detected.')" ;;
    *) status_bad "$(m "Unsupported OS for this script: ${PRETTY_NAME:-unknown}" "Unsupported OS for this script: ${PRETTY_NAME:-unknown}")" ;;
  esac

  if has_cmd apt-get; then status_ok "apt-get"; else status_bad "$(m 'apt-get not found.' 'apt-get not found.')"; fi
  if has_cmd systemctl && [ -d /run/systemd/system ]; then status_ok "systemd"; else status_warn "$(m 'systemd is not fully available; service operations may fail.' 'systemd is not fully available; service operations may fail.')"; fi
  if has_cmd sudo; then status_ok "sudo"; else status_info "$(m 'sudo not found; run as root when applying changes.' 'sudo not found; run as root when applying changes.')"; fi
  if has_cmd curl; then status_ok "curl"; else status_warn "$(m 'curl missing; baseline can install it.' 'curl missing; baseline can install it.')"; fi
  if [ -d /etc/ssl/certs ]; then status_ok "ca-certificates"; else status_warn "$(m 'Certificate store not found; ensure HTTPS downloads work.' 'Certificate store not found; ensure HTTPS downloads work.')"; fi

  if has_cmd sshd; then
    status_ok "$(m "sshd detected; effective port(s): $(current_ssh_ports)" "sshd detected; effective port(s): $(current_ssh_ports)")"
  else
    status_warn "$(m 'sshd not found; SSH hardening/audit will be unavailable.' 'sshd not found; SSH hardening/audit will be unavailable.')"
  fi

  if has_cmd ufw; then status_info "$(m 'UFW is installed.' 'UFW is installed.')"; else status_info "$(m 'UFW is not installed; firewall module can install it.' 'UFW is not installed; firewall module can install it.')"; fi
  if has_cmd fail2ban-client; then status_info "$(m 'Fail2ban is installed.' 'Fail2ban is installed.')"; else status_info "$(m 'Fail2ban is not installed; fail2ban module can install it.' 'Fail2ban is not installed; fail2ban module can install it.')"; fi
  if has_cmd unattended-upgrade; then status_info "$(m 'unattended-upgrades is installed.' 'unattended-upgrades is installed.')"; else status_info "$(m 'unattended-upgrades is not installed; the security updates module can install it.' 'unattended-upgrades is not installed; the security updates module can install it.')"; fi

  echo
  status_info "$(m 'Preflight is read-only. No settings were changed.' 'Preflight is read-only. No settings were changed.')"
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    status_info "$(m 'Run with sudo/root for --optimize-auto, --audit, SSH, UFW, DNS, and service changes.' 'Run with sudo/root for --optimize-auto, --audit, SSH, UFW, DNS, and service changes.')"
  fi
  print_recommended_workflow "$(os_support_level)"
}

memory_report() {
  local mem_mb swap_rec zram_rec swappiness_rec swap_lines zram_active
  mem_mb="$(get_mem_mb)"
  swap_rec="$(recommend_swap_size)"
  zram_rec="$(recommend_zram_size)"
  swappiness_rec="$(recommend_swappiness)"
  swap_lines="$({ swapon --show --noheadings 2>/dev/null || true; } | wc -l | awk '{print $1}')"
  zram_active="$(swapon --show --noheadings 2>/dev/null | awk '$1 ~ /zram/ {print $1}' | paste -sd, - || true)"

  section "$(m 'Memory audit' 'Memory audit')"
  kv "RAM" "${mem_mb} MB"
  kv "Current swappiness" "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
  kv "Current vfs_cache_pressure" "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo unknown)"
  kv "Active swap devices" "${swap_lines:-0}"
  kv "Active ZRAM" "${zram_active:-none}"

  echo
  status_info "$(m "Recommended swapfile: $swap_rec" "Recommended swapfile: $swap_rec")"
  status_info "$(m "Recommended ZRAM: $zram_rec" "Recommended ZRAM: $zram_rec")"
  status_info "$(m "Recommended swappiness: $swappiness_rec; vfs_cache_pressure: 50" "Recommended swappiness: $swappiness_rec; vfs_cache_pressure: 50")"

  echo
  muted "  $(m 'Current free -h:' 'Current free -h:')"
  free -h | print_block || true
  echo
  muted "  $(m 'Current swapon:' 'Current swapon:')"
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true

  echo
  if [ "$mem_mb" -le 2048 ]; then
    status_warn "$(m 'Small VPS profile: ZRAM + swapfile is recommended.' 'Small VPS profile: ZRAM + swapfile is recommended.')"
  elif [ "$mem_mb" -le 8192 ]; then
    status_info "$(m 'Medium VPS profile: swapfile recommended; ZRAM optional.' 'Medium VPS profile: swapfile recommended; ZRAM optional.')"
  else
    status_info "$(m 'Large VPS profile: usually swapfile only; ZRAM optional.' 'Large VPS profile: usually swapfile only; ZRAM optional.')"
  fi
}

# ---------- memory ----------
cleanup_failed_swapfile_creation() {
  local path="${1:-$SWAPFILE}"
  if [ "$path" = "$SWAPFILE" ]; then swapoff "$SWAPFILE" 2>/dev/null || true; fi
  rm -f -- "$path"
}

restore_previous_swapfile() {
  local old_swap_backup="$1" swap_was_active="${2:-0}"
  [ -n "$old_swap_backup" ] && [ -e "$old_swap_backup" ] || return 0
  rm -f -- "$SWAPFILE"
  if ! mv "$old_swap_backup" "$SWAPFILE"; then
    status_warn "$(m "Failed to restore previous swapfile: $old_swap_backup" "Failed to restore previous swapfile: $old_swap_backup")"
    return 1
  fi
  if [ "$swap_was_active" = "1" ]; then
    swapon -p 10 "$SWAPFILE" || status_warn "$(m 'Failed to reactivate previous swapfile. Check swap manually.' 'Failed to reactivate previous swapfile. Check swap manually.')"
  fi
}

rollback_new_swapfile() {
  local old_swap_backup="$1" swap_was_active="${2:-0}"
  cleanup_failed_swapfile_creation
  restore_previous_swapfile "$old_swap_backup" "$swap_was_active"
}

setup_swapfile() {
  local size swappiness vfs_cache_pressure mb expected_bytes actual_bytes allocated=0
  local swap_was_active=0 old_swap_backup="" new_swap_tmp="" fstab_backup=""
  size="$(input_default "$(m 'Swapfile size; use 0 to skip' 'Swapfile size; use 0 to skip')" "$(recommend_swap_size)")"
  case "$size" in 0|0M|0m|0G|0g) yellow "$(m 'Swapfile skipped.' 'Swapfile skipped.')"; return 0 ;; esac
  valid_size_mb_gb "$size" || { red "$(m 'Invalid swapfile size. Use a positive value such as 512M, 2G, or 2048.' 'Invalid swapfile size. Use a positive value such as 512M, 2G, or 2048.')"; return 1; }
  mb="$(parse_size_to_mb "$size")" || { red "$(m 'Unable to parse swapfile size.' 'Unable to parse swapfile size.')"; return 1; }
  swappiness="$(input_default "vm.swappiness" "$(recommend_swappiness)")"
  vfs_cache_pressure="$(input_default "vm.vfs_cache_pressure" "50")"
  valid_uint_range "$swappiness" 0 200 || { red "$(m 'Invalid vm.swappiness. Use 0-200.' 'Invalid vm.swappiness. Use 0-200.')"; return 1; }
  valid_uint_range "$vfs_cache_pressure" 0 1000 || { red "$(m 'Invalid vm.vfs_cache_pressure. Use 0-1000.' 'Invalid vm.vfs_cache_pressure. Use 0-1000.')"; return 1; }

  blue "$(m "Configuring $SWAPFILE size=$size" "Configuring $SWAPFILE size=$size")"
  if swapon --show | awk '{print $1}' | grep -qx "$SWAPFILE"; then
    swap_was_active=1
    yellow "$(m "$SWAPFILE is currently active and will be briefly replaced after the new swapfile is ready." "$SWAPFILE is currently active and will be briefly replaced after the new swapfile is ready.")"
    confirm_yes "$(m "Recreate active $SWAPFILE?" "Recreate active $SWAPFILE?")" || return 0
  elif [ -e "$SWAPFILE" ]; then
    confirm_yes "$(m "$SWAPFILE exists and will be reformatted. Continue?" "$SWAPFILE exists and will be reformatted. Continue?")" || return 0
  fi

  new_swap_tmp="$(mktemp "${SWAPFILE}.new.XXXXXX")" || return 1
  expected_bytes=$((mb * 1024 * 1024))
  if has_cmd fallocate && fallocate -l "$size" "$new_swap_tmp"; then
    actual_bytes="$(stat -c %s "$new_swap_tmp" 2>/dev/null || echo 0)"
    [ "$actual_bytes" -eq "$expected_bytes" ] && allocated=1
  fi
  if [ "$allocated" -ne 1 ]; then
    : > "$new_swap_tmp"
    if ! dd if=/dev/zero of="$new_swap_tmp" bs=1M count="$mb" status=progress; then
      red "$(m 'Failed to create swapfile data. Cleaning up partial file.' 'Failed to create swapfile data. Cleaning up partial file.')"
      cleanup_failed_swapfile_creation "$new_swap_tmp"
      return 1
    fi
  fi
  actual_bytes="$(stat -c %s "$new_swap_tmp" 2>/dev/null || echo 0)"
  if [ "$actual_bytes" -ne "$expected_bytes" ]; then
    red "$(m 'Swapfile size verification failed. Cleaning up partial file.' 'Swapfile size verification failed. Cleaning up partial file.')"
    cleanup_failed_swapfile_creation "$new_swap_tmp"
    return 1
  fi

  if ! chmod 600 "$new_swap_tmp"; then
    red "$(m 'Failed to set swapfile permissions. Cleaning up partial file.' 'Failed to set swapfile permissions. Cleaning up partial file.')"
    cleanup_failed_swapfile_creation "$new_swap_tmp"
    return 1
  fi
  if ! mkswap "$new_swap_tmp"; then
    red "$(m 'Failed to format swapfile. Cleaning up partial file.' 'Failed to format swapfile. Cleaning up partial file.')"
    cleanup_failed_swapfile_creation "$new_swap_tmp"
    return 1
  fi
  if [ -e "$SWAPFILE" ]; then
    old_swap_backup="$(mktemp "${SWAPFILE}.old.XXXXXX")" || {
      red "$(m 'Failed to reserve previous swapfile backup path. Aborting.' 'Failed to reserve previous swapfile backup path. Aborting.')"
      if [ "$swap_was_active" = "1" ]; then swapon -p 10 "$SWAPFILE" 2>/dev/null || true; fi
      cleanup_failed_swapfile_creation "$new_swap_tmp"
      return 1
    }
    if [ "$swap_was_active" = "1" ] && ! swapoff "$SWAPFILE"; then
      red "$(m 'swapoff failed. Memory may be too tight. Aborting.' 'swapoff failed. Memory may be too tight. Aborting.')"
      cleanup_files "$old_swap_backup" "$new_swap_tmp"
      return 1
    fi
    if ! mv "$SWAPFILE" "$old_swap_backup"; then
      red "$(m 'Failed to preserve previous swapfile. Aborting.' 'Failed to preserve previous swapfile. Aborting.')"
      if [ "$swap_was_active" = "1" ]; then swapon -p 10 "$SWAPFILE" 2>/dev/null || true; fi
      cleanup_files "$old_swap_backup"
      cleanup_failed_swapfile_creation "$new_swap_tmp"
      return 1
    fi
  fi
  if ! mv "$new_swap_tmp" "$SWAPFILE"; then
    red "$(m 'Failed to install new swapfile. Restoring previous swapfile.' 'Failed to install new swapfile. Restoring previous swapfile.')"
    cleanup_failed_swapfile_creation "$new_swap_tmp"
    restore_previous_swapfile "$old_swap_backup" "$swap_was_active"
    return 1
  fi
  if ! swapon -p 10 "$SWAPFILE"; then
    red "$(m 'Failed to activate swapfile. Cleaning up partial file.' 'Failed to activate swapfile. Cleaning up partial file.')"
    cleanup_failed_swapfile_creation
    restore_previous_swapfile "$old_swap_backup" "$swap_was_active"
    return 1
  fi

  if ! backup_path /etc/fstab >/dev/null; then
    red "$(m 'Failed to back up /etc/fstab. Restoring previous swapfile.' 'Failed to back up /etc/fstab. Restoring previous swapfile.')"
    rollback_new_swapfile "$old_swap_backup" "$swap_was_active"
    return 1
  fi
  fstab_backup="$BACKUP_LAST_PATH"
  if ! grep -qE "^[^#]*[[:space:]]${SWAPFILE}[[:space:]]" /etc/fstab; then
    if ! echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab; then
      red "$(m 'Failed to update /etc/fstab. Restoring previous swapfile.' 'Failed to update /etc/fstab. Restoring previous swapfile.')"
      restore_managed_file /etc/fstab "$fstab_backup"
      rollback_new_swapfile "$old_swap_backup" "$swap_was_active"
      return 1
    fi
  fi
  cleanup_files "$old_swap_backup"
  if ! apply_memory_sysctl "$swappiness" "$vfs_cache_pressure"; then
    status_warn "$(m 'Swapfile is active, but VM sysctl tuning failed.' 'Swapfile is active, but VM sysctl tuning failed.')"
    return 1
  fi

  green "$(m 'Swapfile configured.' 'Swapfile configured.')"
  free -h
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show
}

zram_supported() {
  modprobe zram 2>/dev/null || true
  [ -e /sys/class/zram-control ] || [ -b /dev/zram0 ]
}

stop_known_zram_services() {
  if is_systemd; then
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl stop zramswap.service 2>/dev/null || true
    systemctl stop zram-config.service 2>/dev/null || true
    systemctl stop zram-swap.service 2>/dev/null || true
  fi
  swapoff /dev/zram0 2>/dev/null || true
}

setup_zram_generator() {
  local size_expr algo config_file="/etc/systemd/zram-generator.conf" config_backup="" config_tmp=""
  size_expr="$(input_default "$(m 'ZRAM size/expression, e.g. 512M / 2G / ram / 2 / min(ram / 2, 1024M)' 'ZRAM size/expression, e.g. 512M / 2G / ram / 2 / min(ram / 2, 1024M)')" "$(recommend_zram_size)")"
  algo="$(input_default "$(m 'Compression algorithm' 'Compression algorithm')" "zstd")"
  apt_install systemd-zram-generator || return 1
  mkdir -p /etc/systemd || return 1
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  config_tmp="$(mktemp /etc/systemd/.zram-generator.conf.XXXXXX)" || return 1
  if ! cat > "$config_tmp" <<EOF2
[zram0]
zram-size = $size_expr
compression-algorithm = $algo
swap-priority = 100
EOF2
  then
    cleanup_files "$config_tmp"
    return 1
  fi
  chmod 644 "$config_tmp" || { cleanup_files "$config_tmp"; return 1; }
  mv -f -- "$config_tmp" "$config_file" || { cleanup_files "$config_tmp"; return 1; }
  if ! systemctl daemon-reload || ! { systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl start systemd-zram-setup@zram0.service; }; then
    red "$(m 'ZRAM generator activation failed. Restoring the previous configuration.' 'ZRAM generator activation failed. Restoring the previous configuration.')"
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    if ! restore_managed_file "$config_file" "$config_backup"; then
      status_bad "$(m 'Failed to restore the previous ZRAM generator configuration.' 'Failed to restore the previous ZRAM generator configuration.')"
      return 1
    fi
    systemctl daemon-reload || status_warn "$(m 'Failed to reload systemd after ZRAM generator rollback.' 'Failed to reload systemd after ZRAM generator rollback.')"
    if [ -n "$config_backup" ]; then
      systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || status_warn "$(m 'Previous ZRAM generator configuration was restored but could not be restarted.' 'Previous ZRAM generator configuration was restored but could not be restarted.')"
    fi
    return 1
  fi
}

setup_zram_tools() {
  local size_hint_mb="$1" config_file="/etc/default/zramswap" config_backup=""
  apt_install zram-tools || return 1
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  if [ -f "$config_file" ]; then
    sed -i 's/^#\?ALGO=.*/ALGO=zstd/' "$config_file" || return 1
    if [[ "$size_hint_mb" =~ ^[0-9]+[Mm]?$ ]]; then
      size_hint_mb="${size_hint_mb%M}"; size_hint_mb="${size_hint_mb%m}"
      if grep -q '^#\?SIZE=' "$config_file"; then
        sed -i "s/^#\?SIZE=.*/SIZE=${size_hint_mb}/" "$config_file" || return 1
      else
        echo "SIZE=${size_hint_mb}" >> "$config_file" || return 1
      fi
    else
      if grep -q '^#\?PERCENT=' "$config_file"; then
        sed -i 's/^#\?PERCENT=.*/PERCENT=50/' "$config_file" || return 1
      else
        echo 'PERCENT=50' >> "$config_file" || return 1
      fi
    fi
    if grep -q '^#\?PRIORITY=' "$config_file"; then
      sed -i 's/^#\?PRIORITY=.*/PRIORITY=100/' "$config_file" || return 1
    else
      echo 'PRIORITY=100' >> "$config_file" || return 1
    fi
  fi
  if ! { systemctl restart zramswap.service 2>/dev/null || systemctl restart zram-config.service 2>/dev/null; }; then
    red "$(m 'ZRAM tools activation failed. Restoring the previous configuration.' 'ZRAM tools activation failed. Restoring the previous configuration.')"
    systemctl stop zramswap.service zram-config.service 2>/dev/null || true
    if ! restore_managed_file "$config_file" "$config_backup"; then
      status_bad "$(m 'Failed to restore the previous zram-tools configuration.' 'Failed to restore the previous zram-tools configuration.')"
      return 1
    fi
    if [ -n "$config_backup" ]; then
      systemctl restart zramswap.service 2>/dev/null || systemctl restart zram-config.service 2>/dev/null || status_warn "$(m 'Previous zram-tools configuration was restored but could not be restarted.' 'Previous zram-tools configuration was restored but could not be restarted.')"
    fi
    return 1
  fi
}

setup_zram_fallback() {
  local size mb
  size="$(input_default "$(m 'ZRAM fallback size' 'ZRAM fallback size')" "$(recommend_zram_size)")"
  valid_size_mb_gb "$size" || { red "$(m 'Invalid ZRAM fallback size. Use a positive value such as 512M or 2G.' 'Invalid ZRAM fallback size. Use a positive value such as 512M or 2G.')"; return 1; }
  mb="$(parse_size_to_mb "$size")" || return 1
  cat > /usr/local/sbin/zram-swap-start.sh <<EOF2
#!/usr/bin/env bash
set -euo pipefail
modprobe zram
[ -b /dev/zram0 ] || { echo "No /dev/zram0"; exit 1; }
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
if grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null; then
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
elif grep -qw lz4 /sys/block/zram0/comp_algorithm 2>/dev/null; then
  echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
fi
echo "${mb}M" > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF2
  cat > /usr/local/sbin/zram-swap-stop.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF2
  chmod +x /usr/local/sbin/zram-swap-start.sh /usr/local/sbin/zram-swap-stop.sh
  cat > /etc/systemd/system/zram-swap.service <<'EOF2'
[Unit]
Description=Compressed RAM swap on zram
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap-start.sh
ExecStop=/usr/local/sbin/zram-swap-stop.sh

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  systemctl enable --now zram-swap.service
}

setup_zram() {
  local enable size_hint
  enable="$(input_yes_no "$(m 'Enable/configure ZRAM?' 'Enable/configure ZRAM?')" "yes")" || return 1
  [ "$enable" = "yes" ] || { yellow "$(m 'ZRAM skipped.' 'ZRAM skipped.')"; return 0; }
  is_systemd || { red "$(m 'systemd not detected. ZRAM auto-start setup skipped.' 'systemd not detected. ZRAM auto-start setup skipped.')"; return 1; }
  zram_supported || { red "$(m 'ZRAM not supported by this kernel/VPS layer.' 'ZRAM not supported by this kernel/VPS layer.')"; return 1; }

  size_hint="$(recommend_zram_size)"
  apt_update_once || return 1
  if apt-cache show systemd-zram-generator >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_generator || return 1
  elif apt-cache show zram-tools >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_tools "$size_hint" || return 1
  else
    stop_known_zram_services
    setup_zram_fallback
  fi
  green "$(m 'ZRAM status:' 'ZRAM status:')"
  free -h
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show
}

memory_optimize_menu() {
  while true; do
    clear_screen
    title "$(m 'Memory / Swap / ZRAM' 'Memory / Swap / ZRAM')"
    echo "1) $(m 'Memory audit report' 'Memory audit report')"
    echo "2) $(m 'Configure/Reconfigure swapfile' 'Configure/Reconfigure swapfile')"
    echo "3) $(m 'Configure/Reconfigure ZRAM' 'Configure/Reconfigure ZRAM')"
    echo "4) $(m 'Apply VM sysctl only' 'Apply VM sysctl only')"
    echo "5) $(m 'Apply full recommended memory profile' 'Apply full recommended memory profile')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) memory_report; pause ;;
      2) setup_swapfile; pause ;;
      3) setup_zram; pause ;;
      4)
        apply_memory_sysctl "$(input_default "vm.swappiness" "$(recommend_swappiness)")" "$(input_default "vm.vfs_cache_pressure" "50")"
        green "$(m 'VM memory sysctl applied.' 'VM memory sysctl applied.')"; pause ;;
      5)
        memory_report
        confirm_yes "$(m 'Apply recommended memory profile?' 'Apply recommended memory profile?')" || { pause; continue; }
        apply_memory_sysctl "$(recommend_swappiness)" "50"
        setup_swapfile
        setup_zram
        pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- network tuning ----------
bbr_supported() {
  modprobe tcp_bbr 2>/dev/null || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

bbr_available_readonly() {
  local kernel_config=""
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
  if [ -r "/boot/config-$(uname -r)" ]; then
    kernel_config="/boot/config-$(uname -r)"
  elif [ -r /proc/config.gz ] && has_cmd zgrep; then
    zgrep -Eq '^CONFIG_TCP_CONG_BBR=(y|m)$' /proc/config.gz
    return $?
  fi
  if [ -n "$kernel_config" ] && grep -Eq '^CONFIG_TCP_CONG_BBR=(y|m)$' "$kernel_config"; then
    return 0
  fi
  find "/lib/modules/$(uname -r)" -type f -name 'tcp_bbr.ko*' -print -quit 2>/dev/null | grep -q .
}

enable_bbr() {
  local config_file="/etc/sysctl.d/90-bbr.conf" config_backup=""
  blue "$(m 'Enabling BBR if supported...' 'Enabling BBR if supported...')"
  if ! bbr_supported; then
    red "$(m 'BBR is not supported or is blocked by the virtualization layer.' 'BBR is not supported or is blocked by the virtualization layer.')"
    return 1
  fi
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<'EOF2' || return 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  if ! sysctl -p /etc/sysctl.d/90-bbr.conf >/dev/null; then
    red "$(m 'Failed to apply BBR sysctl settings. Restoring the previous configuration.' 'Failed to apply BBR sysctl settings. Restoring the previous configuration.')"
    restore_managed_file "$config_file" "$config_backup"
    restore_sysctl_file "$config_file"
    return 1
  fi
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
}

apply_proxy_sysctl() {
  local config_file="/etc/sysctl.d/99-proxy-tuning.conf" config_backup=""
  yellow "$(m 'Advanced proxy sysctl tuning changes global TCP behavior and is not part of the low-risk baseline.' 'Advanced proxy sysctl tuning changes global TCP behavior and is not part of the low-risk baseline.')"
  status_info "$(m 'Use this only for a measured high-concurrency workload and keep benchmark/rollback data.' 'Use this only for a measured high-concurrency workload and keep benchmark/rollback data.')"
  confirm_yes "$(m 'Apply advanced global proxy sysctl tuning?' 'Apply advanced global proxy sysctl tuning?')" || return 0
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<'EOF2' || return 1
fs.file-max=1048576
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fastopen=3
EOF2
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cat >> "$config_file" <<'EOF2' || return 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  fi
  if ! sysctl -p /etc/sysctl.d/99-proxy-tuning.conf >/dev/null; then
    red "$(m 'Failed to apply proxy sysctl settings. Restoring the previous configuration.' 'Failed to apply proxy sysctl settings. Restoring the previous configuration.')"
    restore_managed_file "$config_file" "$config_backup"
    restore_sysctl_file "$config_file"
    return 1
  fi
  green "$(m 'Proxy sysctl tuning applied.' 'Proxy sysctl tuning applied.')"
}

raise_nofile_limits() {
  yellow "$(m 'Global nofile tuning affects all users and default systemd service limits.' 'Global nofile tuning affects all users and default systemd service limits.')"
  status_info "$(m 'Prefer a per-service LimitNOFILE override when only one daemon needs a higher limit.' 'Prefer a per-service LimitNOFILE override when only one daemon needs a higher limit.')"
  confirm_yes "$(m 'Raise global nofile defaults?' 'Raise global nofile defaults?')" || return 0
  backup_path /etc/security/limits.d/99-proxy-limits.conf >/dev/null || return 1
  cat > /etc/security/limits.d/99-proxy-limits.conf <<'EOF2' || return 1
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF2
  if is_systemd; then
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF2' || return 1
[Manager]
DefaultLimitNOFILE=1048576
EOF2
    cat > /etc/systemd/user.conf.d/99-limits.conf <<'EOF2' || return 1
[Manager]
DefaultLimitNOFILE=1048576
EOF2
    systemctl daemon-reexec || true
  fi
  green "$(m 'nofile limits written. Reboot or restart services for full effect.' 'nofile limits written. Reboot or restart services for full effect.')"
}

# ---------- SSH ----------
current_ssh_ports() {
  local ports session_port
  if has_cmd sshd; then
    ports="$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -nu | paste -sd' ' -)"
  else
    ports=""
  fi
  session_port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
  if valid_port "$session_port"; then
    ports="$(printf '%s\n%s\n' "$ports" "$session_port" | tr ' ' '\n' | awk 'NF' | sort -nu | paste -sd' ' -)"
  fi
  echo "${ports:-22}"
}

current_ssh_port_guess() {
  local p
  p="$(current_ssh_ports | awk '{print $1}')"
  echo "${p:-22}"
}

interactive_users() {
  awk -F: '($7 !~ /(nologin|false)$/){printf "%s:%s:%s\n",$1,$3,$7}' /etc/passwd 2>/dev/null || true
}

nonroot_interactive_count() {
  awk -F: '($1!="root" && $7 !~ /(nologin|false)$/){c++} END{print c+0}' /etc/passwd 2>/dev/null || echo 0
}

nonroot_password_hash_count() {
  awk -F: '($1!="root" && $2 !~ /^(!|\*)/ && $2!=""){c++} END{print c+0}' /etc/shadow 2>/dev/null || echo 0
}

ssh_effective() {
  sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|authenticationmethods|permitemptypasswords|usepam|maxauthtries|maxsessions|maxstartups|logingracetime|x11forwarding|allowtcpforwarding|allowagentforwarding|gatewayports|permittunnel|allowusers|denyusers) ' || true
}

ssh_effective_value_from_text() {
  local text="$1" key="$2"
  awk -v key="$key" '
    $1 == key {
      $1 = ""
      sub(/^[[:space:]]+/, "")
      print
      exit
    }
  ' <<< "$text"
}

ssh_effective_expect() {
  local text="$1" key="$2" expected="$3" actual
  actual="$(ssh_effective_value_from_text "$text" "$key")"
  if [ "$actual" != "$expected" ]; then
    status_bad "Effective SSH mismatch: $key expected '$expected', got '${actual:-missing}'."
    return 1
  fi
}

ssh_verify_hardening_effective() {
  local port="$1" password_policy="$2" permit_root="$3" strict_forwarding="$4" allow_tcp="$5" allow_user="${6:-}"
  local output effective_root failures=0
  if ! output="$(sshd -T 2>/dev/null)"; then
    status_bad "Unable to read effective SSH configuration with sshd -T."
    return 1
  fi

  if ! awk -v expected="$port" '$1 == "port" && $2 == expected { found=1 } END { exit(found ? 0 : 1) }' <<< "$output"; then
    status_bad "Effective SSH mismatch: port $port is not active."
    failures=$((failures + 1))
  fi
  ssh_effective_expect "$output" pubkeyauthentication yes || failures=$((failures + 1))

  effective_root="$(ssh_effective_value_from_text "$output" permitrootlogin)"
  if [ "$permit_root" = "without-password" ]; then
    if [ "$effective_root" != "without-password" ] && [ "$effective_root" != "prohibit-password" ]; then
      status_bad "Effective SSH mismatch: permitrootlogin expected password-disabled root login, got '${effective_root:-missing}'."
      failures=$((failures + 1))
    fi
  elif [ "$effective_root" != "$permit_root" ]; then
    status_bad "Effective SSH mismatch: permitrootlogin expected '$permit_root', got '${effective_root:-missing}'."
    failures=$((failures + 1))
  fi

  ssh_effective_expect "$output" maxauthtries 3 || failures=$((failures + 1))
  ssh_effective_expect "$output" maxsessions 3 || failures=$((failures + 1))
  ssh_effective_expect "$output" maxstartups 10:30:60 || failures=$((failures + 1))
  ssh_effective_expect "$output" logingracetime 30 || failures=$((failures + 1))
  ssh_effective_expect "$output" permitemptypasswords no || failures=$((failures + 1))
  ssh_effective_expect "$output" usepam yes || failures=$((failures + 1))

  case "$password_policy" in
    no)
      ssh_effective_expect "$output" passwordauthentication no || failures=$((failures + 1))
      ssh_effective_expect "$output" kbdinteractiveauthentication no || failures=$((failures + 1))
      ;;
    yes)
      ssh_effective_expect "$output" passwordauthentication yes || failures=$((failures + 1))
      ;;
  esac

  if [ "$strict_forwarding" = "yes" ]; then
    ssh_effective_expect "$output" x11forwarding no || failures=$((failures + 1))
    ssh_effective_expect "$output" allowagentforwarding no || failures=$((failures + 1))
    ssh_effective_expect "$output" gatewayports no || failures=$((failures + 1))
    ssh_effective_expect "$output" permittunnel no || failures=$((failures + 1))
    ssh_effective_expect "$output" allowstreamlocalforwarding no || failures=$((failures + 1))
  fi
  ssh_effective_expect "$output" allowtcpforwarding "$allow_tcp" || failures=$((failures + 1))
  if [ -n "$allow_user" ]; then
    ssh_effective_expect "$output" allowusers "$allow_user" || failures=$((failures + 1))
  fi

  [ "$failures" -eq 0 ]
}

ssh_audit() {
  section "$(m 'SSH audit' 'SSH audit')"
  if ! has_cmd sshd; then status_bad "$(m 'sshd not found.' 'sshd not found.')"; return 1; fi

  local port pass root pub maxauth maxsessions maxstartups grace forwarding x11 agent kbd empty tunnel gateway pam authmethods nonroot_count nonroot_hashes
  port="$(current_ssh_ports)"
  pass="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2; exit}')"
  root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}')"
  pub="$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication / {print $2; exit}')"
  kbd="$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication / {print $2; exit}')"
  pam="$(sshd -T 2>/dev/null | awk '/^usepam / {print $2; exit}')"
  authmethods="$(sshd -T 2>/dev/null | awk '/^authenticationmethods / {print $2; exit}')"
  empty="$(sshd -T 2>/dev/null | awk '/^permitemptypasswords / {print $2; exit}')"
  maxauth="$(sshd -T 2>/dev/null | awk '/^maxauthtries / {print $2; exit}')"
  maxsessions="$(sshd -T 2>/dev/null | awk '/^maxsessions / {print $2; exit}')"
  maxstartups="$(sshd -T 2>/dev/null | awk '/^maxstartups / {print $2; exit}')"
  grace="$(sshd -T 2>/dev/null | awk '/^logingracetime / {print $2; exit}')"
  forwarding="$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding / {print $2; exit}')"
  agent="$(sshd -T 2>/dev/null | awk '/^allowagentforwarding / {print $2; exit}')"
  x11="$(sshd -T 2>/dev/null | awk '/^x11forwarding / {print $2; exit}')"
  tunnel="$(sshd -T 2>/dev/null | awk '/^permittunnel / {print $2; exit}')"
  gateway="$(sshd -T 2>/dev/null | awk '/^gatewayports / {print $2; exit}')"
  nonroot_count="$(nonroot_interactive_count)"
  nonroot_hashes="$(nonroot_password_hash_count)"

  kv "Port(s)" "${port:-unknown}"
  kv "PubkeyAuthentication" "${pub:-unknown}"
  kv "PasswordAuthentication" "${pass:-unknown}"
  kv "KbdInteractiveAuthentication" "${kbd:-unknown}"
  kv "PermitRootLogin" "${root:-unknown}"
  kv "UsePAM" "${pam:-unknown}"
  kv "AuthenticationMethods" "${authmethods:-unknown}"
  kv "PermitEmptyPasswords" "${empty:-unknown}"
  kv "MaxAuthTries" "${maxauth:-unknown}"
  kv "MaxSessions" "${maxsessions:-unknown}"
  kv "MaxStartups" "${maxstartups:-unknown}"
  kv "LoginGraceTime" "${grace:-unknown}"
  kv "AllowTcpForwarding" "${forwarding:-unknown}"
  kv "AllowAgentForwarding" "${agent:-unknown}"
  kv "X11Forwarding" "${x11:-unknown}"
  kv "GatewayPorts" "${gateway:-unknown}"
  kv "PermitTunnel" "${tunnel:-unknown}"
  kv "Non-root interactive users" "$nonroot_count"
  kv "Non-root users with password hash" "$nonroot_hashes"

  echo
  if [ "$pub" = "yes" ]; then status_ok "$(m 'Public-key authentication is enabled.' 'Public-key authentication is enabled.')"; else status_bad "$(m 'PubkeyAuthentication is not enabled.' 'PubkeyAuthentication is not enabled.')"; fi

  case "$root" in
    without-password)
      status_ok "$(m 'Root password login is blocked; without-password is an old alias. Prefer prohibit-password for clarity.' 'Root password login is blocked; without-password is an old alias. Prefer prohibit-password for clarity.')" ;;
    prohibit-password)
      status_ok "$(m 'Root password login is blocked by prohibit-password.' 'Root password login is blocked by prohibit-password.')" ;;
    no)
      status_ok "$(m 'Root SSH login is disabled.' 'Root SSH login is disabled.')" ;;
    yes)
      status_warn "$(m 'Root login is fully allowed. Prefer prohibit-password or no.' 'Root login is fully allowed. Prefer prohibit-password or no.')" ;;
    *)
      status_info "$(m "Root login policy: $root" "Root login policy: $root")" ;;
  esac

  if [ "$pass" = "yes" ]; then
    if [ "$nonroot_count" -eq 0 ]; then
      status_info "$(m 'PasswordAuthentication is enabled globally, but no non-root interactive user was detected. This is mainly a future-risk setting.' 'PasswordAuthentication is enabled globally, but no non-root interactive user was detected. This is mainly a future-risk setting.')"
    elif [ "$nonroot_hashes" -gt 0 ]; then
      status_warn "$(m 'Password SSH may be possible for non-root users with password hashes. Consider PasswordAuthentication no.' 'Password SSH may be possible for non-root users with password hashes. Consider PasswordAuthentication no.')"
    else
      status_warn "$(m 'PasswordAuthentication is enabled globally. Check whether non-root users can use password login.' 'PasswordAuthentication is enabled globally. Check whether non-root users can use password login.')"
    fi
  else
    status_ok "$(m 'PasswordAuthentication is disabled.' 'PasswordAuthentication is disabled.')"
  fi

  if [ "$kbd" = "yes" ]; then status_warn "$(m 'Keyboard-interactive auth is enabled. Consider KbdInteractiveAuthentication no.' 'Keyboard-interactive auth is enabled. Consider KbdInteractiveAuthentication no.')"; else status_ok "$(m 'Keyboard-interactive auth is disabled.' 'Keyboard-interactive auth is disabled.')"; fi
  if [ "$empty" = "yes" ]; then status_bad "$(m 'Empty passwords are permitted. Disable immediately.' 'Empty passwords are permitted. Disable immediately.')"; else status_ok "$(m 'Empty passwords are not permitted.' 'Empty passwords are not permitted.')"; fi
  if [ "$x11" = "yes" ]; then status_warn "$(m 'X11Forwarding is enabled. Ordinary VPS usually should set it to no.' 'X11Forwarding is enabled. Ordinary VPS usually should set it to no.')"; else status_ok "$(m 'X11Forwarding is disabled.' 'X11Forwarding is disabled.')"; fi
  if [ "$agent" = "yes" ]; then status_warn "$(m 'Agent forwarding is enabled. Disable it unless this host is a trusted jump box.' 'Agent forwarding is enabled. Disable it unless this host is a trusted jump box.')"; else status_ok "$(m 'Agent forwarding is disabled.' 'Agent forwarding is disabled.')"; fi
  if [ "$gateway" = "yes" ]; then status_warn "$(m 'GatewayPorts is enabled; remote forwards may bind publicly.' 'GatewayPorts is enabled; remote forwards may bind publicly.')"; else status_ok "$(m 'GatewayPorts is not open.' 'GatewayPorts is not open.')"; fi
  if [ "$tunnel" = "yes" ]; then status_warn "$(m 'PermitTunnel is enabled. Usually unnecessary for normal VPS management.' 'PermitTunnel is enabled. Usually unnecessary for normal VPS management.')"; else status_ok "$(m 'PermitTunnel is disabled.' 'PermitTunnel is disabled.')"; fi

  if [[ "$maxauth" =~ ^[0-9]+$ ]] && [ "$maxauth" -le 3 ]; then status_ok "$(m 'MaxAuthTries is strict enough.' 'MaxAuthTries is strict enough.')"; else status_warn "$(m 'Consider MaxAuthTries 3.' 'Consider MaxAuthTries 3.')"; fi
  if [[ "$grace" =~ ^[0-9]+$ ]] && [ "$grace" -le 60 ]; then status_ok "$(m 'LoginGraceTime is reasonably short.' 'LoginGraceTime is reasonably short.')"; else status_warn "$(m 'Consider LoginGraceTime 30.' 'Consider LoginGraceTime 30.')"; fi

  if [ "$nonroot_count" -gt 0 ]; then
    echo
    muted "  $(m 'Interactive users:' 'Interactive users:')"
    interactive_users | print_block
  fi
}

valid_ssh_public_key() {
  local key="$1" type blob rest tmp rc
  read -r type blob rest <<< "$key"
  [ -n "$type" ] && [ -n "$blob" ] || return 1
  case "$type" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) return 1 ;;
  esac
  [[ "$blob" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  if has_cmd ssh-keygen; then
    tmp="$(mktemp)" || return 1
    printf '%s\n' "$key" > "$tmp" || { rm -f "$tmp"; return 1; }
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  return 0
}

extract_ssh_key_from_authorized_line() {
  local line="$1" i j
  local -a parts
  read -r -a parts <<< "$line"
  for i in "${!parts[@]}"; do
    case "${parts[$i]}" in
      ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
        printf '%s' "${parts[$i]}"
        for ((j = i + 1; j < ${#parts[@]}; j++)); do
          printf ' %s' "${parts[$j]}"
        done
        printf '\n'
        return 0
        ;;
    esac
  done
  return 1
}

ssh_key_line_valid() {
  local line="$1" key
  [ -n "$line" ] || return 1
  [[ "$line" != \#* ]] || return 1
  key="$(extract_ssh_key_from_authorized_line "$line")" || return 1
  valid_ssh_public_key "$key"
}

ssh_path_secure_for_user() {
  local path="$1" user="$2" owner_uid mode user_uid
  [ -e "$path" ] || return 1
  owner_uid="$(stat -c %u "$path" 2>/dev/null || true)"
  mode="$(stat -c %a "$path" 2>/dev/null || true)"
  user_uid="$(id -u "$user" 2>/dev/null || true)"
  [[ "$owner_uid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$user_uid" =~ ^[0-9]+$ ]] || return 1
  [ "$owner_uid" -eq 0 ] || [ "$owner_uid" -eq "$user_uid" ] || return 1
  mode="${mode: -3}"
  (( (8#$mode & 8#022) == 0 ))
}

user_has_authorized_key() {
  local user="$1" home auth line
  if [ "$user" = "root" ]; then
    home="/root"
  else
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  [ -n "$home" ] && [ -r "$home/.ssh/authorized_keys" ] || return 1
  auth="$home/.ssh/authorized_keys"
  ssh_path_secure_for_user "$home" "$user" || return 1
  ssh_path_secure_for_user "$home/.ssh" "$user" || return 1
  ssh_path_secure_for_user "$auth" "$user" || return 1
  while IFS= read -r line; do
    ssh_key_line_valid "$line" && return 0
  done < "$auth"
  return 1
}

ssh_key_login_ready() {
  local allow_users="$1" permit_root="${2:-prohibit-password}" token user found=0
  if [ -n "$allow_users" ]; then
    for token in $allow_users; do
      user="${token%@*}"
      case "$user" in
        ""|*[\*\?]*) continue ;;
      esac
      [ "$user" = "root" ] && [ "$permit_root" = "no" ] && continue
      if user_has_authorized_key "$user"; then
        found=1
        break
      fi
    done
  else
    if [ "$permit_root" != "no" ] && user_has_authorized_key root; then
      found=1
    else
      while IFS=: read -r user _; do
        [ "$user" = "root" ] && continue
        if user_has_authorized_key "$user"; then
          found=1
          break
        fi
      done < <(interactive_users)
    fi
  fi
  [ "$found" -eq 1 ]
}

ssh_require_key_login_ready() {
  local allow_users="$1" permit_root="${2:-prohibit-password}"
  ssh_key_login_ready "$allow_users" "$permit_root" && return 0
  red "$(m 'Refusing SSH authentication hardening: no usable authorized_keys entry was found for an account that remains allowed.' 'Refusing SSH authentication hardening: no usable authorized_keys entry was found for an account that remains allowed.')"
  status_info "$(m 'Install and test a public key first. The tool will not rely on an unverified password path after restricting root or password login.' 'Install and test a public key first. The tool will not rely on an unverified password path after restricting root or password login.')"
  return 1
}

ssh_install_key() {
  local user key home auth group
  user="$(input_default "$(m 'Target user' 'Target user')" "root")"
  read -r -p "$(m 'Paste SSH public key: ' 'Paste SSH public key: ')" key || true
  [ -n "$key" ] || { red "$(m 'Empty key.' 'Empty key.')"; return 1; }
  valid_ssh_public_key "$key" || { red "$(m 'Invalid SSH public key format.' 'Invalid SSH public key format.')"; return 1; }
  if [ "$user" = "root" ]; then home="/root"; else home="$(getent passwd "$user" | cut -d: -f6)"; fi
  [ -d "$home" ] || { red "$(m "User home not found: $home" "User home not found: $home")"; return 1; }
  mkdir -p "$home/.ssh"
  group="$(id -gn "$user" 2>/dev/null || echo "$user")"
  auth="$home/.ssh/authorized_keys"
  touch "$auth"
  chmod 700 "$home/.ssh"
  chmod 600 "$auth"
  grep -qxF "$key" "$auth" || echo "$key" >> "$auth"
  chown -R "$user:$group" "$home/.ssh" 2>/dev/null || true
  green "$(m "Public key installed for $user." "Public key installed for $user.")"
}

ssh_reload_or_restart() {
  systemctl reload ssh 2>/dev/null && return 0
  systemctl reload sshd 2>/dev/null && return 0
  systemctl restart ssh 2>/dev/null && return 0
  systemctl restart sshd 2>/dev/null && return 0
  return 1
}

ssh_remove_hardening_fragment() {
  rm -f "$SSH_HARDENING_FRAGMENT"
  sshd -t 2>/dev/null || return 1
  ssh_reload_or_restart
}

ssh_restore_hardening_backup() {
  local backup="${1:-}"
  if [ -n "$backup" ] && [ -e "$backup" ]; then
    cp -a "$backup" "$SSH_HARDENING_FRAGMENT"
  else
    rm -f "$SSH_HARDENING_FRAGMENT"
  fi
  sshd -t 2>/dev/null || return 1
  ssh_reload_or_restart
}

ssh_write_hardening() {
  local port allow_user password_policy permit_root strict_forwarding allow_tcp fragment_backup="" fragment_tmp=""
  port="$(input_default "$(m 'New SSH port' 'New SSH port')" "$(current_ssh_port_guess)")"
  valid_port "$port" || { red "$(m 'Invalid SSH port. Use 1-65535.' 'Invalid SSH port. Use 1-65535.')"; return 1; }
  allow_user="$(input_default "$(m 'AllowUsers value, empty means do not set' 'AllowUsers value, empty means do not set')" "")"
  valid_allow_users_value "$allow_user" || { red "$(m 'Invalid AllowUsers value. Use space-separated usernames or user@host patterns only.' 'Invalid AllowUsers value. Use space-separated usernames or user@host patterns only.')"; return 1; }
  password_policy="$(normalize_password_policy "$(input_default "$(m 'PasswordAuthentication policy: keep/no/yes' 'PasswordAuthentication policy: keep/no/yes')" "keep")")" || { red "$(m 'Invalid PasswordAuthentication policy. Use keep, no, or yes.' 'Invalid PasswordAuthentication policy. Use keep, no, or yes.')"; return 1; }
  if [ "$password_policy" = "yes" ]; then
    yellow "$(m 'Enabling SSH password login is usually not recommended.' 'Enabling SSH password login is usually not recommended.')"
    confirm_yes "$(m 'Explicitly enable SSH password login?' 'Explicitly enable SSH password login?')" || return 0
  fi
  permit_root="$(input_default "PermitRootLogin" "prohibit-password")"
  valid_permit_root_login "$permit_root" || { red "$(m 'Invalid PermitRootLogin policy. Use yes, prohibit-password, forced-commands-only, no, or without-password.' 'Invalid PermitRootLogin policy. Use yes, prohibit-password, forced-commands-only, no, or without-password.')"; return 1; }
  strict_forwarding="$(input_yes_no "$(m 'Disable Agent/X11/Tunnel/Gateway forwarding?' 'Disable Agent/X11/Tunnel/Gateway forwarding?')" "yes")" || return 1
  allow_tcp="$(input_yes_no "$(m 'Allow TCP forwarding for ssh -L/-R/-D?' 'Allow TCP forwarding for ssh -L/-R/-D?')" "yes")" || return 1
  if [ "$password_policy" = "no" ] || [ "$permit_root" != "yes" ]; then
    ssh_require_key_login_ready "$allow_user" "$permit_root" || return 1
  fi

  backup_path /etc/ssh/sshd_config >/dev/null || { red "Failed to back up /etc/ssh/sshd_config."; return 1; }
  mkdir -p /etc/ssh/sshd_config.d || { red "Failed to create /etc/ssh/sshd_config.d."; return 1; }
  if [ -e "$SSH_HARDENING_FRAGMENT" ]; then
    backup_path "$SSH_HARDENING_FRAGMENT" >/dev/null || { red "$(m 'Failed to back up the existing SSH hardening fragment.' 'Failed to back up the existing SSH hardening fragment.')"; return 1; }
    fragment_backup="$BACKUP_LAST_PATH"
  fi

  fragment_tmp="$(mktemp "/etc/ssh/sshd_config.d/.00-vps-init-hardening.conf.XXXXXX")" || {
    red "Failed to create an SSH hardening staging file."
    return 1
  }
  {
    cat <<EOF2
# Managed by $SCRIPT_NAME $TOOL_VERSION
Port $port
PubkeyAuthentication yes
PermitRootLogin $permit_root
MaxAuthTries 3
MaxSessions 3
MaxStartups 10:30:60
LoginGraceTime 30
PermitEmptyPasswords no
UsePAM yes
EOF2
    if [ "$password_policy" = "no" ]; then
      cat <<'EOF2'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF2
    elif [ "$password_policy" = "yes" ]; then
      printf 'PasswordAuthentication %s\n' "$password_policy"
    fi
    if [ "$strict_forwarding" = "yes" ]; then
      cat <<'EOF2'
X11Forwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
AllowStreamLocalForwarding no
EOF2
    fi
    printf 'AllowTcpForwarding %s\n' "$allow_tcp"
    [ -n "$allow_user" ] && printf 'AllowUsers %s\n' "$allow_user"
  } > "$fragment_tmp" || {
    cleanup_files "$fragment_tmp"
    red "Failed to write the SSH hardening staging file."
    return 1
  }
  chmod 600 "$fragment_tmp" || { cleanup_files "$fragment_tmp"; red "Failed to secure the SSH hardening staging file."; return 1; }
  if ! mv -f -- "$fragment_tmp" "$SSH_HARDENING_FRAGMENT"; then
    cleanup_files "$fragment_tmp"
    red "Failed to install the SSH hardening fragment."
    return 1
  fi
  fragment_tmp=""

  if ! sshd -t; then
    red "$(m 'sshd config test failed. Restoring the previous fragment.' 'sshd config test failed. Restoring the previous fragment.')"
    ssh_restore_hardening_backup "$fragment_backup" || red "$(m 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.' 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.')"
    return 1
  fi

  if ! ssh_verify_hardening_effective "$port" "$password_policy" "$permit_root" "$strict_forwarding" "$allow_tcp" "$allow_user"; then
    red "SSH hardening did not become effective. Restoring the previous fragment."
    status_info "Check that /etc/ssh/sshd_config includes /etc/ssh/sshd_config.d/*.conf before global SSH options."
    ssh_restore_hardening_backup "$fragment_backup" || red "Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually."
    return 1
  fi

  if has_cmd ufw; then
    ufw_ensure_ssh_access || { ssh_restore_hardening_backup "$fragment_backup"; return 1; }
    if ! ufw allow "$port/tcp" comment "SSH"; then
      red "$(m 'SSH firewall allow failed; restoring the previous fragment before SSH reload.' 'SSH firewall allow failed; restoring the previous fragment before SSH reload.')"
      ssh_restore_hardening_backup "$fragment_backup" || red "$(m 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.' 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.')"
      return 1
    fi
  fi
  if ! ssh_reload_or_restart; then
    red "SSH service reload/restart failed; restoring the previous hardening fragment to preserve existing access."
    ssh_restore_hardening_backup "$fragment_backup" || red "Rollback reload also failed; keep the current SSH session open and inspect sshd/systemd manually."
    return 1
  fi
  green "$(m "SSH config applied. Keep current session open and test: ssh -p $port <user>@<ip>" "SSH config applied. Keep current session open and test: ssh -p $port <user>@<ip>")"
  ssh_audit
}

ssh_restore_fragment() {
  confirm_yes "$(m 'Remove SSH fragment written by this script?' 'Remove SSH fragment written by this script?')" || return 0
  rm -f "$SSH_HARDENING_FRAGMENT" /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
  sshd -t && ssh_reload_or_restart
  green "$(m 'SSH hardening fragment removed.' 'SSH hardening fragment removed.')"
}

ssh_menu() {
  while true; do
    clear_screen
    title "SSH"
    echo "1) $(m 'SSH audit' 'SSH audit')"
    echo "2) $(m 'Install public key' 'Install public key')"
    echo "3) $(m 'Configure SSH hardening fragment' 'Configure SSH hardening fragment')"
    echo "4) $(m 'Restore/remove hardening fragment' 'Restore/remove hardening fragment')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) ssh_audit; pause ;;
      2) ssh_install_key; pause ;;
      3) ssh_write_hardening; pause ;;
      4) ssh_restore_fragment; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- UFW / Fail2ban ----------
ufw_install() { apt_install ufw; green "$(m 'UFW installed.' 'UFW installed.')"; }

ufw_warn_default_ssh_port() {
  local ssh_ports="$1"
  if printf ' %s ' "$ssh_ports" | grep -q ' 22 '; then
    yellow "$(m 'SSH appears to include the default port 22.' 'SSH appears to include the default port 22.')"
    status_info "$(m 'Before enabling UFW, consider using the SSH menu to move SSH to a custom port, install a public key, and use key-only login.' 'Before enabling UFW, consider using the SSH menu to move SSH to a custom port, install a public key, and use key-only login.')"
    status_info "$(m 'This tool will still allow the current SSH port(s) before UFW changes to avoid locking you out.' 'This tool will still allow the current SSH port(s) before UFW changes to avoid locking you out.')"
  fi
}

ufw_ensure_ssh_access() {
  local ssh_ports p
  ssh_ports="$(current_ssh_ports)"
  [ -n "$ssh_ports" ] || ssh_ports="22"
  ufw_warn_default_ssh_port "$ssh_ports"
  for p in $ssh_ports; do
    valid_port "$p" || { red "$(m "Invalid detected SSH port: $p" "Invalid detected SSH port: $p")"; return 1; }
    ufw allow "$p/tcp" comment "SSH" || return 1
  done
  status_ok "$(m "Allowed SSH port(s): $ssh_ports/tcp." "Allowed SSH port(s): $ssh_ports/tcp.")"
}

ufw_audit() {
  section "$(m 'Firewall audit' 'Firewall audit')"
  local ssh_ports ufw_state
  ssh_ports="$(current_ssh_ports)"

  if ! has_cmd ufw; then
    status_warn "$(m 'UFW is not installed.' 'UFW is not installed.')"
  else
    ufw_state="$(ufw status 2>/dev/null | awk 'NR==1 {print $2}')"
    kv "UFW status" "${ufw_state:-unknown}"
    if ufw status | grep -q inactive; then
      status_warn "$(m "UFW is inactive. Safe-init can allow SSH port(s) $ssh_ports before enabling." "UFW is inactive. Safe-init can allow SSH port(s) $ssh_ports before enabling.")"
    else
      status_ok "$(m 'UFW is active.' 'UFW is active.')"
    fi
    echo
    muted "  $(m 'UFW rules:' 'UFW rules:')"
    ufw status numbered 2>/dev/null | sed -n '1,25p' | print_block || true
  fi

  echo
  muted "  $(m 'Listening TCP/UDP ports and processes:' 'Listening TCP/UDP ports and processes:')"
  listening_ports_compact | print_block || true

  echo
  status_info "$(m "Current SSH port guess: $ssh_ports/tcp." "Current SSH port guess: $ssh_ports/tcp.")"
  status_warn "$(m 'Admin panels should usually be restricted to your management IP/CIDR.' 'Admin panels should usually be restricted to your management IP/CIDR.')"
  status_info "$(m 'If using Cloudflare CDN for 80/443, add CF allow rules first, then manually remove broad 80/443 rules after verification.' 'If using Cloudflare CDN for 80/443, add CF allow rules first, then manually remove broad 80/443 rules after verification.')"
}

ufw_init_safe() {
  ufw_install
  local ssh_ports
  ssh_ports="$(current_ssh_ports)"
  yellow "$(m "Will set: default deny incoming, allow outgoing, allow SSH port(s): $ssh_ports, then enable UFW." "Will set: default deny incoming, allow outgoing, allow SSH port(s): $ssh_ports, then enable UFW.")"
  ufw_warn_default_ssh_port "$ssh_ports"
  confirm_yes "$(m 'Enable UFW safely?' 'Enable UFW safely?')" || return 0
  ufw_ensure_ssh_access || return 1
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw status verbose
}

ufw_allow_port() {
  ufw_install
  local port proto comment
  port="$(input_default "$(m 'Port or range' 'Port or range')" "443")"
  proto="$(input_default "$(m 'Protocol tcp/udp' 'Protocol tcp/udp')" "tcp")"
  comment="$(input_default "$(m 'Comment' 'Comment')" "manual")"
  valid_port_or_range "$port" || { red "$(m 'Invalid port or range. Use 443 or 10000:20000.' 'Invalid port or range. Use 443 or 10000:20000.')"; return 1; }
  valid_proto "$proto" || { red "$(m 'Invalid protocol. Use tcp or udp.' 'Invalid protocol. Use tcp or udp.')"; return 1; }
  ufw allow "$port/$proto" comment "$comment"
  ufw status numbered
}

ufw_allow_ip_to_port() {
  ufw_install
  local ip port proto
  ip="$(input_default "$(m 'Allowed source IP/CIDR' 'Allowed source IP/CIDR')" "")"
  port="$(input_default "$(m 'Destination port' 'Destination port')" "")"
  proto="$(input_default "$(m 'Protocol tcp/udp' 'Protocol tcp/udp')" "tcp")"
  if [ -z "$ip" ] || [ -z "$port" ]; then red "$(m 'Source and port are required.' 'Source and port are required.')"; return 1; fi
  valid_port "$port" || { red "$(m 'Invalid destination port. Use 1-65535.' 'Invalid destination port. Use 1-65535.')"; return 1; }
  valid_proto "$proto" || { red "$(m 'Invalid protocol. Use tcp or udp.' 'Invalid protocol. Use tcp or udp.')"; return 1; }
  valid_ip_or_cidr "$ip" || { red "$(m 'Invalid source IP/CIDR. Use an IPv4/IPv6 address or CIDR such as 203.0.113.0/24.' 'Invalid source IP/CIDR. Use an IPv4/IPv6 address or CIDR such as 203.0.113.0/24.')"; return 1; }
  ufw allow from "$ip" to any port "$port" proto "$proto" comment "restricted-$port"
  ufw status numbered
}

ufw_limit_ssh() {
  ufw_install
  local p
  for p in $(current_ssh_ports); do ufw limit "$p/tcp" comment "rate-limit-ssh" || return 1; done
  ufw status numbered
}

cf_fetch_ranges() {
  local v4_tmp v6_tmp
  apt_install curl ca-certificates
  mkdir -p "$(dirname "$UFW_CF_IPV4_FILE")" "$(dirname "$UFW_CF_IPV6_FILE")" || return 1
  v4_tmp="$(mktemp "$(dirname "$UFW_CF_IPV4_FILE")/cloudflare-ips-v4.txt.XXXXXX")" || return 1
  v6_tmp="$(mktemp "$(dirname "$UFW_CF_IPV6_FILE")/cloudflare-ips-v6.txt.XXXXXX")" || { cleanup_files "$v4_tmp"; return 1; }
  if ! curl -fsSL "$CF_IPV4_URL" -o "$v4_tmp"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  if ! curl -fsSL "$CF_IPV6_URL" -o "$v6_tmp"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  sed -i 's/\r$//' "$v4_tmp" "$v6_tmp" || { cleanup_files "$v4_tmp" "$v6_tmp"; return 1; }
  validate_cloudflare_range_file "$v4_tmp" 4 || { cleanup_files "$v4_tmp" "$v6_tmp"; return 1; }
  validate_cloudflare_range_file "$v6_tmp" 6 || { cleanup_files "$v4_tmp" "$v6_tmp"; return 1; }
  if ! mv "$v4_tmp" "$UFW_CF_IPV4_FILE"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  if ! mv "$v6_tmp" "$UFW_CF_IPV6_FILE"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
}

validate_cloudflare_range_file() {
  local file="$1" family="$2" cidr count=0
  [ -r "$file" ] || { red "Cloudflare IPv${family} list is not readable."; return 1; }
  while IFS= read -r cidr || [ -n "$cidr" ]; do
    cidr="${cidr%$'\r'}"
    [ -n "$cidr" ] || continue
    [[ "$cidr" == */* ]] || { red "Cloudflare IPv${family} entry is not a CIDR: $cidr"; return 1; }
    valid_ip_or_cidr "$cidr" || { red "Invalid Cloudflare IPv${family} CIDR: $cidr"; return 1; }
    if { [ "$family" = "4" ] && [[ "$cidr" == *:* ]]; } || { [ "$family" = "6" ] && [[ "$cidr" != *:* ]]; }; then
      red "Cloudflare IPv${family} list contains the wrong address family: $cidr"
      return 1
    fi
    count=$((count + 1))
    [ "$count" -le 100 ] || { red "Cloudflare IPv${family} list unexpectedly exceeds 100 ranges."; return 1; }
  done < "$file"
  [ "$count" -gt 0 ] || { red "Cloudflare IPv${family} list is empty."; return 1; }
}

ufw_parse_cloudflare_ports() {
  local ports="$1" p
  IFS=',' read -ra port_arr <<< "$ports"
  for p in "${port_arr[@]}"; do
    p="$(echo "$p" | xargs)"
    valid_port "$p" || { red "$(m "Invalid Cloudflare port: $p" "Invalid Cloudflare port: $p")"; return 1; }
  done
}

ufw_build_cloudflare_desired_rules() {
  local output="$1" f cidr p
  : > "$output"
  for f in "$UFW_CF_IPV4_FILE" "$UFW_CF_IPV6_FILE"; do
    while read -r cidr; do
      [ -n "$cidr" ] || continue
      for p in "${port_arr[@]}"; do
        p="$(echo "$p" | xargs)"
        [ -n "$p" ] && printf '%s\t%s\n' "$cidr" "$p" >> "$output"
      done
    done < "$f"
  done
  sort -u "$output" -o "$output"
}

set_diff_file() {
  local exclude="$1" source="$2" output="$3"
  awk 'NR==FNR {seen[$0]=1; next} !($0 in seen)' "$exclude" "$source" > "$output"
}

ufw_delete_rule_exact() {
  local cidr="$1" port="$2"
  ufw --force delete allow proto tcp from "$cidr" to any port "$port" comment "cloudflare-$port" >/dev/null 2>&1
}

ufw_cf_state_commit() {
  local source="$1" state_tmp
  mkdir -p "$(dirname "$UFW_CF_STATE_FILE")" || return 1
  state_tmp="$(mktemp "$(dirname "$UFW_CF_STATE_FILE")/.cloudflare-ufw-state.XXXXXX")" || return 1
  if ! sort -u "$source" > "$state_tmp" || ! install -m 0644 "$state_tmp" "$UFW_CF_STATE_FILE"; then
    cleanup_files "$state_tmp"
    return 1
  fi
  cleanup_files "$state_tmp"
}

ufw_cf_state_add() {
  local state="$1" cidr="$2" port="$3"
  printf '%s\t%s\n' "$cidr" "$port" >> "$state" || return 1
  sort -u "$state" -o "$state" || return 1
  ufw_cf_state_commit "$state"
}

ufw_cf_state_remove() {
  local state="$1" cidr="$2" port="$3" filtered
  filtered="$(mktemp)" || return 1
  if ! awk -F '\t' -v cidr="$cidr" -v port="$port" '!(NF >= 2 && $1 == cidr && $2 == port)' "$state" > "$filtered"; then
    cleanup_files "$filtered"
    return 1
  fi
  mv "$filtered" "$state" || { cleanup_files "$filtered"; return 1; }
  ufw_cf_state_commit "$state"
}

ufw_cf_lock_acquire() {
  mkdir -p "$(dirname "$UFW_CF_LOCK_FILE")"
  if ! has_cmd flock; then
    red "$(m 'flock is required for safe Cloudflare UFW sync. Install util-linux and retry.' 'flock is required for safe Cloudflare UFW sync. Install util-linux and retry.')"
    return 1
  fi
  exec {UFW_CF_LOCK_FD}>"$UFW_CF_LOCK_FILE"
  if ! flock -w "${UFW_CF_LOCK_TIMEOUT:-120}" "$UFW_CF_LOCK_FD"; then
    red "$(m 'Another Cloudflare UFW sync is running; lock timeout reached.' 'Another Cloudflare UFW sync is running; lock timeout reached.')"
    exec {UFW_CF_LOCK_FD}>&- 2>/dev/null || true
    UFW_CF_LOCK_FD=""
    return 1
  fi
}

ufw_cf_lock_release() {
  [ -n "${UFW_CF_LOCK_FD:-}" ] || return 0
  if has_cmd flock; then flock -u "$UFW_CF_LOCK_FD" 2>/dev/null || true; fi
  exec {UFW_CF_LOCK_FD}>&-
  UFW_CF_LOCK_FD=""
}

ufw_cf_sync_cleanup() {
  cleanup_files "$@"
  ufw_cf_lock_release
}

ufw_sync_cloudflare_web() {
  ufw_install
  local ports desired="" current="" adds="" deletes="" add_count delete_count cidr p rule_error=0
  local -a port_arr
  if [ -n "${UFW_CF_PORTS:-}" ]; then
    ports="$UFW_CF_PORTS"
  else
    ports="$(input_default "$(m 'Ports to allow from Cloudflare only, comma-separated' 'Ports to allow from Cloudflare only, comma-separated')" "80,443")"
  fi
  ufw_parse_cloudflare_ports "$ports" || return 1
  yellow "$(m 'This incrementally syncs Cloudflare allow rules managed by this tool.' 'This incrementally syncs Cloudflare allow rules managed by this tool.')"
  yellow "$(m 'It will not remove broad manual 80/443 rules; review those after verification.' 'It will not remove broad manual 80/443 rules; review those after verification.')"
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    yellow "$(m 'UFW is inactive. Synced rules will not protect the origin until safe initialization enables UFW.' 'UFW is inactive. Synced rules will not protect the origin until safe initialization enables UFW.')"
  fi
  confirm_yes "$(m 'Continue Cloudflare UFW sync?' 'Continue Cloudflare UFW sync?')" || return 0

  ufw_cf_lock_acquire || return 1
  ufw_ensure_ssh_access || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }
  cf_fetch_ranges || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }

  desired="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }
  current="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }
  adds="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }
  deletes="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"; return 1; }

  ufw_build_cloudflare_desired_rules "$desired"
  if [ -f "$UFW_CF_STATE_FILE" ]; then
    sort -u "$UFW_CF_STATE_FILE" > "$current"
  else
    : > "$current"
  fi

  set_diff_file "$current" "$desired" "$adds"
  set_diff_file "$desired" "$current" "$deletes"
  add_count="$(wc -l < "$adds" | awk '{print $1}')"
  delete_count="$(wc -l < "$deletes" | awk '{print $1}')"
  status_info "$(m "Cloudflare rules to add: $add_count; managed stale rules to delete: $delete_count." "Cloudflare rules to add: $add_count; managed stale rules to delete: $delete_count.")"

  while read -r cidr p; do
    if [ -z "$cidr" ] || [ -z "$p" ]; then continue; fi
    if ! ufw allow proto tcp from "$cidr" to any port "$p" comment "cloudflare-$p"; then
      red "$(m "Cloudflare UFW add failed: $cidr -> $p/tcp. Managed state was not updated." "Cloudflare UFW add failed: $cidr -> $p/tcp. Managed state was not updated.")"
      rule_error=1
      break
    fi
    if ! ufw_cf_state_add "$current" "$cidr" "$p"; then
      red "$(m 'Cloudflare UFW rule was added, but managed progress could not be saved.' 'Cloudflare UFW rule was added, but managed progress could not be saved.')"
      rule_error=1
      break
    fi
  done < "$adds"
  if [ "$rule_error" -ne 0 ]; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"
    return 1
  fi

  while read -r cidr p; do
    if [ -z "$cidr" ] || [ -z "$p" ]; then continue; fi
    if ! ufw_delete_rule_exact "$cidr" "$p"; then
      red "$(m "Cloudflare UFW delete failed: $cidr -> $p/tcp. Managed state was not updated." "Cloudflare UFW delete failed: $cidr -> $p/tcp. Managed state was not updated.")"
      rule_error=1
      break
    fi
    if ! ufw_cf_state_remove "$current" "$cidr" "$p"; then
      red "$(m 'Cloudflare UFW stale rule was deleted, but managed progress could not be saved.' 'Cloudflare UFW stale rule was deleted, but managed progress could not be saved.')"
      rule_error=1
      break
    fi
  done < "$deletes"
  if [ "$rule_error" -ne 0 ]; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"
    return 1
  fi

  if ! ufw_cf_state_commit "$current"; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"
    return 1
  fi

  ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes"
  ufw status numbered || true
  green "$(m 'Cloudflare UFW sync complete.' 'Cloudflare UFW sync complete.')"
}

ufw_allow_cloudflare_web() {
  ufw_sync_cloudflare_web
}

ufw_reset_safe() {
  ufw_install
  confirm_yes "$(m 'Reset ALL UFW rules?' 'Reset ALL UFW rules?')" || return 0
  ufw --force reset || return 1
  rm -f -- "$UFW_CF_STATE_FILE"
  green "$(m 'UFW reset.' 'UFW reset.')"
}

ufw_menu() {
  while true; do
    clear_screen
    title "$(m 'UFW Firewall' 'UFW Firewall')"
    echo "1) $(m 'Firewall audit' 'Firewall audit')"
    echo "2) $(m 'Install UFW' 'Install UFW')"
    echo "3) $(m 'Safe init UFW' 'Safe init UFW')"
    echo "4) $(m 'Allow custom port' 'Allow custom port')"
    echo "5) $(m 'Allow only IP/CIDR to port' 'Allow only IP/CIDR to port')"
    echo "6) $(m 'Rate-limit SSH' 'Rate-limit SSH')"
    echo "7) $(m 'Add Cloudflare ranges to 80/443' 'Add Cloudflare ranges to 80/443')"
    echo "8) $(m 'Reset UFW' 'Reset UFW')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) ufw_audit; pause ;;
      2) ufw_install; pause ;;
      3) ufw_init_safe; pause ;;
      4) ufw_allow_port; pause ;;
      5) ufw_allow_ip_to_port; pause ;;
      6) ufw_limit_ssh; pause ;;
      7) ufw_allow_cloudflare_web; pause ;;
      8) ufw_reset_safe; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

fail2ban_audit() {
  section "$(m 'Fail2ban audit' 'Fail2ban audit')"
  if ! has_cmd fail2ban-client; then
    status_warn "$(m 'Fail2ban is not installed.' 'Fail2ban is not installed.')"
    return 0
  fi
  local active jails tmp
  active="$(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
  jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
  kv "Service" "$active"
  kv "Jails" "${jails:-none}"
  tmp="$(mktemp)"
  if fail2ban-client status sshd >"$tmp" 2>/dev/null; then
    status_ok "$(m 'sshd jail is active.' 'sshd jail is active.')"
    sed -n '1,20p' "$tmp" | print_block
  else
    status_warn "$(m 'sshd jail is not active or not found.' 'sshd jail is not active or not found.')"
  fi
  rm -f "$tmp"
}

fail2ban_setup_sshd() {
  require_systemd || return 1
  apt_install fail2ban
  mkdir -p /etc/fail2ban/jail.d
  local jail_file="/etc/fail2ban/jail.d/sshd-vps-init.local"
  local bantime findtime maxretry ports jail_backup=""
  bantime="$(input_default "bantime" "12h")"
  findtime="$(input_default "findtime" "10m")"
  maxretry="$(input_default "maxretry" "3")"
  valid_fail2ban_time "$bantime" || { red "$(m 'Invalid bantime. Use values such as 12h, 30m, 600, or -1.' 'Invalid bantime. Use values such as 12h, 30m, 600, or -1.')"; return 1; }
  valid_fail2ban_time "$findtime" || { red "$(m 'Invalid findtime. Use values such as 10m or 600.' 'Invalid findtime. Use values such as 10m or 600.')"; return 1; }
  valid_positive_int "$maxretry" || { red "$(m 'Invalid maxretry. Use a positive integer.' 'Invalid maxretry. Use a positive integer.')"; return 1; }
  ports="$(current_ssh_ports | tr ' ' ',')"
  if [ -e "$jail_file" ]; then
    backup_path "$jail_file" >/dev/null || { red "$(m 'Failed to back up the existing Fail2ban jail.' 'Failed to back up the existing Fail2ban jail.')"; return 1; }
    jail_backup="$BACKUP_LAST_PATH"
  fi
  cat > "$jail_file" <<EOF2
[sshd]
enabled = true
backend = systemd
port = $ports
filter = sshd
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
EOF2
  if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then echo "banaction = ufw" >> "$jail_file"; fi
  if ! fail2ban-client -t; then
    red "$(m 'Fail2ban configuration test failed. Restoring the previous jail.' 'Fail2ban configuration test failed. Restoring the previous jail.')"
    if [ -n "$jail_backup" ]; then cp -a "$jail_backup" "$jail_file"; else rm -f "$jail_file"; fi
    fail2ban-client -t || true
    return 1
  fi
  if ! systemctl enable --now fail2ban || ! systemctl restart fail2ban; then
    red "$(m 'Fail2ban service activation failed. Restoring the previous jail.' 'Fail2ban service activation failed. Restoring the previous jail.')"
    if [ -n "$jail_backup" ]; then cp -a "$jail_backup" "$jail_file"; else rm -f "$jail_file"; fi
    systemctl restart fail2ban 2>/dev/null || status_warn "$(m 'Failed to restart fail2ban after restoring jail. Check fail2ban manually.' 'Failed to restart fail2ban after restoring jail. Check fail2ban manually.')"
    return 1
  fi
  fail2ban_audit
}

fail2ban_unban() {
  local jail ip
  jail="$(input_default "Jail" "sshd")"
  ip="$(input_default "$(m 'IP to unban' 'IP to unban')" "")"
  [ -n "$ip" ] || return 1
  valid_ip_literal "$ip" || { red "$(m 'Invalid IP to unban.' 'Invalid IP to unban.')"; return 1; }
  fail2ban-client set "$jail" unbanip "$ip"
}

fail2ban_menu() {
  while true; do
    clear_screen
    title "Fail2ban"
    echo "1) $(m 'Audit' 'Audit')"
    echo "2) $(m 'Install/configure sshd jail' 'Install/configure sshd jail')"
    echo "3) $(m 'Unban IP' 'Unban IP')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) fail2ban_audit; pause ;;
      2) fail2ban_setup_sshd; pause ;;
      3) fail2ban_unban; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- DNS ----------
dns_audit() {
  section "$(m 'DNS audit' 'DNS audit')"
  local target nameservers resolved_state
  target="$(readlink -f /etc/resolv.conf 2>/dev/null || echo plain-file)"
  nameservers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)"
  kv "/etc/resolv.conf" "$target"
  kv "Nameservers" "${nameservers:-none}"

  if is_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved.service'; then
    resolved_state="$(systemctl is-active systemd-resolved 2>/dev/null || echo inactive)"
    kv "systemd-resolved" "$resolved_state"
  else
    kv "systemd-resolved" "not detected"
  fi

  if grep -qi cloud-init /etc/resolv.conf 2>/dev/null; then
    status_warn "$(m '/etc/resolv.conf appears cloud-init managed; direct edits may be overwritten.' '/etc/resolv.conf appears cloud-init managed; direct edits may be overwritten.')"
  fi
  if has_cmd resolvectl; then
    echo
    muted "  resolvectl DNS servers:"
    resolvectl dns 2>/dev/null | print_block || true
  fi
  echo
  status_info "$(m 'Use DNS test before applying changes on production servers.' 'Use DNS test before applying changes on production servers.')"
}

dns_query_time_ms() {
  local server="$1" name="$2" start end tmp
  tmp="$(mktemp)"
  start="$(date +%s%3N)"
  if timeout 3 dig +time=2 +tries=1 +short "@$server" "$name" A >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    end="$(date +%s%3N)"
    rm -f "$tmp"
    echo $((end - start))
  else
    rm -f "$tmp"
    echo "fail"
  fi
}

dns_test() {
  apt_install dnsutils
  local servers=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" "9.9.9.9" "149.112.112.112" "208.67.222.222" "208.67.220.220")
  local names=("google.com" "cloudflare.com" "github.com" "debian.org")
  local s n t total count fail avg
  printf "%-18s %-10s %-10s\n" "DNS" "AVG(ms)" "FAILS"
  for s in "${servers[@]}"; do
    total=0; count=0; fail=0
    for n in "${names[@]}"; do
      t="$(dns_query_time_ms "$s" "$n")"
      if [ "$t" = "fail" ]; then fail=$((fail + 1)); else total=$((total + t)); count=$((count + 1)); fi
    done
    if [ "$count" -gt 0 ]; then avg=$((total / count)); else avg="fail"; fi
    printf "%-18s %-10s %-10s\n" "$s" "$avg" "$fail"
  done
}

dns_restore_resolved_backup() {
  local config_file="$1" backup="${2:-}"
  if [ -n "$backup" ] && [ -e "$backup" ]; then
    cp -a "$backup" "$config_file"
  else
    rm -f "$config_file"
  fi
  systemctl restart systemd-resolved 2>/dev/null || status_warn "$(m 'Failed to restart systemd-resolved after restoring backup. Check DNS manually.' 'Failed to restart systemd-resolved after restoring backup. Check DNS manually.')"
}

dns_apply_resolved() {
  local dns fallback config_file="/etc/systemd/resolved.conf.d/10-vps-init-dns.conf" config_backup=""
  require_systemd || return 1
  systemctl list-unit-files | grep -q '^systemd-resolved.service' || { red "systemd-resolved not found."; return 1; }
  dns="$(input_default "$(m 'Primary DNS servers, space-separated' 'Primary DNS servers, space-separated')" "1.1.1.1 8.8.8.8")"
  fallback="$(input_default "$(m 'Fallback DNS servers, space-separated' 'Fallback DNS servers, space-separated')" "1.0.0.1 8.8.4.4")"
  valid_ip_list "$dns" || { red "$(m 'Invalid primary DNS server list. Use space-separated IPv4/IPv6 addresses.' 'Invalid primary DNS server list. Use space-separated IPv4/IPv6 addresses.')"; return 1; }
  valid_ip_list "$fallback" || { red "$(m 'Invalid fallback DNS server list. Use space-separated IPv4/IPv6 addresses.' 'Invalid fallback DNS server list. Use space-separated IPv4/IPv6 addresses.')"; return 1; }
  confirm_yes "$(m 'Apply DNS via systemd-resolved?' 'Apply DNS via systemd-resolved?')" || return 0
  mkdir -p /etc/systemd/resolved.conf.d
  if [ -e "$config_file" ]; then
    backup_path "$config_file" >/dev/null || { red "$(m 'Failed to back up the existing systemd-resolved configuration.' 'Failed to back up the existing systemd-resolved configuration.')"; return 1; }
    config_backup="$BACKUP_LAST_PATH"
  fi
  cat > "$config_file" <<EOF2
[Resolve]
DNS=$dns
FallbackDNS=$fallback
Cache=yes
EOF2
  if ! systemctl enable --now systemd-resolved || ! systemctl restart systemd-resolved; then
    red "$(m 'systemd-resolved activation failed. Restoring the previous configuration.' 'systemd-resolved activation failed. Restoring the previous configuration.')"
    dns_restore_resolved_backup "$config_file" "$config_backup"
    return 1
  fi
  dns_audit
}

dns_apply_resolvconf() {
  local dns1 dns2
  dns1="$(input_default "nameserver 1" "1.1.1.1")"
  dns2="$(input_default "nameserver 2" "8.8.8.8")"
  valid_ip_literal "$dns1" || { red "$(m 'Invalid nameserver 1. Use an IPv4 or IPv6 address.' 'Invalid nameserver 1. Use an IPv4 or IPv6 address.')"; return 1; }
  valid_ip_literal "$dns2" || { red "$(m 'Invalid nameserver 2. Use an IPv4 or IPv6 address.' 'Invalid nameserver 2. Use an IPv4 or IPv6 address.')"; return 1; }
  [ -L /etc/resolv.conf ] && { red "$(m '/etc/resolv.conf is a managed symbolic link. Use the systemd-resolved option or update the owning network manager instead.' '/etc/resolv.conf is a managed symbolic link. Use the systemd-resolved option or update the owning network manager instead.')"; return 1; }
  yellow "$(m 'Direct /etc/resolv.conf edits may be overwritten by cloud-init, DHCP, NetworkManager, or systemd-resolved.' 'Direct /etc/resolv.conf edits may be overwritten by cloud-init, DHCP, NetworkManager, or systemd-resolved.')"
  confirm_yes "$(m 'Edit /etc/resolv.conf directly?' 'Edit /etc/resolv.conf directly?')" || return 0
  backup_path /etc/resolv.conf >/dev/null
  cat > /etc/resolv.conf <<EOF2
nameserver $dns1
nameserver $dns2
options timeout:2 attempts:2 rotate
EOF2
  dns_audit
}

dns_menu() {
  while true; do
    clear_screen
    title "DNS"
    echo "1) $(m 'DNS audit' 'DNS audit')"
    echo "2) $(m 'Test common public resolvers' 'Test common public resolvers')"
    echo "3) $(m 'Apply via systemd-resolved' 'Apply via systemd-resolved')"
    echo "4) $(m 'Apply by direct /etc/resolv.conf edit' 'Apply by direct /etc/resolv.conf edit')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) dns_audit; pause ;;
      2) dns_test; pause ;;
      3) dns_apply_resolved; pause ;;
      4) dns_apply_resolvconf; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- logs ----------
logs_audit() {
  section "$(m 'Logs audit' 'Logs audit')"
  local journal_usage varlog_size
  if is_systemd; then
    journal_usage="$(journalctl --disk-usage 2>/dev/null | sed 's/^/ /')"
    kv "journald usage" "${journal_usage:-unknown}"
    if [ -f /etc/systemd/journald.conf.d/99-vps-init-size-limit.conf ]; then
      status_ok "$(m 'vps-init journald size limit is configured.' 'vps-init journald size limit is configured.')"
    else
      status_warn "$(m 'No vps-init journald limit found. Consider setting SystemMaxUse.' 'No vps-init journald limit found. Consider setting SystemMaxUse.')"
    fi
  else
    status_warn "$(m 'systemd not detected; journald audit skipped.' 'systemd not detected; journald audit skipped.')"
  fi

  varlog_size="$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
  kv "/var/log size" "${varlog_size:-unknown}"
  echo
  muted "  $(m 'Largest /var/log entries:' 'Largest /var/log entries:')"
  du -ah /var/log 2>/dev/null | sort -hr | head -8 | print_block || true
}

logs_limit_journald() {
  require_systemd || return 1
  local system_max runtime_max retention
  local config_file="/etc/systemd/journald.conf.d/99-vps-init-size-limit.conf" config_backup=""
  system_max="${1:-$(input_default "SystemMaxUse" "200M")}"
  runtime_max="${2:-$(input_default "RuntimeMaxUse" "100M")}"
  retention="${3:-$(input_default "MaxRetentionSec" "7day")}"
  valid_systemd_size "$system_max" || { red "$(m 'Invalid SystemMaxUse. Use values such as 200M or 1G.' 'Invalid SystemMaxUse. Use values such as 200M or 1G.')"; return 1; }
  valid_systemd_size "$runtime_max" || { red "$(m 'Invalid RuntimeMaxUse. Use values such as 100M or 1G.' 'Invalid RuntimeMaxUse. Use values such as 100M or 1G.')"; return 1; }
  valid_systemd_timespan "$retention" || { red "$(m 'Invalid MaxRetentionSec. Use values such as 7day or 24h.' 'Invalid MaxRetentionSec. Use values such as 7day or 24h.')"; return 1; }
  mkdir -p /etc/systemd/journald.conf.d
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<EOF2 || return 1
[Journal]
SystemMaxUse=$system_max
RuntimeMaxUse=$runtime_max
MaxRetentionSec=$retention
Compress=yes
EOF2
  if ! systemctl restart systemd-journald; then
    red "$(m 'Failed to restart systemd-journald. Restoring the previous configuration.' 'Failed to restart systemd-journald. Restoring the previous configuration.')"
    restore_managed_file "$config_file" "$config_backup"
    systemctl restart systemd-journald 2>/dev/null || status_warn "$(m 'Failed to restart systemd-journald after restoring backup. Check journald manually.' 'Failed to restart systemd-journald after restoring backup. Check journald manually.')"
    return 1
  fi
  journalctl --disk-usage || true
}

logs_vacuum() {
  require_systemd || return 1
  local size
  size="$(input_default "$(m 'Vacuum journal down to size' 'Vacuum journal down to size')" "200M")"
  valid_systemd_size "$size" || { red "$(m 'Invalid journal vacuum size. Use values such as 200M or 1G.' 'Invalid journal vacuum size. Use values such as 200M or 1G.')"; return 1; }
  confirm_yes "$(m "Vacuum journald logs to $size?" "Vacuum journald logs to $size?")" || return 0
  journalctl --vacuum-size="$size"
  journalctl --disk-usage || true
}

logs_menu() {
  while true; do
    clear_screen
    title "$(m 'Logs' 'Logs')"
    echo "1) $(m 'Logs audit' 'Logs audit')"
    echo "2) $(m 'Limit journald size' 'Limit journald size')"
    echo "3) $(m 'Vacuum journald now' 'Vacuum journald now')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) logs_audit; pause ;;
      2) logs_limit_journald; pause ;;
      3) logs_vacuum; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- automatic security updates ----------
security_updates_audit() {
  section "$(m 'Automatic security updates audit' 'Automatic security updates audit')"
  local dump="" update_lists="unset" unattended="unset" auto_reboot="false" package_state="not-installed"
  local daily_enabled="unknown" upgrade_enabled="unknown" daily_active="unknown" upgrade_active="unknown"

  if ! has_cmd apt-config; then
    status_warn "$(m 'apt-config is unavailable; automatic security updates are supported only on Debian/Ubuntu.' 'apt-config is unavailable; automatic security updates are supported only on Debian/Ubuntu.')"
    return 0
  fi
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    package_state="installed"
  fi
  if dump="$(apt-config dump 2>/dev/null)"; then
    update_lists="$(apt_config_value_from_text "$dump" 'APT::Periodic::Update-Package-Lists')"
    unattended="$(apt_config_value_from_text "$dump" 'APT::Periodic::Unattended-Upgrade')"
    auto_reboot="$(apt_config_value_from_text "$dump" 'Unattended-Upgrade::Automatic-Reboot')"
  else
    status_warn "$(m 'Unable to read the effective APT configuration.' 'Unable to read the effective APT configuration.')"
  fi
  update_lists="${update_lists:-unset}"
  unattended="${unattended:-unset}"
  auto_reboot="${auto_reboot:-false}"

  kv "Package" "$package_state"
  kv "Update-Package-Lists" "$update_lists"
  kv "Unattended-Upgrade" "$unattended"
  kv "Automatic-Reboot" "$auto_reboot"
  kv "Managed policy" "$([ -f "$AUTO_UPGRADES_CONFIG" ] && echo present || echo absent)"

  if is_systemd; then
    daily_enabled="$(systemctl is-enabled apt-daily.timer 2>/dev/null || true)"
    upgrade_enabled="$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
    daily_active="$(systemctl is-active apt-daily.timer 2>/dev/null || true)"
    upgrade_active="$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true)"
    daily_enabled="${daily_enabled:-disabled}"
    upgrade_enabled="${upgrade_enabled:-disabled}"
    daily_active="${daily_active:-inactive}"
    upgrade_active="${upgrade_active:-inactive}"
    kv "apt-daily.timer" "$daily_enabled/$daily_active"
    kv "apt-daily-upgrade.timer" "$upgrade_enabled/$upgrade_active"
  else
    status_info "$(m 'systemd timers are unavailable; APT may use cron instead.' 'systemd timers are unavailable; APT may use cron instead.')"
  fi

  if [ "$package_state" = "installed" ] && [ "$update_lists" = "1" ] && [ "$unattended" = "1" ]; then
    status_ok "$(m 'Daily unattended security updates are enabled through the distro configuration.' 'Daily unattended security updates are enabled through the distro configuration.')"
  else
    status_warn "$(m 'Automatic security updates are not fully enabled.' 'Automatic security updates are not fully enabled.')"
  fi
  case "$auto_reboot" in
    true|yes|1) status_warn "$(m 'Automatic reboot is enabled; review maintenance-window requirements.' 'Automatic reboot is enabled; review maintenance-window requirements.')" ;;
    *) status_ok "$(m 'Automatic reboot is disabled.' 'Automatic reboot is disabled.')" ;;
  esac
  if [ -e /var/run/reboot-required ]; then
    status_warn "$(m 'A reboot is currently required to finish installed updates.' 'A reboot is currently required to finish installed updates.')"
  fi
  if [ -d /var/log/unattended-upgrades ]; then
    kv "Logs" "/var/log/unattended-upgrades"
  fi
}

security_updates_policy_effective() {
  local expected="$1" dump update_lists unattended auto_reboot
  dump="$(apt-config dump 2>/dev/null)" || return 1
  update_lists="$(apt_config_value_from_text "$dump" 'APT::Periodic::Update-Package-Lists')"
  unattended="$(apt_config_value_from_text "$dump" 'APT::Periodic::Unattended-Upgrade')"
  auto_reboot="$(apt_config_value_from_text "$dump" 'Unattended-Upgrade::Automatic-Reboot')"
  if [ "$update_lists" != "$expected" ] || [ "$unattended" != "$expected" ] || [ "${auto_reboot:-false}" != "false" ]; then
    status_bad "Effective automatic updates policy mismatch: update-lists=${update_lists:-unset}, unattended=${unattended:-unset}, automatic-reboot=${auto_reboot:-false}."
    return 1
  fi
}

security_updates_fully_enabled() {
  has_cmd apt-config && has_cmd dpkg-query || return 1
  dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' || return 1
  security_updates_policy_effective 1 >/dev/null 2>&1 || return 1
  if is_systemd; then
    systemctl is-enabled --quiet apt-daily.timer 2>/dev/null || return 1
    systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null || return 1
  fi
}

security_updates_write_policy() {
  local enabled="$1" config_backup="" policy_tmp="" policy_dir=""
  [ "$enabled" = "0" ] || [ "$enabled" = "1" ] || return 1
  policy_dir="$(dirname "$AUTO_UPGRADES_CONFIG")"
  mkdir -p "$policy_dir" || return 1
  backup_path "$AUTO_UPGRADES_CONFIG" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  policy_tmp="$(mktemp "$policy_dir/.52-vps-init-auto-upgrades.XXXXXX")" || return 1
  if ! cat > "$policy_tmp" <<EOF2
// Managed by $SCRIPT_NAME $TOOL_VERSION
// Distribution-provided Allowed-Origins/Origins-Pattern settings remain authoritative.
APT::Periodic::Update-Package-Lists "$enabled";
APT::Periodic::Unattended-Upgrade "$enabled";
Unattended-Upgrade::Automatic-Reboot "false";
EOF2
  then
    cleanup_files "$policy_tmp"
    return 1
  fi
  chmod 644 "$policy_tmp" || { cleanup_files "$policy_tmp"; return 1; }
  mv -f -- "$policy_tmp" "$AUTO_UPGRADES_CONFIG" || { cleanup_files "$policy_tmp"; return 1; }
  if ! apt-config dump >/dev/null || ! security_updates_policy_effective "$enabled"; then
    red "$(m 'APT configuration validation or effective policy check failed. Restoring the previous automatic updates policy.' 'APT configuration validation or effective policy check failed. Restoring the previous automatic updates policy.')"
    restore_managed_file "$AUTO_UPGRADES_CONFIG" "$config_backup" || status_bad "$(m 'Failed to restore the previous automatic updates policy.' 'Failed to restore the previous automatic updates policy.')"
    return 1
  fi
  if [ "$enabled" = "1" ]; then
    if ! systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then
      red "$(m 'Failed to enable the standard APT timers. Restoring the previous automatic updates policy.' 'Failed to enable the standard APT timers. Restoring the previous automatic updates policy.')"
      restore_managed_file "$AUTO_UPGRADES_CONFIG" "$config_backup" || status_bad "$(m 'Failed to restore the previous automatic updates policy.' 'Failed to restore the previous automatic updates policy.')"
      return 1
    fi
  fi
}

security_updates_enable() {
  require_systemd || return 1
  yellow "$(m 'This enables the distro unattended-upgrades policy and standard daily APT timers.' 'This enables the distro unattended-upgrades policy and standard daily APT timers.')"
  status_info "$(m 'Automatic reboot stays disabled; third-party repositories are not added to allowed origins.' 'Automatic reboot stays disabled; third-party repositories are not added to allowed origins.')"
  confirm_yes "$(m 'Enable daily automatic security updates?' 'Enable daily automatic security updates?')" || return 0
  apt_install unattended-upgrades || return 1
  security_updates_write_policy 1 || return 1
  log_action "security-updates" "enabled automatic-reboot=false"
  green "$(m 'Automatic security updates enabled without automatic reboot.' 'Automatic security updates enabled without automatic reboot.')"
  security_updates_audit
}

security_updates_disable() {
  yellow "$(m 'This disables periodic package-list refresh and unattended upgrades through the tool-managed policy.' 'This disables periodic package-list refresh and unattended upgrades through the tool-managed policy.')"
  confirm_yes "$(m 'Disable automatic security updates?' 'Disable automatic security updates?')" || return 0
  security_updates_write_policy 0 || return 1
  log_action "security-updates" "disabled"
  green "$(m 'Automatic security updates disabled by the managed policy; the package was not removed.' 'Automatic security updates disabled by the managed policy; the package was not removed.')"
  security_updates_audit
}

security_updates_menu() {
  while true; do
    clear_screen
    title "$(m 'Automatic Security Updates' 'Automatic Security Updates')"
    echo "1) $(m 'Audit effective policy' 'Audit effective policy')"
    echo "2) $(m 'Enable daily security updates (no automatic reboot)' 'Enable daily security updates (no automatic reboot)')"
    echo "3) $(m 'Disable automatic updates through managed policy' 'Disable automatic updates through managed policy')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) security_updates_audit; pause ;;
      2) security_updates_enable; pause ;;
      3) security_updates_disable; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

# ---------- layered optimization ----------
memory_profile_current() {
  local swappiness="$1" config_file="/etc/sysctl.d/99-memory-tuning.conf"
  [ "$(sysctl -n vm.swappiness 2>/dev/null || true)" = "$swappiness" ] || return 1
  [ "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || true)" = "50" ] || return 1
  [ -f "$config_file" ] || return 1
  grep -Eq "^[[:space:]]*vm\.swappiness[[:space:]]*=[[:space:]]*$swappiness([[:space:]]*)$" "$config_file" || return 1
  grep -Eq '^[[:space:]]*vm\.vfs_cache_pressure[[:space:]]*=[[:space:]]*50([[:space:]]*)$' "$config_file"
}

bbr_profile_current() {
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = "bbr" ] || return 1
  [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" = "fq" ] || return 1
  [ -f /etc/sysctl.d/90-bbr.conf ] || return 1
  grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]*)$' /etc/sysctl.d/90-bbr.conf || return 1
  grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq([[:space:]]*)$' /etc/sysctl.d/90-bbr.conf
}

journald_profile_current() {
  local config_file="/etc/systemd/journald.conf.d/99-vps-init-size-limit.conf"
  [ -f "$config_file" ] || return 1
  grep -Eq '^[[:space:]]*SystemMaxUse[[:space:]]*=[[:space:]]*200M([[:space:]]*)$' "$config_file" || return 1
  grep -Eq '^[[:space:]]*RuntimeMaxUse[[:space:]]*=[[:space:]]*100M([[:space:]]*)$' "$config_file" || return 1
  grep -Eq '^[[:space:]]*MaxRetentionSec[[:space:]]*=[[:space:]]*7day([[:space:]]*)$' "$config_file" || return 1
  grep -Eq '^[[:space:]]*Compress[[:space:]]*=[[:space:]]*yes([[:space:]]*)$' "$config_file"
}

optimization_assessment() {
  local support missing swappiness_rec effective="" ssh_ports="unknown" ssh_pass="unknown" ssh_root="unknown"
  local swap_count zram_active disk_used ntp_state auto_pending=0 optional_pending=0
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  support="$(os_support_level)"
  missing="$(basic_tools_missing)"
  swappiness_rec="$(recommend_swappiness)"

  title "$(m 'VPS Optimization Assessment' 'VPS Optimization Assessment')"
  kv "Tool" "$SCRIPT_NAME $TOOL_VERSION"
  kv "Host" "$(hostname 2>/dev/null || echo unknown)"
  kv "Support level" "$support"
  kv "Assessment mode" "read-only"

  section "$(m 'Automatic optimization' 'Automatic optimization')"
  status_info "$(m 'Safe, repeatable defaults with no application-specific assumptions.' 'Safe, repeatable defaults with no application-specific assumptions.')"
  if [ -n "$missing" ]; then
    status_warn "$(m "Essential tools missing: $missing" "Essential tools missing: $missing")"
    auto_pending=$((auto_pending + 1))
  else
    status_ok "$(m 'Essential administration tools are available.' 'Essential administration tools are available.')"
  fi

  if bbr_profile_current; then
    status_ok "$(m 'BBR with fq is active and persistent.' 'BBR with fq is active and persistent.')"
  elif bbr_available_readonly; then
    status_warn "$(m 'BBR is available but the managed BBR/fq profile is not fully active.' 'BBR is available but the managed BBR/fq profile is not fully active.')"
    auto_pending=$((auto_pending + 1))
  else
    status_info "$(m 'BBR availability is not confirmed read-only; automatic mode will probe safely and skip if unsupported.' 'BBR availability is not confirmed read-only; automatic mode will probe safely and skip if unsupported.')"
  fi

  if memory_profile_current "$swappiness_rec"; then
    status_ok "$(m "Managed memory profile is current: swappiness=$swappiness_rec, vfs_cache_pressure=50." "Managed memory profile is current: swappiness=$swappiness_rec, vfs_cache_pressure=50.")"
  else
    status_warn "$(m "Managed memory profile is pending: swappiness=$swappiness_rec, vfs_cache_pressure=50." "Managed memory profile is pending: swappiness=$swappiness_rec, vfs_cache_pressure=50.")"
    auto_pending=$((auto_pending + 1))
  fi

  if is_systemd; then
    if journald_profile_current; then
      status_ok "$(m 'Managed journald retention profile is current.' 'Managed journald retention profile is current.')"
    else
      status_warn "$(m 'Managed journald limits are pending: 200M persistent, 100M runtime, 7-day retention.' 'Managed journald limits are pending: 200M persistent, 100M runtime, 7-day retention.')"
      auto_pending=$((auto_pending + 1))
    fi
  else
    status_info "$(m 'journald optimization is unavailable without systemd and will be skipped.' 'journald optimization is unavailable without systemd and will be skipped.')"
  fi

  if [ "$support" != "full" ]; then
    status_warn "$(m 'Automatic changes are disabled on this OS; the assessment remains available.' 'Automatic changes are disabled on this OS; the assessment remains available.')"
  fi

  section "$(m 'Optional optimization' 'Optional optimization')"
  status_info "$(m 'These items require an access, workload, provider, or maintenance decision.' 'These items require an access, workload, provider, or maintenance decision.')"

  if has_cmd sshd; then
    effective="$(sshd -T 2>/dev/null || true)"
    if [ -n "$effective" ]; then
      ssh_ports="$(awk '/^port / {print $2}' <<< "$effective" | sort -nu | paste -sd' ' -)"
      ssh_pass="$(awk '/^passwordauthentication / {print $2; exit}' <<< "$effective")"
      ssh_root="$(awk '/^permitrootlogin / {print $2; exit}' <<< "$effective")"
      if grep -qw 22 <<< "$ssh_ports"; then
        status_warn "$(m "SSH still includes port 22; review key login and hardening before enabling UFW. PasswordAuthentication=$ssh_pass, PermitRootLogin=$ssh_root." "SSH still includes port 22; review key login and hardening before enabling UFW. PasswordAuthentication=$ssh_pass, PermitRootLogin=$ssh_root.")"
        optional_pending=$((optional_pending + 1))
      elif [ "$ssh_pass" = "yes" ] || [ "$ssh_root" = "yes" ]; then
        status_warn "$(m "SSH uses port(s) ${ssh_ports:-unknown}, but authentication policy needs review. PasswordAuthentication=$ssh_pass, PermitRootLogin=$ssh_root." "SSH uses port(s) ${ssh_ports:-unknown}, but authentication policy needs review. PasswordAuthentication=$ssh_pass, PermitRootLogin=$ssh_root.")"
        optional_pending=$((optional_pending + 1))
      else
        status_ok "$(m "SSH uses port(s) ${ssh_ports:-unknown}; no obvious password/root-login warning was found." "SSH uses port(s) ${ssh_ports:-unknown}; no obvious password/root-login warning was found.")"
      fi
    else
      status_info "$(m 'sshd is installed, but effective settings require a privileged SSH audit.' 'sshd is installed, but effective settings require a privileged SSH audit.')"
      optional_pending=$((optional_pending + 1))
    fi
  else
    status_warn "$(m 'OpenSSH server was not detected; confirm how remote administration is provided.' 'OpenSSH server was not detected; confirm how remote administration is provided.')"
    optional_pending=$((optional_pending + 1))
  fi

  if has_cmd ufw; then
    if [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; then
      if ufw status 2>/dev/null | grep -q '^Status: active'; then
        status_ok "$(m 'UFW is active; review allowed services and source restrictions.' 'UFW is active; review allowed services and source restrictions.')"
      else
        status_warn "$(m 'UFW is installed but inactive. Configure SSH first, then use safe initialization.' 'UFW is installed but inactive. Configure SSH first, then use safe initialization.')"
        optional_pending=$((optional_pending + 1))
      fi
    else
      status_info "$(m 'UFW is installed; run this assessment with sudo to inspect activation state.' 'UFW is installed; run this assessment with sudo to inspect activation state.')"
    fi
  else
    status_warn "$(m 'UFW is not installed. Add it only after confirming the effective SSH port and access path.' 'UFW is not installed. Add it only after confirming the effective SSH port and access path.')"
    optional_pending=$((optional_pending + 1))
  fi

  if is_systemd && has_cmd fail2ban-client && systemctl is-active --quiet fail2ban 2>/dev/null; then
    status_ok "$(m 'Fail2ban is active; verify that the sshd jail follows the effective SSH port.' 'Fail2ban is active; verify that the sshd jail follows the effective SSH port.')"
  else
    status_warn "$(m 'Fail2ban is not confirmed active. It is useful when SSH remains internet-facing.' 'Fail2ban is not confirmed active. It is useful when SSH remains internet-facing.')"
    optional_pending=$((optional_pending + 1))
  fi

  if security_updates_fully_enabled; then
    status_ok "$(m 'Automatic distro security updates are enabled without automatic reboot.' 'Automatic distro security updates are enabled without automatic reboot.')"
  else
    status_warn "$(m 'Automatic security updates are not fully enabled; choose a maintenance policy before enabling them.' 'Automatic security updates are not fully enabled; choose a maintenance policy before enabling them.')"
    optional_pending=$((optional_pending + 1))
  fi

  swap_count="$({ swapon --show --noheadings 2>/dev/null || true; } | wc -l | awk '{print $1}')"
  zram_active="$(swapon --show --noheadings 2>/dev/null | awk '$1 ~ /zram/ {print $1}' | paste -sd, - || true)"
  if [ "${swap_count:-0}" -eq 0 ]; then
    status_warn "$(m "No swap is active. Review workload and disk endurance; suggested swapfile ceiling: $(recommend_swap_size), ZRAM: $(recommend_zram_size)." "No swap is active. Review workload and disk endurance; suggested swapfile ceiling: $(recommend_swap_size), ZRAM: $(recommend_zram_size).")"
    optional_pending=$((optional_pending + 1))
  else
    status_ok "$(m "Swap is active; ZRAM devices: ${zram_active:-none}." "Swap is active; ZRAM devices: ${zram_active:-none}.")"
  fi

  status_info "$(m 'DNS changes, Cloudflare-only web rules, global nofile limits, and proxy sysctl tuning stay optional and workload-specific.' 'DNS changes, Cloudflare-only web rules, global nofile limits, and proxy sysctl tuning stay optional and workload-specific.')"

  section "$(m 'Reference optimization' 'Reference optimization')"
  status_info "$(m 'Observe these items and act only with provider or workload context.' 'Observe these items and act only with provider or workload context.')"
  disk_used="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
  if [[ "$disk_used" =~ ^[0-9]+$ ]] && [ "$disk_used" -ge 85 ]; then
    status_warn "$(m "Root filesystem usage is ${disk_used}%; investigate before package upgrades or swap allocation." "Root filesystem usage is ${disk_used}%; investigate before package upgrades or swap allocation.")"
  else
    status_ok "$(m "Root filesystem usage: ${disk_used:-unknown}%." "Root filesystem usage: ${disk_used:-unknown}%.")"
  fi

  ntp_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  case "$ntp_state" in
    yes) status_ok "$(m 'System clock reports NTP synchronized.' 'System clock reports NTP synchronized.')" ;;
    no) status_warn "$(m 'System clock is not yet NTP synchronized; check the provider and time service.' 'System clock is not yet NTP synchronized; check the provider and time service.')" ;;
    *) status_info "$(m 'NTP synchronization state is unavailable.' 'NTP synchronization state is unavailable.')" ;;
  esac
  if [ -e /var/run/reboot-required ]; then
    status_warn "$(m 'A reboot is required to finish installed updates; schedule it after service checks.' 'A reboot is required to finish installed updates; schedule it after service checks.')"
  else
    status_ok "$(m 'No distro reboot-required marker is present.' 'No distro reboot-required marker is present.')"
  fi
  status_info "$(m 'Prefer per-service LimitNOFILE overrides, measured network tuning, provider snapshots, off-host backups, and external monitoring.' 'Prefer per-service LimitNOFILE overrides, measured network tuning, provider snapshots, off-host backups, and external monitoring.')"
  status_info "$(m 'Cloud-init or the provider may own networking, DNS, hostname, and boot settings; verify ownership before editing them.' 'Cloud-init or the provider may own networking, DNS, hostname, and boot settings; verify ownership before editing them.')"

  section "$(m 'Assessment summary' 'Assessment summary')"
  kv "Automatic pending groups" "$auto_pending"
  kv "Optional review groups" "$optional_pending"
  if [ "$support" = "full" ]; then
    status_info "$(m 'Apply only the automatic tier: sudo bash vps_init_tool.sh --optimize-auto --yes' 'Apply only the automatic tier: sudo bash vps_init_tool.sh --optimize-auto --yes')"
    status_info "$(m 'Use the guided workflow: sudo bash vps_init_tool.sh, then choose Optimization assessment / guided setup.' 'Use the guided workflow: sudo bash vps_init_tool.sh, then choose Optimization assessment / guided setup.')"
  else
    status_warn "$(m 'This OS is assessment-only. Do not run automatic changes with this script.' 'This OS is assessment-only. Do not run automatic changes with this script.')"
  fi
  status_info "$(m 'Assessment completed without changing the system.' 'Assessment completed without changing the system.')"
}

apply_safe_automatic_optimizations() {
  local failures=0 missing swappiness_rec
  missing="$(basic_tools_missing)"
  swappiness_rec="$(recommend_swappiness)"
  if [ -n "$missing" ]; then
    if ! install_essential_tools; then failures=$((failures + 1)); fi
  else
    status_ok "$(m 'Essential administration tools already present; skipped package installation.' 'Essential administration tools already present; skipped package installation.')"
  fi
  if bbr_profile_current; then
    status_ok "$(m 'BBR/fq profile already current; skipped.' 'BBR/fq profile already current; skipped.')"
  elif bbr_supported; then
    if ! enable_bbr; then failures=$((failures + 1)); fi
  else
    status_info "$(m 'BBR is unsupported or unavailable; skipped without failure.' 'BBR is unsupported or unavailable; skipped without failure.')"
  fi
  if memory_profile_current "$swappiness_rec"; then
    status_ok "$(m 'Memory profile already current; skipped.' 'Memory profile already current; skipped.')"
  elif ! apply_memory_sysctl "$swappiness_rec" "50"; then
    failures=$((failures + 1))
  fi
  if is_systemd; then
    if journald_profile_current; then
      status_ok "$(m 'journald profile already current; skipped.' 'journald profile already current; skipped.')"
    elif ! logs_limit_journald "200M" "100M" "7day"; then
      failures=$((failures + 1))
    fi
  else
    status_info "$(m 'systemd is unavailable; journald profile skipped without failure.' 'systemd is unavailable; journald profile skipped without failure.')"
  fi
  [ "$failures" -eq 0 ] || return "$failures"
}

automatic_optimize() {
  local mode="${1:-interactive}" failures=0
  optimization_assessment
  section "$(m 'Automatic optimization scope' 'Automatic optimization scope')"
  yellow "$(m 'This applies only essential tools, supported BBR/fq, conservative VM memory values, and bounded journald retention.' 'This applies only essential tools, supported BBR/fq, conservative VM memory values, and bounded journald retention.')"
  yellow "$(m 'It does NOT change SSH, UFW, Fail2ban, DNS, security-update policy, swap/ZRAM, global nofile limits, or advanced proxy sysctl values.' 'It does NOT change SSH, UFW, Fail2ban, DNS, security-update policy, swap/ZRAM, global nofile limits, or advanced proxy sysctl values.')"
  if ! confirm_yes "$(m 'Apply the safe automatic optimization tier?' 'Apply the safe automatic optimization tier?')"; then
    [ "$mode" = "cli" ] && return 2
    return 0
  fi
  log_action "optimize-auto" "start mode=$mode"
  if apply_safe_automatic_optimizations; then
    failures=0
  else
    failures=$?
    log_action "optimize-auto" "partial-failure mode=$mode failures=$failures"
    red "$(m "Automatic optimization completed with $failures failed step(s)." "Automatic optimization completed with $failures failed step(s).")"
    return 1
  fi
  log_action "optimize-auto" "complete mode=$mode"
  green "$(m 'Safe automatic optimization completed.' 'Safe automatic optimization completed.')"
  optimization_assessment
}

guided_optimization() {
  automatic_optimize "guided" || true
  while true; do
    title "$(m 'Optional Optimization' 'Optional Optimization')"
    status_info "$(m 'Recommended order: secure SSH access first, then firewall and Fail2ban.' 'Recommended order: secure SSH access first, then firewall and Fail2ban.')"
    echo "1) $(m 'SSH audit / key setup / hardening' 'SSH audit / key setup / hardening')"
    echo "2) $(m 'UFW safe initialization / Cloudflare rules' 'UFW safe initialization / Cloudflare rules')"
    echo "3) Fail2ban"
    echo "4) $(m 'Automatic security updates' 'Automatic security updates')"
    echo "5) $(m 'Swap / ZRAM workload choices' 'Swap / ZRAM workload choices')"
    echo "6) $(m 'DNS audit and testing' 'DNS audit and testing')"
    echo "7) $(m 'Advanced measured tuning' 'Advanced measured tuning')"
    echo "8) $(m 'Run optimization assessment again' 'Run optimization assessment again')"
    echo "0) $(m 'Back' 'Back')"
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) ssh_menu ;;
      2) ufw_menu ;;
      3) fail2ban_menu ;;
      4) security_updates_menu ;;
      5) memory_optimize_menu ;;
      6) dns_menu ;;
      7)
        apply_proxy_sysctl
        raise_nofile_limits
        pause
        ;;
      8) optimization_assessment; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

audit_all() {
  clear_screen
  title "$(m 'Full Environment Audit' 'Full Environment Audit')"
  load_os_release
  kv "Time" "$(date '+%F %T %Z')"
  kv "Host" "$(hostname)"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Kernel" "$(uname -r)"
  kv "Arch" "$(uname -m)"
  kv "Language" "$LANG_MODE"

  memory_report
  ssh_audit || true
  ufw_audit || true
  fail2ban_audit || true
  dns_audit || true
  logs_audit || true
  security_updates_audit || true

  section "$(m 'Summary' 'Summary')"
  status_info "$(m 'Audit mode is read-only. No settings were changed.' 'Audit mode is read-only. No settings were changed.')"
  status_info "$(m 'Use the individual module menus to apply changes with confirmation.' 'Use the individual module menus to apply changes with confirmation.')"
}

low_risk_baseline() {
  local mode="${1:-interactive}" failures=0
  yellow "$(m 'Compatibility baseline includes: essential administration tools, BBR if supported, conservative VM memory settings, and a journald limit.' 'Compatibility baseline includes: essential administration tools, BBR if supported, conservative VM memory settings, and a journald limit.')"
  yellow "$(m 'It does NOT change SSH, UFW, DNS, Fail2ban, automatic security updates, global proxy sysctl/nofile tuning, swapfile, or ZRAM.' 'It does NOT change SSH, UFW, DNS, Fail2ban, automatic security updates, global proxy sysctl/nofile tuning, swapfile, or ZRAM.')"
  log_action "baseline" "start mode=$mode"
  confirm_yes "$(m 'Run low-risk baseline?' 'Run low-risk baseline?')" || return 0
  if apply_safe_automatic_optimizations; then failures=0; else failures=$?; fi
  if [ "$failures" -gt 0 ]; then
    log_action "baseline" "partial-failure mode=$mode failures=$failures"
    red "$(m "Baseline completed with $failures failed step(s). Review the output before rebooting." "Baseline completed with $failures failed step(s). Review the output before rebooting.")"
    return 1
  fi
  log_action "baseline" "complete mode=$mode"
  green "$(m 'Baseline complete. Reboot is recommended.' 'Baseline complete. Reboot is recommended.')"
}

list_backups() {
  make_backup_dir
  find "$BACKUP_ROOT" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
}

language_menu() {
  echo "1) English"
  echo "2) Chinese alias (English-safe fallback)"
  read -r -p "Choose [1/2]: " ans || true
  case "$ans" in
    2|cn|CN|zh|chinese|Chinese) LANG_MODE="en" ;;
    *) LANG_MODE="en" ;;
  esac
  green "$(m 'Language switched to English.' 'Language switched to English.')"
}

show_help() {
  cat <<EOF2
$SCRIPT_NAME $TOOL_VERSION

Usage:
  bash vps_init_tool.sh [options] [command]

Commands:
  --doctor          Show read-only summary diagnostics and recommended commands.
  --compat          Show read-only OS/module compatibility report; does not require root.
  --preflight        Run read-only checks; does not require root.
  --optimize-check   Assess a new VPS and classify automatic, optional, and reference optimizations; read-only.
  --optimize-auto    Apply only the safe automatic tier; use --yes for unattended execution.
  --audit            Run full read-only environment audit.
  --status           Show system status.
  --memory-audit     Show memory/swap/ZRAM audit.
  --ssh-audit        Show SSH hardening audit.
  --baseline         Compatibility alias for the safe automatic tier, without the assessment report.
  --ufw-audit        Show UFW/firewall audit.
  --fail2ban-audit   Show Fail2ban audit.
  --dns-audit        Show DNS audit.
  --logs-audit       Show log/journald audit.
  --updates-audit    Show effective automatic security updates policy; does not require root.
  --updates-enable   Enable daily distro security updates without automatic reboot.
  --updates-disable  Disable periodic automatic updates through the tool-managed policy.
  --list-backups     List configuration backups created by this tool.
  --ufw-cf-sync      Incrementally sync Cloudflare allow rules for web ports.
  --version          Print version.
  --help             Show this help.

Options:
  --yes, -y          Auto-confirm prompts for non-interactive commands.
  --lang en|cn       Set output language; cn currently uses English-safe output.
  --ports LIST       Cloudflare ports for --ufw-cf-sync, default: 80,443; comma-separated single ports only, no ranges.

Environment:
  VPS_INIT_YES=1
  VPS_INIT_LANG=en|cn    # cn currently uses English-safe output
  VPS_INIT_CF_PORTS=80,443
  VPS_INIT_CF_IPV4_FILE=/var/lib/vps-init/cloudflare-ips-v4.txt
  VPS_INIT_CF_IPV6_FILE=/var/lib/vps-init/cloudflare-ips-v6.txt
  VPS_INIT_LOG=/var/log/vps-init-tool.log
  VPS_INIT_APT_LOCK_TIMEOUT=120
  VPS_INIT_APT_RETRIES=3
  VPS_INIT_CF_LOCK_TIMEOUT=120
EOF2
}

handle_cli() {
  [ "$#" -eq 0 ] && return 1

  local cmd="" original_args="$*" rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        show_help
        exit 0
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$TOOL_VERSION"
        exit 0
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      --lang)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then red "Missing value for --lang."; show_help; exit 2; fi
        shift
        case "$1" in
          en|cn) LANG_MODE="$1" ;;
          *) red "Invalid --lang value: $1. Use en or cn."; show_help; exit 2 ;;
        esac
        ;;
      --ports)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then red "Missing value for --ports."; show_help; exit 2; fi
        shift
        UFW_CF_PORTS="$1"
        ufw_parse_cloudflare_ports "$UFW_CF_PORTS" || { red "Invalid --ports value: $UFW_CF_PORTS"; show_help; exit 2; }
        ;;
      --doctor|--compat|--preflight|--optimize-check|--optimize-auto|--audit|--status|--memory-audit|--ssh-audit|--baseline|--ufw-audit|--fail2ban-audit|--dns-audit|--logs-audit|--updates-audit|--updates-enable|--updates-disable|--list-backups|--ufw-cf-sync)
        [ -z "$cmd" ] || { red "Only one command may be specified."; show_help; exit 2; }
        cmd="$1"
        ;;
      *)
        red "$(m "Unknown argument: $1" "Unknown argument: $1")"
        show_help
        exit 2
        ;;
    esac
    shift
  done

  [ -n "$cmd" ] || { show_help; exit 2; }
  NONINTERACTIVE=1
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  case "$cmd" in
    --doctor) doctor_report; exit 0 ;;
    --compat) compatibility_report; exit 0 ;;
    --preflight) preflight_check; exit 0 ;;
    --optimize-check) optimization_assessment; exit 0 ;;
    --updates-audit) security_updates_audit; exit 0 ;;
  esac
  need_root
  require_debian_family
  log_action "cli" "command=$cmd args=$original_args"

  set +e
  (
    set -e
    case "$cmd" in
      --audit) audit_all ;;
      --status) show_system_status ;;
      --memory-audit) memory_report ;;
      --ssh-audit) ssh_audit ;;
      --optimize-auto) automatic_optimize "cli" ;;
      --baseline) ASSUME_YES=1; low_risk_baseline "cli" ;;
      --ufw-audit) ufw_audit ;;
      --fail2ban-audit) fail2ban_audit ;;
      --dns-audit) dns_audit ;;
      --logs-audit) logs_audit ;;
      --updates-enable) security_updates_enable ;;
      --updates-disable) security_updates_disable ;;
      --list-backups) list_backups ;;
      --ufw-cf-sync) ufw_sync_cloudflare_web ;;
    esac
  )
  rc=$?
  set -e
  log_action "cli" "command=$cmd complete rc=$rc"
  exit "$rc"
}

main_menu() {
  while true; do
    clear_screen
    title "$SCRIPT_NAME $TOOL_VERSION"
    section "$(m 'Start here' 'Start here')"
    echo "1) $(m 'Optimization assessment / guided setup' 'Optimization assessment / guided setup')"
    echo "2) $(m 'Full environment audit' 'Full environment audit')"
    echo "3) $(m 'System status' 'System status')"
    section "$(m 'Optional modules' 'Optional modules')"
    echo "4) SSH"
    echo "5) $(m 'UFW Firewall / Cloudflare ranges' 'UFW Firewall / Cloudflare ranges')"
    echo "6) Fail2ban"
    echo "7) $(m 'Automatic security updates' 'Automatic security updates')"
    echo "8) $(m 'Memory / Swap / ZRAM' 'Memory / Swap / ZRAM')"
    echo "9) DNS"
    echo "10) $(m 'Logs / journald' 'Logs / journald')"
    section "$(m 'Advanced / maintenance' 'Advanced / maintenance')"
    echo "11) $(m 'Enable BBR' 'Enable BBR')"
    echo "12) $(m 'Proxy sysctl tuning' 'Proxy sysctl tuning')"
    echo "13) $(m 'Raise nofile limits' 'Raise nofile limits')"
    echo "14) $(m 'Install extended tool set' 'Install extended tool set')"
    echo "15) $(m 'Apply safe automatic tier directly' 'Apply safe automatic tier directly')"
    echo "16) $(m 'List config backups' 'List config backups')"
    echo "17) $(m 'Switch language' 'Switch language')"
    echo "0) $(m 'Exit' 'Exit')"
    echo
    read -r -p "$(m 'Choose: ' 'Choose: ')" c
    case "$c" in
      1) guided_optimization ;;
      2) audit_all; pause ;;
      3) show_system_status; pause ;;
      4) ssh_menu ;;
      5) ufw_menu ;;
      6) fail2ban_menu ;;
      7) security_updates_menu ;;
      8) memory_optimize_menu ;;
      9) dns_menu ;;
      10) logs_menu ;;
      11) enable_bbr; pause ;;
      12) apply_proxy_sysctl; pause ;;
      13) raise_nofile_limits; pause ;;
      14) install_basic_tools; pause ;;
      15) automatic_optimize "interactive"; pause ;;
      16) list_backups; pause ;;
      17) language_menu; pause ;;
      0) exit 0 ;;
      *) yellow "$(m 'Invalid choice' 'Invalid choice')"; pause ;;
    esac
  done
}

handle_cli "$@"
need_root
choose_language
require_debian_family
main_menu
