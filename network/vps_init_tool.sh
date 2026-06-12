#!/usr/bin/env bash
set -Eeuo pipefail

# VPS Init Tool v1.0.4
# Debian/Ubuntu VPS bootstrap, audit and maintenance helper.
# Scope: memory, SSH, UFW firewall, Fail2ban, DNS, logs, basic network tuning.
# Principle: audit first, confirm before risky changes.

TOOL_VERSION="1.0.4"
SCRIPT_NAME="VPS Init Tool"
BACKUP_ROOT="/root/vps-init-backups"
SWAPFILE="/swapfile"
CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
UFW_CF_STATE_FILE="/var/lib/vps-init/cloudflare-ufw-managed.tsv"
UFW_CF_LOCK_FILE="/var/lib/vps-init/cloudflare-ufw.lock"
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
    zh|zh-cn|zh_CN|cn|CN|中文) echo "cn" ;;
    en|EN|english|English) echo "en" ;;
    *) echo "en" ;;
  esac
}

m() {
  # m "English" "中文"
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
  read -r -p "$(m 'Press Enter to continue...' '按 Enter 继续...')" _ || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_systemd() { has_cmd systemctl && [ -d /run/systemd/system ]; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    red "$(m "Please run as root: sudo bash $0" "请使用 root 执行：sudo bash $0")"
    exit 1
  fi
}

choose_language() {
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  if [ -t 0 ] && [ -z "${VPS_INIT_LANG:-}" ]; then
    echo "Language / 语言:"
    echo "1) English"
    echo "2) 中文"
    read -r -p "Choose [1/2, default 1]: " ans || true
    case "$ans" in
      2|cn|CN|zh|中文) LANG_MODE="cn" ;;
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

require_debian_family() {
  load_os_release
  case "${ID:-}" in
    debian|ubuntu) return 0 ;;
    *)
      red "$(m "This script is intended for Debian/Ubuntu family systems. Detected: ${PRETTY_NAME:-unknown}" "此脚本面向 Debian/Ubuntu 系系统。检测到：${PRETTY_NAME:-unknown}")"
      exit 1
      ;;
  esac
}

confirm_yes() {
  local prompt="$1" ans
  case "${ASSUME_YES:-0}" in
    1|yes|YES|true|TRUE)
      status_info "$(m "Auto-confirmed: $prompt" "已自动确认：$prompt")"
      return 0
      ;;
  esac
  echo
  yellow "$prompt"
  if [ "${NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    status_warn "$(m 'Confirmation required; use --yes or VPS_INIT_YES=1 for non-interactive execution.' '需要确认；非交互执行请使用 --yes 或 VPS_INIT_YES=1。')"
    return 1
  fi
  read -r -p "$(m 'Type YES to continue: ' '输入 YES 继续：')" ans || true
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
    yellow "$(m "apt-get $* failed with rc=$rc; retrying in ${delay}s..." "apt-get $* 失败，rc=$rc；${delay}s 后重试...")"
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
  valid_uint_range "$swappiness" 0 200 || { red "$(m 'Invalid vm.swappiness. Use 0-200.' 'vm.swappiness 无效，请使用 0-200。')"; return 1; }
  valid_uint_range "$vfs_cache_pressure" 0 1000 || { red "$(m 'Invalid vm.vfs_cache_pressure. Use 0-1000.' 'vm.vfs_cache_pressure 无效，请使用 0-1000。')"; return 1; }
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<EOF2 || return 1
vm.swappiness=$swappiness
vm.vfs_cache_pressure=$vfs_cache_pressure
EOF2
  if ! sysctl -p /etc/sysctl.d/99-memory-tuning.conf >/dev/null; then
    red "$(m 'Failed to apply memory sysctl settings. Restoring the previous configuration.' '应用内存 sysctl 设置失败，正在恢复之前的配置。')"
    restore_managed_file "$config_file" "$config_backup"
    if [ -e "$config_file" ]; then sysctl -p "$config_file" >/dev/null 2>&1 || true; fi
    return 1
  fi
}

# ---------- system / audit ----------
install_basic_tools() {
  blue "$(m 'Installing basic tools...' '正在安装基础工具...')"
  apt_install \
    curl wget ca-certificates gnupg lsb-release apt-transport-https \
    vim nano less unzip zip tar gzip xz-utils zstd \
    jq sqlite3 cron socat lsof \
    dnsutils iproute2 net-tools \
    htop iotop sysstat \
    openssl rsync screen tmux || return 1

  if is_systemd; then
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl enable sysstat >/dev/null 2>&1 || true
  fi
  green "$(m 'Basic tools installed.' '基础工具安装完成。')"
}

show_system_status() {
  load_os_release
  title "$(m 'System Status' '系统状态')"
  kv "Tool" "$SCRIPT_NAME $TOOL_VERSION"
  kv "Language" "$LANG_MODE"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Kernel" "$(uname -r)"
  kv "Arch" "$(uname -m)"
  kv "Hostname" "$(hostname)"
  kv "Systemd" "$(is_systemd && echo yes || echo no)"

  section "$(m 'Memory / Swap' '内存 / Swap')"
  free -h | print_block || true
  echo
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true

  section "$(m 'Disk' '磁盘')"
  df -hT / | print_block || true

  section "$(m 'Network / BBR' '网络 / BBR')"
  kv "tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  kv "default_qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  kv "available algorithms" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"

  section "$(m 'Listening ports' '监听端口')"
  listening_ports_compact | print_block || true
}

preflight_check() {
  LANG_MODE="$(normalize_lang "$LANG_MODE")"
  load_os_release

  title "$(m 'VPS init preflight' 'VPS 初始化预检')"
  kv "Time" "$(date '+%F %T %Z' 2>/dev/null || echo unknown)"
  kv "User" "$(id -un 2>/dev/null || echo unknown)"
  kv "Root" "$([ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] && echo yes || echo no)"
  kv "OS" "${PRETTY_NAME:-unknown}"
  kv "Kernel" "$(uname -r 2>/dev/null || echo unknown)"
  kv "Arch" "$(uname -m 2>/dev/null || echo unknown)"
  kv "Memory" "$(get_mem_mb 2>/dev/null || echo unknown) MB"
  kv "Root disk available" "$(get_root_avail_mb 2>/dev/null || echo unknown) MB"

  echo
  case "${ID:-}" in
    debian|ubuntu) status_ok "$(m 'Debian/Ubuntu family detected.' '检测到 Debian/Ubuntu 系统。')" ;;
    *) status_bad "$(m "Unsupported OS for this script: ${PRETTY_NAME:-unknown}" "此脚本不支持当前系统：${PRETTY_NAME:-unknown}")" ;;
  esac

  if has_cmd apt-get; then status_ok "apt-get"; else status_bad "$(m 'apt-get not found.' '未找到 apt-get。')"; fi
  if has_cmd systemctl && [ -d /run/systemd/system ]; then status_ok "systemd"; else status_warn "$(m 'systemd is not fully available; service operations may fail.' 'systemd 不完整可用，服务操作可能失败。')"; fi
  if has_cmd sudo; then status_ok "sudo"; else status_info "$(m 'sudo not found; run as root when applying changes.' '未找到 sudo；应用修改时请使用 root。')"; fi
  if has_cmd curl; then status_ok "curl"; else status_warn "$(m 'curl missing; baseline can install it.' '缺少 curl；baseline 可安装。')"; fi
  if [ -d /etc/ssl/certs ]; then status_ok "ca-certificates"; else status_warn "$(m 'Certificate store not found; ensure HTTPS downloads work.' '未找到证书目录；请确认 HTTPS 下载可用。')"; fi

  if has_cmd sshd; then
    status_ok "$(m "sshd detected; effective port(s): $(current_ssh_ports)" "检测到 sshd；有效端口：$(current_ssh_ports)")"
  else
    status_warn "$(m 'sshd not found; SSH hardening/audit will be unavailable.' '未找到 sshd；SSH 加固/审计不可用。')"
  fi

  if has_cmd ufw; then status_info "$(m 'UFW is installed.' 'UFW 已安装。')"; else status_info "$(m 'UFW is not installed; firewall module can install it.' 'UFW 未安装；防火墙模块可安装。')"; fi
  if has_cmd fail2ban-client; then status_info "$(m 'Fail2ban is installed.' 'Fail2ban 已安装。')"; else status_info "$(m 'Fail2ban is not installed; fail2ban module can install it.' 'Fail2ban 未安装；Fail2ban 模块可安装。')"; fi

  echo
  status_info "$(m 'Preflight is read-only. No settings were changed.' '预检是只读的，没有修改任何设置。')"
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    status_info "$(m 'Run with sudo/root for --audit, --baseline, SSH, UFW, DNS, and service changes.' '执行 --audit、--baseline、SSH、UFW、DNS 和服务修改时请使用 sudo/root。')"
  fi
}

memory_report() {
  local mem_mb swap_rec zram_rec swappiness_rec swap_lines zram_active
  mem_mb="$(get_mem_mb)"
  swap_rec="$(recommend_swap_size)"
  zram_rec="$(recommend_zram_size)"
  swappiness_rec="$(recommend_swappiness)"
  swap_lines="$({ swapon --show --noheadings 2>/dev/null || true; } | wc -l | awk '{print $1}')"
  zram_active="$(swapon --show --noheadings 2>/dev/null | awk '$1 ~ /zram/ {print $1}' | paste -sd, - || true)"

  section "$(m 'Memory audit' '内存审计')"
  kv "RAM" "${mem_mb} MB"
  kv "Current swappiness" "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
  kv "Current vfs_cache_pressure" "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo unknown)"
  kv "Active swap devices" "${swap_lines:-0}"
  kv "Active ZRAM" "${zram_active:-none}"

  echo
  status_info "$(m "Recommended swapfile: $swap_rec" "建议 swapfile：$swap_rec")"
  status_info "$(m "Recommended ZRAM: $zram_rec" "建议 ZRAM：$zram_rec")"
  status_info "$(m "Recommended swappiness: $swappiness_rec; vfs_cache_pressure: 50" "建议 swappiness：$swappiness_rec；vfs_cache_pressure：50")"

  echo
  muted "  $(m 'Current free -h:' '当前 free -h：')"
  free -h | print_block || true
  echo
  muted "  $(m 'Current swapon:' '当前 swapon：')"
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true

  echo
  if [ "$mem_mb" -le 2048 ]; then
    status_warn "$(m 'Small VPS profile: ZRAM + swapfile is recommended.' '小内存 VPS：建议 ZRAM + swapfile 组合。')"
  elif [ "$mem_mb" -le 8192 ]; then
    status_info "$(m 'Medium VPS profile: swapfile recommended; ZRAM optional.' '中等内存 VPS：建议保留 swapfile，ZRAM 可选。')"
  else
    status_info "$(m 'Large VPS profile: usually swapfile only; ZRAM optional.' '大内存服务器：通常保留 swapfile 兜底即可，ZRAM 可选。')"
  fi
}

# ---------- memory ----------
setup_swapfile() {
  local size swappiness vfs_cache_pressure mb
  size="$(input_default "$(m 'Swapfile size; use 0 to skip' 'Swapfile 大小；输入 0 跳过')" "$(recommend_swap_size)")"
  case "$size" in 0|0M|0m|0G|0g) yellow "$(m 'Swapfile skipped.' '已跳过 swapfile。')"; return 0 ;; esac
  valid_size_mb_gb "$size" || { red "$(m 'Invalid swapfile size. Use a positive value such as 512M, 2G, or 2048.' 'Swapfile 大小无效。请使用 512M、2G 或 2048 等正数格式。')"; return 1; }
  mb="$(parse_size_to_mb "$size")" || { red "$(m 'Unable to parse swapfile size.' '无法解析 Swapfile 大小。')"; return 1; }
  swappiness="$(input_default "vm.swappiness" "$(recommend_swappiness)")"
  vfs_cache_pressure="$(input_default "vm.vfs_cache_pressure" "50")"
  valid_uint_range "$swappiness" 0 200 || { red "$(m 'Invalid vm.swappiness. Use 0-200.' 'vm.swappiness 无效，请使用 0-200。')"; return 1; }
  valid_uint_range "$vfs_cache_pressure" 0 1000 || { red "$(m 'Invalid vm.vfs_cache_pressure. Use 0-1000.' 'vm.vfs_cache_pressure 无效，请使用 0-1000。')"; return 1; }

  blue "$(m "Configuring $SWAPFILE size=$size" "正在配置 $SWAPFILE，大小=$size")"
  if swapon --show | awk '{print $1}' | grep -qx "$SWAPFILE"; then
    yellow "$(m "$SWAPFILE is currently active. To recreate it, it must be swapoff first." "$SWAPFILE 当前已启用。若要重建，需要先 swapoff。")"
    confirm_yes "$(m "Recreate active $SWAPFILE?" "是否重建正在使用的 $SWAPFILE？")" || return 0
    swapoff "$SWAPFILE" || { red "$(m 'swapoff failed. Memory may be too tight. Aborting.' 'swapoff 失败，可能当前内存太紧。已中止。')"; return 1; }
  elif [ -e "$SWAPFILE" ]; then
    confirm_yes "$(m "$SWAPFILE exists and will be reformatted. Continue?" "$SWAPFILE 已存在并将被重新格式化。继续？")" || return 0
  fi

  rm -f "$SWAPFILE"
  if has_cmd fallocate; then fallocate -l "$size" "$SWAPFILE" || true; fi
  if [ ! -s "$SWAPFILE" ]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=progress
  fi

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon -p 10 "$SWAPFILE"

  backup_path /etc/fstab >/dev/null
  grep -qE "^[^#]*[[:space:]]${SWAPFILE}[[:space:]]" /etc/fstab || echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
  apply_memory_sysctl "$swappiness" "$vfs_cache_pressure"

  green "$(m 'Swapfile configured.' 'swapfile 配置完成。')"
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
  local size_expr algo
  size_expr="$(input_default "$(m 'ZRAM size/expression, e.g. 512M / 2G / ram / 2 / min(ram / 2, 1024M)' 'ZRAM 大小/表达式，例如 512M / 2G / ram / 2 / min(ram / 2, 1024M)')" "$(recommend_zram_size)")"
  algo="$(input_default "$(m 'Compression algorithm' '压缩算法')" "zstd")"
  apt_install systemd-zram-generator
  mkdir -p /etc/systemd
  backup_path /etc/systemd/zram-generator.conf >/dev/null
  cat > /etc/systemd/zram-generator.conf <<EOF2
[zram0]
zram-size = $size_expr
compression-algorithm = $algo
  swap-priority = 100
EOF2
  systemctl daemon-reload
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl start systemd-zram-setup@zram0.service
}

setup_zram_tools() {
  local size_hint_mb="$1"
  apt_install zram-tools
  backup_path /etc/default/zramswap >/dev/null
  if [ -f /etc/default/zramswap ]; then
    sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null || true
    if [[ "$size_hint_mb" =~ ^[0-9]+[Mm]?$ ]]; then
      size_hint_mb="${size_hint_mb%M}"; size_hint_mb="${size_hint_mb%m}"
      grep -q '^SIZE=' /etc/default/zramswap 2>/dev/null && sed -i "s/^#\?SIZE=.*/SIZE=${size_hint_mb}/" /etc/default/zramswap || echo "SIZE=${size_hint_mb}" >> /etc/default/zramswap
    else
      sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null || true
    fi
    grep -q '^PRIORITY=' /etc/default/zramswap 2>/dev/null && sed -i 's/^#\?PRIORITY=.*/PRIORITY=100/' /etc/default/zramswap || echo 'PRIORITY=100' >> /etc/default/zramswap
  fi
  systemctl restart zramswap.service 2>/dev/null || systemctl restart zram-config.service
}

setup_zram_fallback() {
  local size mb
  size="$(input_default "$(m 'ZRAM fallback size' 'ZRAM fallback 大小')" "$(recommend_zram_size)")"
  valid_size_mb_gb "$size" || { red "$(m 'Invalid ZRAM fallback size. Use a positive value such as 512M or 2G.' 'ZRAM fallback 大小无效。请使用 512M 或 2G 等正数格式。')"; return 1; }
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
  enable="$(input_yes_no "$(m 'Enable/configure ZRAM?' '启用/配置 ZRAM？')" "yes")" || return 1
  [ "$enable" = "yes" ] || { yellow "$(m 'ZRAM skipped.' '已跳过 ZRAM。')"; return 0; }
  is_systemd || { red "$(m 'systemd not detected. ZRAM auto-start setup skipped.' '未检测到 systemd，跳过 ZRAM 自启动配置。')"; return 1; }
  zram_supported || { red "$(m 'ZRAM not supported by this kernel/VPS layer.' '当前内核或 VPS 虚拟化层不支持 ZRAM。')"; return 1; }

  size_hint="$(recommend_zram_size)"
  apt_update_once
  if apt-cache show systemd-zram-generator >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_generator || { stop_known_zram_services; setup_zram_fallback; }
  elif apt-cache show zram-tools >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_tools "$size_hint" || { stop_known_zram_services; setup_zram_fallback; }
  else
    stop_known_zram_services
    setup_zram_fallback
  fi
  green "$(m 'ZRAM status:' 'ZRAM 状态：')"
  free -h
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show
}

memory_optimize_menu() {
  while true; do
    clear_screen
    title "$(m 'Memory / Swap / ZRAM' '内存 / Swap / ZRAM')"
    echo "1) $(m 'Memory audit report' '内存审计报告')"
    echo "2) $(m 'Configure/Reconfigure swapfile' '配置/重配 swapfile')"
    echo "3) $(m 'Configure/Reconfigure ZRAM' '配置/重配 ZRAM')"
    echo "4) $(m 'Apply VM sysctl only' '仅应用 VM sysctl')"
    echo "5) $(m 'Apply full recommended memory profile' '应用完整推荐内存配置')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) memory_report; pause ;;
      2) setup_swapfile; pause ;;
      3) setup_zram; pause ;;
      4)
        apply_memory_sysctl "$(input_default "vm.swappiness" "$(recommend_swappiness)")" "$(input_default "vm.vfs_cache_pressure" "50")"
        green "$(m 'VM memory sysctl applied.' 'VM 内存 sysctl 已应用。')"; pause ;;
      5)
        memory_report
        confirm_yes "$(m 'Apply recommended memory profile?' '应用推荐内存配置？')" || { pause; continue; }
        apply_memory_sysctl "$(recommend_swappiness)" "50"
        setup_swapfile
        setup_zram
        pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

# ---------- network tuning ----------
bbr_supported() {
  modprobe tcp_bbr 2>/dev/null || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

enable_bbr() {
  local config_file="/etc/sysctl.d/90-bbr.conf" config_backup=""
  blue "$(m 'Enabling BBR if supported...' '正在尝试启用 BBR...')"
  if ! bbr_supported; then
    red "$(m 'BBR is not supported or is blocked by the virtualization layer.' '当前内核不支持 BBR，或被 VPS 虚拟化层限制。')"
    return 1
  fi
  backup_path "$config_file" >/dev/null || return 1
  config_backup="$BACKUP_LAST_PATH"
  cat > "$config_file" <<'EOF2' || return 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  if ! sysctl -p /etc/sysctl.d/90-bbr.conf >/dev/null; then
    red "$(m 'Failed to apply BBR sysctl settings. Restoring the previous configuration.' '应用 BBR sysctl 设置失败，正在恢复之前的配置。')"
    restore_managed_file "$config_file" "$config_backup"
    if [ -e "$config_file" ]; then sysctl -p "$config_file" >/dev/null 2>&1 || true; fi
    return 1
  fi
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
}

apply_proxy_sysctl() {
  local config_file="/etc/sysctl.d/99-proxy-tuning.conf" config_backup=""
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
    red "$(m 'Failed to apply proxy sysctl settings. Restoring the previous configuration.' '应用代理 sysctl 设置失败，正在恢复之前的配置。')"
    restore_managed_file "$config_file" "$config_backup"
    if [ -e "$config_file" ]; then sysctl -p "$config_file" >/dev/null 2>&1 || true; fi
    return 1
  fi
  green "$(m 'Proxy sysctl tuning applied.' '代理机 sysctl 优化已应用。')"
}

raise_nofile_limits() {
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
  green "$(m 'nofile limits written. Reboot or restart services for full effect.' 'nofile 限制已写入。重启系统或重启服务后完全生效。')"
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

ssh_audit() {
  section "$(m 'SSH audit' 'SSH 审计')"
  if ! has_cmd sshd; then status_bad "$(m 'sshd not found.' '未找到 sshd。')"; return 1; fi

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
  if [ "$pub" = "yes" ]; then status_ok "$(m 'Public-key authentication is enabled.' '公钥认证已启用。')"; else status_bad "$(m 'PubkeyAuthentication is not enabled.' '公钥认证未启用。')"; fi

  case "$root" in
    without-password)
      status_ok "$(m 'Root password login is blocked; without-password is an old alias. Prefer prohibit-password for clarity.' 'root 密码登录已被阻止；without-password 是旧别名，建议改为 prohibit-password 以便更清晰。')" ;;
    prohibit-password)
      status_ok "$(m 'Root password login is blocked by prohibit-password.' 'root 密码登录已被 prohibit-password 阻止。')" ;;
    no)
      status_ok "$(m 'Root SSH login is disabled.' 'root SSH 登录已禁用。')" ;;
    yes)
      status_warn "$(m 'Root login is fully allowed. Prefer prohibit-password or no.' 'root 登录完全允许。建议改为 prohibit-password 或 no。')" ;;
    *)
      status_info "$(m "Root login policy: $root" "root 登录策略：$root")" ;;
  esac

  if [ "$pass" = "yes" ]; then
    if [ "$nonroot_count" -eq 0 ]; then
      status_info "$(m 'PasswordAuthentication is enabled globally, but no non-root interactive user was detected. This is mainly a future-risk setting.' 'PasswordAuthentication 全局开启，但未检测到非 root 交互用户；当前主要是未来风险。')"
    elif [ "$nonroot_hashes" -gt 0 ]; then
      status_warn "$(m 'Password SSH may be possible for non-root users with password hashes. Consider PasswordAuthentication no.' '有非 root 用户带密码 hash，可能可用密码 SSH 登录；建议考虑 PasswordAuthentication no。')"
    else
      status_warn "$(m 'PasswordAuthentication is enabled globally. Check whether non-root users can use password login.' 'PasswordAuthentication 全局开启，请确认非 root 用户是否可密码登录。')"
    fi
  else
    status_ok "$(m 'PasswordAuthentication is disabled.' '密码登录已关闭。')"
  fi

  if [ "$kbd" = "yes" ]; then status_warn "$(m 'Keyboard-interactive auth is enabled. Consider KbdInteractiveAuthentication no.' 'keyboard-interactive 认证已开启，建议 KbdInteractiveAuthentication no。')"; else status_ok "$(m 'Keyboard-interactive auth is disabled.' 'keyboard-interactive 认证已关闭。')"; fi
  if [ "$empty" = "yes" ]; then status_bad "$(m 'Empty passwords are permitted. Disable immediately.' '空密码被允许，请立即关闭。')"; else status_ok "$(m 'Empty passwords are not permitted.' '空密码未被允许。')"; fi
  if [ "$x11" = "yes" ]; then status_warn "$(m 'X11Forwarding is enabled. Ordinary VPS usually should set it to no.' 'X11Forwarding 已开启。普通 VPS 通常建议设为 no。')"; else status_ok "$(m 'X11Forwarding is disabled.' 'X11Forwarding 已关闭。')"; fi
  if [ "$agent" = "yes" ]; then status_warn "$(m 'Agent forwarding is enabled. Disable it unless this host is a trusted jump box.' 'Agent 转发已开启。除非这台机是可信跳板机，否则建议关闭。')"; else status_ok "$(m 'Agent forwarding is disabled.' 'Agent 转发已关闭。')"; fi
  if [ "$gateway" = "yes" ]; then status_warn "$(m 'GatewayPorts is enabled; remote forwards may bind publicly.' 'GatewayPorts 已开启，远程转发可能绑定公网地址。')"; else status_ok "$(m 'GatewayPorts is not open.' 'GatewayPorts 未开放。')"; fi
  if [ "$tunnel" = "yes" ]; then status_warn "$(m 'PermitTunnel is enabled. Usually unnecessary for normal VPS management.' 'PermitTunnel 已开启。普通 VPS 管理通常不需要。')"; else status_ok "$(m 'PermitTunnel is disabled.' 'PermitTunnel 已关闭。')"; fi

  if [[ "$maxauth" =~ ^[0-9]+$ ]] && [ "$maxauth" -le 3 ]; then status_ok "$(m 'MaxAuthTries is strict enough.' 'MaxAuthTries 足够严格。')"; else status_warn "$(m 'Consider MaxAuthTries 3.' '建议考虑 MaxAuthTries 3。')"; fi
  if [[ "$grace" =~ ^[0-9]+$ ]] && [ "$grace" -le 60 ]; then status_ok "$(m 'LoginGraceTime is reasonably short.' 'LoginGraceTime 较合理。')"; else status_warn "$(m 'Consider LoginGraceTime 30.' '建议考虑 LoginGraceTime 30。')"; fi

  if [ "$nonroot_count" -gt 0 ]; then
    echo
    muted "  $(m 'Interactive users:' '交互用户：')"
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

user_has_authorized_key() {
  local user="$1" home auth line
  if [ "$user" = "root" ]; then
    home="/root"
  else
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  [ -n "$home" ] && [ -r "$home/.ssh/authorized_keys" ] || return 1
  auth="$home/.ssh/authorized_keys"
  while IFS= read -r line; do
    ssh_key_line_valid "$line" && return 0
  done < "$auth"
  return 1
}

ssh_require_key_login_ready() {
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
  [ "$found" -eq 1 ] && return 0
  red "$(m 'Refusing to disable SSH password login: no usable authorized_keys entry was found.' 'Refusing to disable SSH password login: no usable authorized_keys entry was found.')"
  status_info "$(m 'Install a public key first, or keep PasswordAuthentication as keep until key login is tested.' 'Install a public key first, or keep PasswordAuthentication as keep until key login is tested.')"
  return 1
}

ssh_install_key() {
  local user key home auth group
  user="$(input_default "$(m 'Target user' '目标用户')" "root")"
  read -r -p "$(m 'Paste SSH public key: ' '粘贴 SSH 公钥：')" key || true
  [ -n "$key" ] || { red "$(m 'Empty key.' '公钥为空。')"; return 1; }
  valid_ssh_public_key "$key" || { red "$(m 'Invalid SSH public key format.' 'SSH 公钥格式无效。')"; return 1; }
  if [ "$user" = "root" ]; then home="/root"; else home="$(getent passwd "$user" | cut -d: -f6)"; fi
  [ -d "$home" ] || { red "$(m "User home not found: $home" "未找到用户家目录：$home")"; return 1; }
  mkdir -p "$home/.ssh"
  group="$(id -gn "$user" 2>/dev/null || echo "$user")"
  auth="$home/.ssh/authorized_keys"
  touch "$auth"
  chmod 700 "$home/.ssh"
  chmod 600 "$auth"
  grep -qxF "$key" "$auth" || echo "$key" >> "$auth"
  chown -R "$user:$group" "$home/.ssh" 2>/dev/null || true
  green "$(m "Public key installed for $user." "已为 $user 安装公钥。")"
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
  local port allow_user password_policy permit_root strict_forwarding allow_tcp fragment_backup=""
  port="$(input_default "$(m 'New SSH port' '新的 SSH 端口')" "$(current_ssh_port_guess)")"
  valid_port "$port" || { red "$(m 'Invalid SSH port. Use 1-65535.' 'SSH 端口无效，请使用 1-65535。')"; return 1; }
  allow_user="$(input_default "$(m 'AllowUsers value, empty means do not set' 'AllowUsers 值，留空表示不设置')" "")"
  password_policy="$(normalize_password_policy "$(input_default "$(m 'PasswordAuthentication policy: keep/no/yes' 'PasswordAuthentication 策略：keep/no/yes')" "keep")")" || { red "$(m 'Invalid PasswordAuthentication policy. Use keep, no, or yes.' 'PasswordAuthentication 策略无效，请使用 keep、no 或 yes。')"; return 1; }
  if [ "$password_policy" = "yes" ]; then
    yellow "$(m 'Enabling SSH password login is usually not recommended.' '通常不建议开启 SSH 密码登录。')"
    confirm_yes "$(m 'Explicitly enable SSH password login?' '明确开启 SSH 密码登录？')" || return 0
  fi
  permit_root="$(input_default "PermitRootLogin" "prohibit-password")"
  strict_forwarding="$(input_yes_no "$(m 'Disable Agent/X11/Tunnel/Gateway forwarding?' '关闭 Agent/X11/Tunnel/Gateway 转发？')" "yes")" || return 1
  allow_tcp="$(input_yes_no "$(m 'Allow TCP forwarding for ssh -L/-R/-D?' '允许 TCP 转发用于 ssh -L/-R/-D？')" "yes")" || return 1
  if [ "$password_policy" = "no" ]; then
    ssh_require_key_login_ready "$allow_user" "$permit_root" || return 1
  fi

  backup_path /etc/ssh/sshd_config >/dev/null
  mkdir -p /etc/ssh/sshd_config.d
  if [ -e "$SSH_HARDENING_FRAGMENT" ]; then
    backup_path "$SSH_HARDENING_FRAGMENT" >/dev/null || { red "$(m 'Failed to back up the existing SSH hardening fragment.' '备份现有 SSH hardening 片段失败。')"; return 1; }
    fragment_backup="$BACKUP_LAST_PATH"
  fi

  cat > "$SSH_HARDENING_FRAGMENT" <<EOF2
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
    cat >> "$SSH_HARDENING_FRAGMENT" <<'EOF2'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF2
  elif [ "$password_policy" = "yes" ]; then
    printf 'PasswordAuthentication %s\n' "$password_policy" >> "$SSH_HARDENING_FRAGMENT"
  fi
  if [ "$strict_forwarding" = "yes" ]; then
    cat >> "$SSH_HARDENING_FRAGMENT" <<'EOF2'
X11Forwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
AllowStreamLocalForwarding no
EOF2
  fi
  if [ "$allow_tcp" = "yes" ]; then echo "AllowTcpForwarding yes" >> "$SSH_HARDENING_FRAGMENT"; else echo "AllowTcpForwarding no" >> "$SSH_HARDENING_FRAGMENT"; fi
  [ -n "$allow_user" ] && echo "AllowUsers $allow_user" >> "$SSH_HARDENING_FRAGMENT"

  if ! sshd -t; then
    red "$(m 'sshd config test failed. Restoring the previous fragment.' 'sshd 配置检查失败，正在恢复之前的片段。')"
    ssh_restore_hardening_backup "$fragment_backup" || red "$(m 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.' '恢复之前的 SSH 配置失败；请保持当前 SSH 会话并手动检查 sshd。')"
    return 1
  fi

  if has_cmd ufw; then
    ufw_ensure_ssh_access || { ssh_restore_hardening_backup "$fragment_backup"; return 1; }
    if ! ufw allow "$port/tcp" comment "SSH"; then
      red "$(m 'SSH firewall allow failed; restoring the previous fragment before SSH reload.' 'SSH 防火墙放行失败；在重载 SSH 前恢复之前的片段。')"
      ssh_restore_hardening_backup "$fragment_backup" || red "$(m 'Failed to restore the previous SSH configuration; keep the current SSH session open and inspect sshd manually.' '恢复之前的 SSH 配置失败；请保持当前 SSH 会话并手动检查 sshd。')"
      return 1
    fi
  fi
  if ! ssh_reload_or_restart; then
    red "SSH service reload/restart failed; restoring the previous hardening fragment to preserve existing access."
    ssh_restore_hardening_backup "$fragment_backup" || red "Rollback reload also failed; keep the current SSH session open and inspect sshd/systemd manually."
    return 1
  fi
  green "$(m "SSH config applied. Keep current session open and test: ssh -p $port <user>@<ip>" "SSH 配置已应用。不要关闭当前窗口，请另开终端测试：ssh -p $port <user>@<ip>")"
  ssh_audit
}

ssh_restore_fragment() {
  confirm_yes "$(m 'Remove SSH fragment written by this script?' '删除本脚本写入的 SSH 配置片段？')" || return 0
  rm -f "$SSH_HARDENING_FRAGMENT" /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
  sshd -t && ssh_reload_or_restart
  green "$(m 'SSH hardening fragment removed.' 'SSH hardening 片段已删除。')"
}

ssh_menu() {
  while true; do
    clear_screen
    title "SSH"
    echo "1) $(m 'SSH audit' 'SSH 审计')"
    echo "2) $(m 'Install public key' '安装公钥')"
    echo "3) $(m 'Configure SSH hardening fragment' '配置 SSH hardening 片段')"
    echo "4) $(m 'Restore/remove hardening fragment' '恢复/删除 hardening 片段')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) ssh_audit; pause ;;
      2) ssh_install_key; pause ;;
      3) ssh_write_hardening; pause ;;
      4) ssh_restore_fragment; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

# ---------- UFW / Fail2ban ----------
ufw_install() { apt_install ufw; green "$(m 'UFW installed.' 'UFW 已安装。')"; }

ufw_warn_default_ssh_port() {
  local ssh_ports="$1"
  if printf ' %s ' "$ssh_ports" | grep -q ' 22 '; then
    yellow "$(m 'SSH appears to include the default port 22.' '检测到 SSH 仍包含默认 22 端口。')"
    status_info "$(m 'Before enabling UFW, consider using the SSH menu to move SSH to a custom port, install a public key, and use key-only login.' '启用 UFW 前，建议先使用 SSH 菜单修改端口、安装公钥，并配置仅公钥登录。')"
    status_info "$(m 'This tool will still allow the current SSH port(s) before UFW changes to avoid locking you out.' '为避免锁死，工具仍会在 UFW 变更前自动放行当前 SSH 端口。')"
  fi
}

ufw_ensure_ssh_access() {
  local ssh_ports p
  ssh_ports="$(current_ssh_ports)"
  [ -n "$ssh_ports" ] || ssh_ports="22"
  ufw_warn_default_ssh_port "$ssh_ports"
  for p in $ssh_ports; do
    valid_port "$p" || { red "$(m "Invalid detected SSH port: $p" "检测到无效 SSH 端口：$p")"; return 1; }
    ufw allow "$p/tcp" comment "SSH" || return 1
  done
  status_ok "$(m "Allowed SSH port(s): $ssh_ports/tcp." "已放行 SSH 端口：$ssh_ports/tcp。")"
}

ufw_audit() {
  section "$(m 'Firewall audit' '防火墙审计')"
  local ssh_ports ufw_state
  ssh_ports="$(current_ssh_ports)"

  if ! has_cmd ufw; then
    status_warn "$(m 'UFW is not installed.' 'UFW 未安装。')"
  else
    ufw_state="$(ufw status 2>/dev/null | awk 'NR==1 {print $2}')"
    kv "UFW status" "${ufw_state:-unknown}"
    if ufw status | grep -q inactive; then
      status_warn "$(m "UFW is inactive. Safe-init can allow SSH port(s) $ssh_ports before enabling." "UFW 未启用。安全初始化会先放行 SSH 端口 $ssh_ports 再启用。")"
    else
      status_ok "$(m 'UFW is active.' 'UFW 已启用。')"
    fi
    echo
    muted "  $(m 'UFW rules:' 'UFW 规则：')"
    ufw status numbered 2>/dev/null | sed -n '1,25p' | print_block || true
  fi

  echo
  muted "  $(m 'Listening TCP/UDP ports and processes:' '监听 TCP/UDP 端口及进程：')"
  listening_ports_compact | print_block || true

  echo
  status_info "$(m "Current SSH port guess: $ssh_ports/tcp." "当前 SSH 端口推测：$ssh_ports/tcp。")"
  status_warn "$(m 'Admin panels should usually be restricted to your management IP/CIDR.' '管理面板通常应限制为仅你的管理 IP/CIDR 可访问。')"
  status_info "$(m 'If using Cloudflare CDN for 80/443, add CF allow rules first, then manually remove broad 80/443 rules after verification.' '如果 80/443 使用 Cloudflare CDN，应先添加 CF 放行规则，确认后再手动删除宽泛 80/443 放行。')"
}

ufw_init_safe() {
  ufw_install
  local ssh_ports
  ssh_ports="$(current_ssh_ports)"
  yellow "$(m "Will set: default deny incoming, allow outgoing, allow SSH port(s): $ssh_ports, then enable UFW." "将设置：默认拒绝入站、允许出站、放行 SSH 端口：$ssh_ports，然后启用 UFW。")"
  ufw_warn_default_ssh_port "$ssh_ports"
  confirm_yes "$(m 'Enable UFW safely?' '安全启用 UFW？')" || return 0
  ufw_ensure_ssh_access || return 1
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw status verbose
}

ufw_allow_port() {
  ufw_install
  local port proto comment
  port="$(input_default "$(m 'Port or range' '端口或范围')" "443")"
  proto="$(input_default "$(m 'Protocol tcp/udp' '协议 tcp/udp')" "tcp")"
  comment="$(input_default "$(m 'Comment' '备注')" "manual")"
  valid_port_or_range "$port" || { red "$(m 'Invalid port or range. Use 443 or 10000:20000.' '端口或范围无效，请使用 443 或 10000:20000。')"; return 1; }
  valid_proto "$proto" || { red "$(m 'Invalid protocol. Use tcp or udp.' '协议无效，请使用 tcp 或 udp。')"; return 1; }
  ufw allow "$port/$proto" comment "$comment"
  ufw status numbered
}

ufw_allow_ip_to_port() {
  ufw_install
  local ip port proto
  ip="$(input_default "$(m 'Allowed source IP/CIDR' '允许的来源 IP/CIDR')" "")"
  port="$(input_default "$(m 'Destination port' '目标端口')" "")"
  proto="$(input_default "$(m 'Protocol tcp/udp' '协议 tcp/udp')" "tcp")"
  if [ -z "$ip" ] || [ -z "$port" ]; then red "$(m 'Source and port are required.' '来源和端口不能为空。')"; return 1; fi
  valid_port "$port" || { red "$(m 'Invalid destination port. Use 1-65535.' '目标端口无效，请使用 1-65535。')"; return 1; }
  valid_proto "$proto" || { red "$(m 'Invalid protocol. Use tcp or udp.' '协议无效，请使用 tcp 或 udp。')"; return 1; }
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
  mkdir -p /var/lib/vps-init
  v4_tmp="$(mktemp /var/lib/vps-init/cloudflare-ips-v4.txt.XXXXXX)" || return 1
  v6_tmp="$(mktemp /var/lib/vps-init/cloudflare-ips-v6.txt.XXXXXX)" || { cleanup_files "$v4_tmp"; return 1; }
  if ! curl -fsSL "$CF_IPV4_URL" -o "$v4_tmp"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  if ! curl -fsSL "$CF_IPV6_URL" -o "$v6_tmp"; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' "$v4_tmp" || { red "Invalid Cloudflare IPv4 list."; cleanup_files "$v4_tmp" "$v6_tmp"; return 1; }
  grep -Eq ':' "$v6_tmp" || { red "Invalid Cloudflare IPv6 list."; cleanup_files "$v4_tmp" "$v6_tmp"; return 1; }
  if ! mv "$v4_tmp" /var/lib/vps-init/cloudflare-ips-v4.txt; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
  if ! mv "$v6_tmp" /var/lib/vps-init/cloudflare-ips-v6.txt; then cleanup_files "$v4_tmp" "$v6_tmp"; return 1; fi
}

ufw_parse_cloudflare_ports() {
  local ports="$1" p
  IFS=',' read -ra port_arr <<< "$ports"
  for p in "${port_arr[@]}"; do
    p="$(echo "$p" | xargs)"
    valid_port "$p" || { red "$(m "Invalid Cloudflare port: $p" "Cloudflare 端口无效：$p")"; return 1; }
  done
}

ufw_build_cloudflare_desired_rules() {
  local output="$1" f cidr p
  : > "$output"
  for f in /var/lib/vps-init/cloudflare-ips-v4.txt /var/lib/vps-init/cloudflare-ips-v6.txt; do
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

ufw_cf_lock_acquire() {
  mkdir -p "$(dirname "$UFW_CF_LOCK_FILE")"
  if ! has_cmd flock; then
    red "$(m 'flock is required for safe Cloudflare UFW sync. Install util-linux and retry.' '安全同步 Cloudflare UFW 规则需要 flock。请安装 util-linux 后重试。')"
    return 1
  fi
  exec {UFW_CF_LOCK_FD}>"$UFW_CF_LOCK_FILE"
  if ! flock -w "${UFW_CF_LOCK_TIMEOUT:-120}" "$UFW_CF_LOCK_FD"; then
    red "$(m 'Another Cloudflare UFW sync is running; lock timeout reached.' '另一个 Cloudflare UFW 同步正在运行；等待锁超时。')"
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
  local ports desired="" current="" adds="" deletes="" state_tmp="" add_count delete_count cidr p rule_error=0
  local -a port_arr
  if [ -n "${UFW_CF_PORTS:-}" ]; then
    ports="$UFW_CF_PORTS"
  else
    ports="$(input_default "$(m 'Ports to allow from Cloudflare only, comma-separated' '仅允许 Cloudflare 访问的端口，逗号分隔')" "80,443")"
  fi
  ufw_parse_cloudflare_ports "$ports" || return 1
  yellow "$(m 'This incrementally syncs Cloudflare allow rules managed by this tool.' '这会增量同步由本工具托管的 Cloudflare 放行规则。')"
  yellow "$(m 'It will not remove broad manual 80/443 rules; review those after verification.' '它不会删除手动添加的宽泛 80/443 规则，请验证后自行检查。')"
  confirm_yes "$(m 'Continue Cloudflare UFW sync?' '继续同步 Cloudflare UFW 规则？')" || return 0

  ufw_cf_lock_acquire || return 1
  ufw_ensure_ssh_access || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }
  cf_fetch_ranges || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }

  desired="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }
  current="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }
  adds="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }
  deletes="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }
  state_tmp="$(mktemp)" || { ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"; return 1; }

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
  status_info "$(m "Cloudflare rules to add: $add_count; managed stale rules to delete: $delete_count." "需新增 Cloudflare 规则：$add_count；需删除托管的过期规则：$delete_count。")"

  while read -r cidr p; do
    if [ -z "$cidr" ] || [ -z "$p" ]; then continue; fi
    if ! ufw allow proto tcp from "$cidr" to any port "$p" comment "cloudflare-$p"; then
      red "$(m "Cloudflare UFW add failed: $cidr -> $p/tcp. Managed state was not updated." "Cloudflare UFW 新增失败：$cidr -> $p/tcp。托管状态未更新。")"
      rule_error=1
      break
    fi
  done < "$adds"
  if [ "$rule_error" -ne 0 ]; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"
    return 1
  fi

  while read -r cidr p; do
    if [ -z "$cidr" ] || [ -z "$p" ]; then continue; fi
    if ! ufw_delete_rule_exact "$cidr" "$p"; then
      red "$(m "Cloudflare UFW delete failed: $cidr -> $p/tcp. Managed state was not updated." "Cloudflare UFW 删除失败：$cidr -> $p/tcp。托管状态未更新。")"
      rule_error=1
      break
    fi
  done < "$deletes"
  if [ "$rule_error" -ne 0 ]; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"
    return 1
  fi

  mkdir -p "$(dirname "$UFW_CF_STATE_FILE")"
  if ! cp "$desired" "$state_tmp"; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"
    return 1
  fi
  if ! install -m 0644 "$state_tmp" "$UFW_CF_STATE_FILE"; then
    ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"
    return 1
  fi

  ufw_cf_sync_cleanup "$desired" "$current" "$adds" "$deletes" "$state_tmp"
  ufw status numbered || true
  green "$(m 'Cloudflare UFW sync complete.' 'Cloudflare UFW 增量同步完成。')"
}

ufw_allow_cloudflare_web() {
  ufw_sync_cloudflare_web
}

ufw_reset_safe() {
  confirm_yes "$(m 'Reset ALL UFW rules?' '重置所有 UFW 规则？')" || return 0
  ufw --force reset
  green "$(m 'UFW reset.' 'UFW 已重置。')"
}

ufw_menu() {
  while true; do
    clear_screen
    title "$(m 'UFW Firewall' 'UFW 防火墙')"
    echo "1) $(m 'Firewall audit' '防火墙审计')"
    echo "2) $(m 'Install UFW' '安装 UFW')"
    echo "3) $(m 'Safe init UFW' '安全初始化 UFW')"
    echo "4) $(m 'Allow custom port' '放行自定义端口')"
    echo "5) $(m 'Allow only IP/CIDR to port' '仅允许指定 IP/CIDR 访问端口')"
    echo "6) $(m 'Rate-limit SSH' '对 SSH 限速')"
    echo "7) $(m 'Add Cloudflare ranges to 80/443' '添加 Cloudflare 网段到 80/443')"
    echo "8) $(m 'Reset UFW' '重置 UFW')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
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
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

fail2ban_audit() {
  section "$(m 'Fail2ban audit' 'Fail2ban 审计')"
  if ! has_cmd fail2ban-client; then
    status_warn "$(m 'Fail2ban is not installed.' 'Fail2ban 未安装。')"
    return 0
  fi
  local active jails tmp
  active="$(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
  jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
  kv "Service" "$active"
  kv "Jails" "${jails:-none}"
  tmp="$(mktemp)"
  if fail2ban-client status sshd >"$tmp" 2>/dev/null; then
    status_ok "$(m 'sshd jail is active.' 'sshd jail 已启用。')"
    sed -n '1,20p' "$tmp" | print_block
  else
    status_warn "$(m 'sshd jail is not active or not found.' 'sshd jail 未启用或未找到。')"
  fi
  rm -f "$tmp"
}

fail2ban_setup_sshd() {
  apt_install fail2ban
  mkdir -p /etc/fail2ban/jail.d
  local jail_file="/etc/fail2ban/jail.d/sshd-vps-init.local"
  local bantime findtime maxretry ports jail_backup=""
  bantime="$(input_default "bantime" "12h")"
  findtime="$(input_default "findtime" "10m")"
  maxretry="$(input_default "maxretry" "3")"
  valid_fail2ban_time "$bantime" || { red "$(m 'Invalid bantime. Use values such as 12h, 30m, 600, or -1.' 'bantime 无效。请使用 12h、30m、600 或 -1 等格式。')"; return 1; }
  valid_fail2ban_time "$findtime" || { red "$(m 'Invalid findtime. Use values such as 10m or 600.' 'findtime 无效。请使用 10m 或 600 等格式。')"; return 1; }
  valid_positive_int "$maxretry" || { red "$(m 'Invalid maxretry. Use a positive integer.' 'maxretry 无效。请使用正整数。')"; return 1; }
  ports="$(current_ssh_ports | tr ' ' ',')"
  if [ -e "$jail_file" ]; then
    backup_path "$jail_file" >/dev/null || { red "$(m 'Failed to back up the existing Fail2ban jail.' '备份现有 Fail2ban jail 失败。')"; return 1; }
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
    red "$(m 'Fail2ban configuration test failed. Restoring the previous jail.' 'Fail2ban 配置检查失败，正在恢复之前的 jail。')"
    if [ -n "$jail_backup" ]; then cp -a "$jail_backup" "$jail_file"; else rm -f "$jail_file"; fi
    fail2ban-client -t || true
    return 1
  fi
  if ! systemctl enable --now fail2ban || ! systemctl restart fail2ban; then
    red "$(m 'Fail2ban service activation failed. Restoring the previous jail.' 'Fail2ban 服务启用失败，正在恢复之前的 jail。')"
    if [ -n "$jail_backup" ]; then cp -a "$jail_backup" "$jail_file"; else rm -f "$jail_file"; fi
    systemctl restart fail2ban 2>/dev/null || true
    return 1
  fi
  fail2ban_audit
}

fail2ban_unban() {
  local jail ip
  jail="$(input_default "Jail" "sshd")"
  ip="$(input_default "$(m 'IP to unban' '要解封的 IP')" "")"
  [ -n "$ip" ] || return 1
  valid_ip_literal "$ip" || { red "$(m 'Invalid IP to unban.' 'Invalid IP to unban.')"; return 1; }
  fail2ban-client set "$jail" unbanip "$ip"
}

fail2ban_menu() {
  while true; do
    clear_screen
    title "Fail2ban"
    echo "1) $(m 'Audit' '审计')"
    echo "2) $(m 'Install/configure sshd jail' '安装/配置 sshd jail')"
    echo "3) $(m 'Unban IP' '解封 IP')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) fail2ban_audit; pause ;;
      2) fail2ban_setup_sshd; pause ;;
      3) fail2ban_unban; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

# ---------- DNS ----------
dns_audit() {
  section "$(m 'DNS audit' 'DNS 审计')"
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
    status_warn "$(m '/etc/resolv.conf appears cloud-init managed; direct edits may be overwritten.' '/etc/resolv.conf 似乎由 cloud-init 管理，直接修改可能被覆盖。')"
  fi
  if has_cmd resolvectl; then
    echo
    muted "  resolvectl DNS servers:"
    resolvectl dns 2>/dev/null | print_block || true
  fi
  echo
  status_info "$(m 'Use DNS test before applying changes on production servers.' '生产服务器改 DNS 前建议先测试。')"
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
  systemctl restart systemd-resolved 2>/dev/null || true
}

dns_apply_resolved() {
  local dns fallback config_file="/etc/systemd/resolved.conf.d/10-vps-init-dns.conf" config_backup=""
  is_systemd || { red "$(m 'systemd not detected.' '未检测到 systemd。')"; return 1; }
  systemctl list-unit-files | grep -q '^systemd-resolved.service' || { red "systemd-resolved not found."; return 1; }
  dns="$(input_default "$(m 'Primary DNS servers, space-separated' '主 DNS，空格分隔')" "1.1.1.1 8.8.8.8")"
  fallback="$(input_default "$(m 'Fallback DNS servers, space-separated' '备用 DNS，空格分隔')" "1.0.0.1 8.8.4.4")"
  valid_ip_list "$dns" || { red "$(m 'Invalid primary DNS server list. Use space-separated IPv4/IPv6 addresses.' '主 DNS 列表无效。请使用空格分隔的 IPv4/IPv6 地址。')"; return 1; }
  valid_ip_list "$fallback" || { red "$(m 'Invalid fallback DNS server list. Use space-separated IPv4/IPv6 addresses.' '备用 DNS 列表无效。请使用空格分隔的 IPv4/IPv6 地址。')"; return 1; }
  confirm_yes "$(m 'Apply DNS via systemd-resolved?' '通过 systemd-resolved 应用 DNS？')" || return 0
  mkdir -p /etc/systemd/resolved.conf.d
  if [ -e "$config_file" ]; then
    backup_path "$config_file" >/dev/null || { red "$(m 'Failed to back up the existing systemd-resolved configuration.' '备份现有 systemd-resolved 配置失败。')"; return 1; }
    config_backup="$BACKUP_LAST_PATH"
  fi
  cat > "$config_file" <<EOF2
[Resolve]
DNS=$dns
FallbackDNS=$fallback
Cache=yes
EOF2
  if ! systemctl enable --now systemd-resolved || ! systemctl restart systemd-resolved; then
    red "$(m 'systemd-resolved activation failed. Restoring the previous configuration.' 'systemd-resolved 启用失败，正在恢复之前的配置。')"
    dns_restore_resolved_backup "$config_file" "$config_backup"
    return 1
  fi
  dns_audit
}

dns_apply_resolvconf() {
  local dns1 dns2
  dns1="$(input_default "nameserver 1" "1.1.1.1")"
  dns2="$(input_default "nameserver 2" "8.8.8.8")"
  valid_ip_literal "$dns1" || { red "$(m 'Invalid nameserver 1. Use an IPv4 or IPv6 address.' 'nameserver 1 无效。请使用 IPv4 或 IPv6 地址。')"; return 1; }
  valid_ip_literal "$dns2" || { red "$(m 'Invalid nameserver 2. Use an IPv4 or IPv6 address.' 'nameserver 2 无效。请使用 IPv4 或 IPv6 地址。')"; return 1; }
  [ -L /etc/resolv.conf ] && { red "$(m '/etc/resolv.conf is a managed symbolic link. Use the systemd-resolved option or update the owning network manager instead.' '/etc/resolv.conf 是受管理的符号链接。请使用 systemd-resolved 选项，或修改负责管理它的网络服务。')"; return 1; }
  yellow "$(m 'Direct /etc/resolv.conf edits may be overwritten by cloud-init, DHCP, NetworkManager, or systemd-resolved.' '直接修改 /etc/resolv.conf 可能被 cloud-init、DHCP、NetworkManager 或 systemd-resolved 覆盖。')"
  confirm_yes "$(m 'Edit /etc/resolv.conf directly?' '直接编辑 /etc/resolv.conf？')" || return 0
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
    echo "1) $(m 'DNS audit' 'DNS 审计')"
    echo "2) $(m 'Test common public resolvers' '测试常见公共 DNS')"
    echo "3) $(m 'Apply via systemd-resolved' '通过 systemd-resolved 应用')"
    echo "4) $(m 'Apply by direct /etc/resolv.conf edit' '直接编辑 /etc/resolv.conf')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) dns_audit; pause ;;
      2) dns_test; pause ;;
      3) dns_apply_resolved; pause ;;
      4) dns_apply_resolvconf; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

# ---------- logs ----------
logs_audit() {
  section "$(m 'Logs audit' '日志审计')"
  local journal_usage varlog_size
  if is_systemd; then
    journal_usage="$(journalctl --disk-usage 2>/dev/null | sed 's/^/ /')"
    kv "journald usage" "${journal_usage:-unknown}"
    if [ -f /etc/systemd/journald.conf.d/99-vps-init-size-limit.conf ]; then
      status_ok "$(m 'vps-init journald size limit is configured.' 'vps-init journald 体积限制已配置。')"
    else
      status_warn "$(m 'No vps-init journald limit found. Consider setting SystemMaxUse.' '未发现 vps-init journald 限额。建议设置 SystemMaxUse。')"
    fi
  else
    status_warn "$(m 'systemd not detected; journald audit skipped.' '未检测到 systemd，跳过 journald 审计。')"
  fi

  varlog_size="$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
  kv "/var/log size" "${varlog_size:-unknown}"
  echo
  muted "  $(m 'Largest /var/log entries:' '/var/log 最大项目：')"
  du -ah /var/log 2>/dev/null | sort -hr | head -8 | print_block || true
}

logs_limit_journald() {
  is_systemd || { red "$(m 'systemd not detected.' '未检测到 systemd。')"; return 1; }
  local system_max runtime_max retention
  local config_file="/etc/systemd/journald.conf.d/99-vps-init-size-limit.conf" config_backup=""
  system_max="$(input_default "SystemMaxUse" "200M")"
  runtime_max="$(input_default "RuntimeMaxUse" "100M")"
  retention="$(input_default "MaxRetentionSec" "7day")"
  valid_systemd_size "$system_max" || { red "$(m 'Invalid SystemMaxUse. Use values such as 200M or 1G.' 'SystemMaxUse 无效。请使用 200M 或 1G 等格式。')"; return 1; }
  valid_systemd_size "$runtime_max" || { red "$(m 'Invalid RuntimeMaxUse. Use values such as 100M or 1G.' 'RuntimeMaxUse 无效。请使用 100M 或 1G 等格式。')"; return 1; }
  valid_systemd_timespan "$retention" || { red "$(m 'Invalid MaxRetentionSec. Use values such as 7day or 24h.' 'MaxRetentionSec 无效。请使用 7day 或 24h 等格式。')"; return 1; }
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
    red "$(m 'Failed to restart systemd-journald. Restoring the previous configuration.' '重启 systemd-journald 失败，正在恢复之前的配置。')"
    restore_managed_file "$config_file" "$config_backup"
    systemctl restart systemd-journald 2>/dev/null || true
    return 1
  fi
  journalctl --disk-usage || true
}

logs_vacuum() {
  is_systemd || { red "$(m 'systemd not detected.' '未检测到 systemd。')"; return 1; }
  local size
  size="$(input_default "$(m 'Vacuum journal down to size' '清理 journald 到指定大小')" "200M")"
  valid_systemd_size "$size" || { red "$(m 'Invalid journal vacuum size. Use values such as 200M or 1G.' 'journald 清理大小无效。请使用 200M 或 1G 等格式。')"; return 1; }
  confirm_yes "$(m "Vacuum journald logs to $size?" "将 journald 日志清理到 $size？")" || return 0
  journalctl --vacuum-size="$size"
  journalctl --disk-usage || true
}

logs_menu() {
  while true; do
    clear_screen
    title "$(m 'Logs' '日志')"
    echo "1) $(m 'Logs audit' '日志审计')"
    echo "2) $(m 'Limit journald size' '限制 journald 大小')"
    echo "3) $(m 'Vacuum journald now' '立即清理 journald')"
    echo "0) $(m 'Back' '返回')"
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) logs_audit; pause ;;
      2) logs_limit_journald; pause ;;
      3) logs_vacuum; pause ;;
      0) return ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

audit_all() {
  clear_screen
  title "$(m 'Full Environment Audit' '完整环境审计')"
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

  section "$(m 'Summary' '总结')"
  status_info "$(m 'Audit mode is read-only. No settings were changed.' '审计模式是只读的，没有修改任何设置。')"
  status_info "$(m 'Use the individual module menus to apply changes with confirmation.' '如需修改，请进入对应模块并确认后应用。')"
}

low_risk_baseline() {
  local mode="${1:-interactive}" failures=0
  yellow "$(m 'Low-risk baseline includes: basic tools, BBR if supported, memory profile, proxy sysctl, nofile, journald limit.' '低风险基线包括：基础工具、BBR（如支持）、内存配置、代理 sysctl、nofile、journald 限额。')"
  yellow "$(m 'It does NOT change SSH, UFW, DNS, Fail2ban, swapfile, or ZRAM.' '它不会修改 SSH、UFW、DNS、Fail2ban、swapfile 或 ZRAM。')"
  log_action "baseline" "start mode=$mode"
  confirm_yes "$(m 'Run low-risk baseline?' '执行低风险基线？')" || return 0
  if ! install_basic_tools; then failures=$((failures + 1)); fi
  if bbr_supported; then
    if ! enable_bbr; then failures=$((failures + 1)); fi
  else
    status_info "$(m 'BBR is not supported; baseline skipped it.' '当前不支持 BBR；基线已跳过。')"
  fi
  if ! apply_memory_sysctl "$(recommend_swappiness)" "50"; then failures=$((failures + 1)); fi
  if ! apply_proxy_sysctl; then failures=$((failures + 1)); fi
  if ! raise_nofile_limits; then failures=$((failures + 1)); fi
  if ! logs_limit_journald; then failures=$((failures + 1)); fi
  if [ "$failures" -gt 0 ]; then
    log_action "baseline" "partial-failure mode=$mode failures=$failures"
    red "$(m "Baseline completed with $failures failed step(s). Review the output before rebooting." "基线执行完成，但有 $failures 个步骤失败。重启前请检查输出。")"
    return 1
  fi
  log_action "baseline" "complete mode=$mode"
  green "$(m 'Baseline complete. Reboot is recommended.' '基线执行完成。建议重启。')"
}

list_backups() {
  make_backup_dir
  find "$BACKUP_ROOT" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
}

language_menu() {
  echo "1) English"
  echo "2) 中文"
  read -r -p "Choose [1/2]: " ans || true
  case "$ans" in
    2|cn|CN|zh|中文) LANG_MODE="cn" ;;
    *) LANG_MODE="en" ;;
  esac
  green "$(m 'Language switched to English.' '语言已切换为中文。')"
}

show_help() {
  cat <<EOF2
$SCRIPT_NAME $TOOL_VERSION

Usage:
  bash vps_init_tool.sh [options] [command]

Commands:
  --preflight        Run read-only checks; does not require root.
  --audit            Run full read-only environment audit.
  --status           Show system status.
  --baseline         Run the low-risk baseline non-interactively.
  --ufw-audit        Show UFW/firewall audit.
  --ufw-cf-sync      Incrementally sync Cloudflare allow rules for web ports.
  --version          Print version.
  --help             Show this help.

Options:
  --yes, -y          Auto-confirm prompts for non-interactive commands.
  --lang en|cn       Set output language.
  --ports LIST       Cloudflare ports for --ufw-cf-sync, default: 80,443.

Environment:
  VPS_INIT_YES=1
  VPS_INIT_LANG=en|cn
  VPS_INIT_CF_PORTS=80,443
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
        ;;
      --preflight|--audit|--status|--baseline|--ufw-audit|--ufw-cf-sync)
        [ -z "$cmd" ] || { red "Only one command may be specified."; show_help; exit 2; }
        cmd="$1"
        ;;
      *)
        red "$(m "Unknown argument: $1" "未知参数：$1")"
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
    --preflight) preflight_check; exit 0 ;;
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
      --baseline) ASSUME_YES=1; low_risk_baseline "cli" ;;
      --ufw-audit) ufw_audit ;;
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
    echo "1) $(m 'Full environment audit' '完整环境审计')"
    echo "2) $(m 'System status' '系统状态')"
    echo "3) $(m 'Memory / Swap / ZRAM' '内存 / Swap / ZRAM')"
    echo "4) SSH"
    echo "5) $(m 'UFW Firewall / Cloudflare ranges' 'UFW 防火墙 / Cloudflare 网段')"
    echo "6) Fail2ban"
    echo "7) DNS"
    echo "8) $(m 'Logs / journald' '日志 / journald')"
    echo "9) $(m 'Enable BBR' '启用 BBR')"
    echo "10) $(m 'Proxy sysctl tuning' '代理机 sysctl 优化')"
    echo "11) $(m 'Raise nofile limits' '提高 nofile 限制')"
    echo "12) $(m 'Install basic tools' '安装基础工具')"
    echo "13) $(m 'Run low-risk baseline' '执行低风险基线')"
    echo "14) $(m 'List config backups' '列出配置备份')"
    echo "15) $(m 'Switch language' '切换语言')"
    echo "0) $(m 'Exit' '退出')"
    echo
    read -r -p "$(m 'Choose: ' '请选择：')" c
    case "$c" in
      1) audit_all; pause ;;
      2) show_system_status; pause ;;
      3) memory_optimize_menu ;;
      4) ssh_menu ;;
      5) ufw_menu ;;
      6) fail2ban_menu ;;
      7) dns_menu ;;
      8) logs_menu ;;
      9) enable_bbr; pause ;;
      10) apply_proxy_sysctl; pause ;;
      11) raise_nofile_limits; pause ;;
      12) install_basic_tools; pause ;;
      13) low_risk_baseline; pause ;;
      14) list_backups; pause ;;
      15) language_menu; pause ;;
      0) exit 0 ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

handle_cli "$@"
need_root
choose_language
require_debian_family
main_menu
