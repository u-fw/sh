#!/usr/bin/env bash
set -Eeuo pipefail

# VPS Init Tool v1.0.3
# Debian/Ubuntu VPS bootstrap, audit and maintenance helper.
# Scope: memory, SSH, UFW firewall, Fail2ban, DNS, logs, basic network tuning.
# Principle: audit first, confirm before risky changes.

TOOL_VERSION="1.0.3"
SCRIPT_NAME="VPS Init Tool"
BACKUP_ROOT="/root/vps-init-backups"
SWAPFILE="/swapfile"
CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
LANG_MODE="${VPS_INIT_LANG:-en}"

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
  echo
  yellow "$prompt"
  read -r -p "$(m 'Type YES to continue: ' '输入 YES 继续：')" ans || true
  [ "$ans" = "YES" ]
}

input_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
  printf '%s\n' "${value:-$default}"
}

make_backup_dir() { mkdir -p "$BACKUP_ROOT"; }
backup_path() {
  local p="$1" safe dest
  [ -e "$p" ] || return 0
  make_backup_dir
  safe="$(echo "$p" | sed 's#/#_#g; s#^_##')"
  dest="$BACKUP_ROOT/${safe}.$(date +%F-%H%M%S).bak"
  cp -a "$p" "$dest"
  echo "Backup: $dest"
}

# ---------- package helpers ----------
apt_update_done=0
apt_update_once() {
  if [ "$apt_update_done" -eq 0 ]; then
    apt-get update
    apt_update_done=1
  fi
}

apt_install() {
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ---------- common helpers ----------
get_mem_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
get_root_avail_mb() { df -Pm / | awk 'NR==2 {print $4}'; }

parse_size_to_mb() {
  local s="$1" n
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $((${BASH_REMATCH[1]} * 1024)); return 0; fi
  if [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "$s" =~ ^([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  n="$(echo "$s" | tr -cd '0-9' | head -c 8)"
  echo "${n:-1024}"
}

listening_ports_compact() {
  local tmp="/tmp/vps-init-ss.$$.$RANDOM"
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

  if [ "$max_by_disk_mb" -lt "$rec_mb" ]; then rec_mb="$max_by_disk_mb"; fi
  if [ "$rec_mb" -lt 512 ]; then rec_mb=512; fi
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
  backup_path /etc/sysctl.d/99-memory-tuning.conf >/dev/null || true
  cat > /etc/sysctl.d/99-memory-tuning.conf <<EOF2
vm.swappiness=$swappiness
vm.vfs_cache_pressure=$vfs_cache_pressure
EOF2
  sysctl --system >/dev/null || true
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
    openssl rsync screen tmux

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
  swappiness="$(input_default "vm.swappiness" "$(recommend_swappiness)")"
  vfs_cache_pressure="$(input_default "vm.vfs_cache_pressure" "50")"

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
    mb="$(parse_size_to_mb "$size")"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=progress
  fi

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon -p 10 "$SWAPFILE"

  backup_path /etc/fstab >/dev/null || true
  grep -qE "^[^#]*[[:space:]]$SWAPFILE[[:space:]]" /etc/fstab || echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
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
  backup_path /etc/systemd/zram-generator.conf >/dev/null || true
  cat > /etc/systemd/zram-generator.conf <<EOF2
[zram0]
zram-size = $size_expr
compression-algorithm = $algo
swap-priority = 100
EOF2
  systemctl daemon-reload
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
}

setup_zram_tools() {
  local size_hint_mb="$1"
  apt_install zram-tools
  backup_path /etc/default/zramswap >/dev/null || true
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
  systemctl restart zramswap.service 2>/dev/null || systemctl restart zram-config.service 2>/dev/null || true
}

setup_zram_fallback() {
  local size mb
  size="$(input_default "$(m 'ZRAM fallback size' 'ZRAM fallback 大小')" "$(recommend_zram_size)")"
  mb="$(parse_size_to_mb "$size")"
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
  enable="$(input_default "$(m 'Enable/configure ZRAM? yes/no' '启用/配置 ZRAM？yes/no')" "yes")"
  [ "$enable" = "yes" ] || { yellow "$(m 'ZRAM skipped.' '已跳过 ZRAM。')"; return 0; }
  is_systemd || { red "$(m 'systemd not detected. ZRAM auto-start setup skipped.' '未检测到 systemd，跳过 ZRAM 自启动配置。')"; return 1; }
  zram_supported || { red "$(m 'ZRAM not supported by this kernel/VPS layer.' '当前内核或 VPS 虚拟化层不支持 ZRAM。')"; return 1; }

  size_hint="$(recommend_zram_size)"
  apt_update_once
  if apt-cache show systemd-zram-generator >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_generator || setup_zram_fallback
  elif apt-cache show zram-tools >/dev/null 2>&1; then
    stop_known_zram_services
    setup_zram_tools "$size_hint" || setup_zram_fallback
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
enable_bbr() {
  blue "$(m 'Enabling BBR if supported...' '正在尝试启用 BBR...')"
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    red "$(m 'BBR is not supported or is blocked by the virtualization layer.' '当前内核不支持 BBR，或被 VPS 虚拟化层限制。')"
    return 1
  fi
  backup_path /etc/sysctl.d/90-bbr.conf >/dev/null || true
  cat > /etc/sysctl.d/90-bbr.conf <<'EOF2'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  sysctl --system >/dev/null || true
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
}

apply_proxy_sysctl() {
  backup_path /etc/sysctl.d/99-proxy-tuning.conf >/dev/null || true
  cat > /etc/sysctl.d/99-proxy-tuning.conf <<'EOF2'
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
    cat >> /etc/sysctl.d/99-proxy-tuning.conf <<'EOF2'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  fi
  sysctl --system >/dev/null || true
  green "$(m 'Proxy sysctl tuning applied.' '代理机 sysctl 优化已应用。')"
}

raise_nofile_limits() {
  backup_path /etc/security/limits.d/99-proxy-limits.conf >/dev/null || true
  cat > /etc/security/limits.d/99-proxy-limits.conf <<'EOF2'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF2
  if is_systemd; then
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF2'
[Manager]
DefaultLimitNOFILE=1048576
EOF2
    cat > /etc/systemd/user.conf.d/99-limits.conf <<'EOF2'
[Manager]
DefaultLimitNOFILE=1048576
EOF2
    systemctl daemon-reexec || true
  fi
  green "$(m 'nofile limits written. Reboot or restart services for full effect.' 'nofile 限制已写入。重启系统或重启服务后完全生效。')"
}

# ---------- SSH ----------
current_ssh_ports() {
  if has_cmd sshd; then
    sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -nu | paste -sd' ' -
  else
    echo "22"
  fi
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
  [ "$pub" = "yes" ] && status_ok "$(m 'Public-key authentication is enabled.' '公钥认证已启用。')" || status_bad "$(m 'PubkeyAuthentication is not enabled.' '公钥认证未启用。')"

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

  [ "$kbd" = "yes" ] && status_warn "$(m 'Keyboard-interactive auth is enabled. Consider KbdInteractiveAuthentication no.' 'keyboard-interactive 认证已开启，建议 KbdInteractiveAuthentication no。')" || status_ok "$(m 'Keyboard-interactive auth is disabled.' 'keyboard-interactive 认证已关闭。')"
  [ "$empty" = "yes" ] && status_bad "$(m 'Empty passwords are permitted. Disable immediately.' '空密码被允许，请立即关闭。')" || status_ok "$(m 'Empty passwords are not permitted.' '空密码未被允许。')"
  [ "$x11" = "yes" ] && status_warn "$(m 'X11Forwarding is enabled. Ordinary VPS usually should set it to no.' 'X11Forwarding 已开启。普通 VPS 通常建议设为 no。')" || status_ok "$(m 'X11Forwarding is disabled.' 'X11Forwarding 已关闭。')"
  [ "$agent" = "yes" ] && status_warn "$(m 'Agent forwarding is enabled. Disable it unless this host is a trusted jump box.' 'Agent 转发已开启。除非这台机是可信跳板机，否则建议关闭。')" || status_ok "$(m 'Agent forwarding is disabled.' 'Agent 转发已关闭。')"
  [ "$gateway" = "yes" ] && status_warn "$(m 'GatewayPorts is enabled; remote forwards may bind publicly.' 'GatewayPorts 已开启，远程转发可能绑定公网地址。')" || status_ok "$(m 'GatewayPorts is not open.' 'GatewayPorts 未开放。')"
  [ "$tunnel" = "yes" ] && status_warn "$(m 'PermitTunnel is enabled. Usually unnecessary for normal VPS management.' 'PermitTunnel 已开启。普通 VPS 管理通常不需要。')" || status_ok "$(m 'PermitTunnel is disabled.' 'PermitTunnel 已关闭。')"

  if [[ "$maxauth" =~ ^[0-9]+$ ]] && [ "$maxauth" -le 3 ]; then status_ok "$(m 'MaxAuthTries is strict enough.' 'MaxAuthTries 足够严格。')"; else status_warn "$(m 'Consider MaxAuthTries 3.' '建议考虑 MaxAuthTries 3。')"; fi
  if [[ "$grace" =~ ^[0-9]+$ ]] && [ "$grace" -le 60 ]; then status_ok "$(m 'LoginGraceTime is reasonably short.' 'LoginGraceTime 较合理。')"; else status_warn "$(m 'Consider LoginGraceTime 30.' '建议考虑 LoginGraceTime 30。')"; fi

  if [ "$nonroot_count" -gt 0 ]; then
    echo
    muted "  $(m 'Interactive users:' '交互用户：')"
    interactive_users | print_block
  fi
}

ssh_install_key() {
  local user key home auth
  user="$(input_default "$(m 'Target user' '目标用户')" "root")"
  read -r -p "$(m 'Paste SSH public key: ' '粘贴 SSH 公钥：')" key || true
  [ -n "$key" ] || { red "$(m 'Empty key.' '公钥为空。')"; return 1; }
  if [ "$user" = "root" ]; then home="/root"; else home="$(getent passwd "$user" | cut -d: -f6)"; fi
  [ -d "$home" ] || { red "$(m "User home not found: $home" "未找到用户家目录：$home")"; return 1; }
  mkdir -p "$home/.ssh"
  auth="$home/.ssh/authorized_keys"
  touch "$auth"
  chmod 700 "$home/.ssh"
  chmod 600 "$auth"
  grep -qxF "$key" "$auth" || echo "$key" >> "$auth"
  chown -R "$user:$user" "$home/.ssh" 2>/dev/null || true
  green "$(m "Public key installed for $user." "已为 $user 安装公钥。")"
}

ssh_write_hardening() {
  local port allow_user disable_password permit_root strict_forwarding allow_tcp
  port="$(input_default "$(m 'New SSH port' '新的 SSH 端口')" "$(current_ssh_port_guess)")"
  allow_user="$(input_default "$(m 'AllowUsers value, empty means do not set' 'AllowUsers 值，留空表示不设置')" "")"
  disable_password="$(input_default "$(m 'Disable password login? yes/no' '关闭密码登录？yes/no')" "no")"
  permit_root="$(input_default "PermitRootLogin" "prohibit-password")"
  strict_forwarding="$(input_default "$(m 'Disable Agent/X11/Tunnel/Gateway forwarding? yes/no' '关闭 Agent/X11/Tunnel/Gateway 转发？yes/no')" "yes")"
  allow_tcp="$(input_default "$(m 'Allow TCP forwarding for ssh -L/-R/-D? yes/no' '允许 TCP 转发用于 ssh -L/-R/-D？yes/no')" "yes")"

  backup_path /etc/ssh/sshd_config >/dev/null || true
  mkdir -p /etc/ssh/sshd_config.d
  backup_path /etc/ssh/sshd_config.d/00-vps-init-hardening.conf >/dev/null || true

  cat > /etc/ssh/sshd_config.d/00-vps-init-hardening.conf <<EOF2
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
  if [ "$disable_password" = "yes" ]; then
    cat >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf <<'EOF2'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF2
  else
    cat >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf <<'EOF2'
PasswordAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF2
  fi
  if [ "$strict_forwarding" = "yes" ]; then
    cat >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf <<'EOF2'
X11Forwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
AllowStreamLocalForwarding no
EOF2
  fi
  if [ "$allow_tcp" = "yes" ]; then echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf; else echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf; fi
  [ -n "$allow_user" ] && echo "AllowUsers $allow_user" >> /etc/ssh/sshd_config.d/00-vps-init-hardening.conf

  if ! sshd -t; then
    red "$(m 'sshd config test failed. Removing new fragment.' 'sshd 配置检查失败，删除新片段。')"
    rm -f /etc/ssh/sshd_config.d/00-vps-init-hardening.conf
    sshd -t || true
    return 1
  fi

  if has_cmd ufw; then ufw allow "$port/tcp" comment "SSH" || true; fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  green "$(m "SSH config applied. Keep current session open and test: ssh -p $port <user>@<ip>" "SSH 配置已应用。不要关闭当前窗口，请另开终端测试：ssh -p $port <user>@<ip>")"
  ssh_audit
}

ssh_restore_fragment() {
  confirm_yes "$(m 'Remove SSH fragment written by this script?' '删除本脚本写入的 SSH 配置片段？')" || return 0
  rm -f /etc/ssh/sshd_config.d/00-vps-init-hardening.conf /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
  sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true)
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
  status_warn "$(m 'Admin panels such as 3x-ui should usually be restricted to your management IP/CIDR.' '3x-ui 等管理面板通常应限制为仅你的管理 IP/CIDR 可访问。')"
  status_info "$(m 'If using Cloudflare CDN for 80/443, add CF allow rules first, then manually remove broad 80/443 rules after verification.' '如果 80/443 使用 Cloudflare CDN，应先添加 CF 放行规则，确认后再手动删除宽泛 80/443 放行。')"
}

ufw_init_safe() {
  ufw_install
  local ssh_ports p
  ssh_ports="$(current_ssh_ports)"
  yellow "$(m "Will set: default deny incoming, allow outgoing, allow SSH port(s): $ssh_ports, then enable UFW." "将设置：默认拒绝入站、允许出站、放行 SSH 端口：$ssh_ports，然后启用 UFW。")"
  confirm_yes "$(m 'Enable UFW safely?' '安全启用 UFW？')" || return 0
  ufw default deny incoming
  ufw default allow outgoing
  for p in $ssh_ports; do ufw allow "$p/tcp" comment "SSH" || true; done
  ufw --force enable
  ufw status verbose
}

ufw_allow_port() {
  ufw_install
  local port proto comment
  port="$(input_default "$(m 'Port or range' '端口或范围')" "443")"
  proto="$(input_default "$(m 'Protocol tcp/udp' '协议 tcp/udp')" "tcp")"
  comment="$(input_default "$(m 'Comment' '备注')" "manual")"
  ufw allow "$port/$proto" comment "$comment"
  ufw status numbered
}

ufw_allow_ip_to_port() {
  ufw_install
  local ip port proto
  ip="$(input_default "$(m 'Allowed source IP/CIDR' '允许的来源 IP/CIDR')" "")"
  port="$(input_default "$(m 'Destination port' '目标端口')" "")"
  proto="$(input_default "$(m 'Protocol tcp/udp' '协议 tcp/udp')" "tcp")"
  [ -n "$ip" ] && [ -n "$port" ] || { red "$(m 'Source and port are required.' '来源和端口不能为空。')"; return 1; }
  ufw allow from "$ip" to any port "$port" proto "$proto" comment "restricted-$port"
  ufw status numbered
}

ufw_limit_ssh() {
  ufw_install
  local p
  for p in $(current_ssh_ports); do ufw limit "$p/tcp" comment "rate-limit-ssh" || true; done
  ufw status numbered
}

cf_fetch_ranges() {
  apt_install curl ca-certificates
  mkdir -p /var/lib/vps-init
  curl -fsSL "$CF_IPV4_URL" -o /var/lib/vps-init/cloudflare-ips-v4.txt.tmp
  curl -fsSL "$CF_IPV6_URL" -o /var/lib/vps-init/cloudflare-ips-v6.txt.tmp
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' /var/lib/vps-init/cloudflare-ips-v4.txt.tmp || { red "Invalid Cloudflare IPv4 list."; return 1; }
  grep -Eq ':' /var/lib/vps-init/cloudflare-ips-v6.txt.tmp || { red "Invalid Cloudflare IPv6 list."; return 1; }
  mv /var/lib/vps-init/cloudflare-ips-v4.txt.tmp /var/lib/vps-init/cloudflare-ips-v4.txt
  mv /var/lib/vps-init/cloudflare-ips-v6.txt.tmp /var/lib/vps-init/cloudflare-ips-v6.txt
}

ufw_allow_cloudflare_web() {
  ufw_install
  local ports p f cidr
  ports="$(input_default "$(m 'Ports to allow from Cloudflare only, comma-separated' '仅允许 Cloudflare 访问的端口，逗号分隔')" "80,443")"
  yellow "$(m 'This adds Cloudflare allow rules. It will NOT delete existing broad allow rules.' '这只会添加 Cloudflare 放行规则，不会删除现有宽泛放行规则。')"
  confirm_yes "$(m 'Continue?' '继续？')" || return 0
  cf_fetch_ranges
  for f in /var/lib/vps-init/cloudflare-ips-v4.txt /var/lib/vps-init/cloudflare-ips-v6.txt; do
    while read -r cidr; do
      [ -n "$cidr" ] || continue
      IFS=',' read -ra port_arr <<< "$ports"
      for p in "${port_arr[@]}"; do
        p="$(echo "$p" | xargs)"
        [ -n "$p" ] && ufw allow proto tcp from "$cidr" to any port "$p" comment "cloudflare-$p" || true
      done
    done < "$f"
  done
  ufw status numbered
  yellow "$(m 'Review and remove broad 80/443 allow rules manually if true Cloudflare-only mode is required.' '如果需要真正 Cloudflare-only，请检查后手动删除宽泛 80/443 放行。')"
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
  local active jails
  active="$(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
  jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
  kv "Service" "$active"
  kv "Jails" "${jails:-none}"
  if fail2ban-client status sshd >/tmp/vps-init-f2b-sshd.$$ 2>/dev/null; then
    status_ok "$(m 'sshd jail is active.' 'sshd jail 已启用。')"
    sed -n '1,20p' /tmp/vps-init-f2b-sshd.$$ | print_block
  else
    status_warn "$(m 'sshd jail is not active or not found.' 'sshd jail 未启用或未找到。')"
  fi
  rm -f /tmp/vps-init-f2b-sshd.$$
}

fail2ban_setup_sshd() {
  apt_install fail2ban
  mkdir -p /etc/fail2ban/jail.d
  backup_path /etc/fail2ban/jail.d/sshd-vps-init.local >/dev/null || true
  local bantime findtime maxretry ports
  bantime="$(input_default "bantime" "12h")"
  findtime="$(input_default "findtime" "10m")"
  maxretry="$(input_default "maxretry" "3")"
  ports="$(current_ssh_ports | tr ' ' ',')"
  cat > /etc/fail2ban/jail.d/sshd-vps-init.local <<EOF2
[sshd]
enabled = true
backend = systemd
port = $ports
filter = sshd
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
EOF2
  if has_cmd ufw; then echo "banaction = ufw" >> /etc/fail2ban/jail.d/sshd-vps-init.local; fi
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  fail2ban_audit
}

fail2ban_unban() {
  local jail ip
  jail="$(input_default "Jail" "sshd")"
  ip="$(input_default "$(m 'IP to unban' '要解封的 IP')" "")"
  [ -n "$ip" ] || return 1
  fail2ban-client set "$jail" unbanip "$ip" || true
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
  tmp="/tmp/vps-init-dig.$$.$RANDOM"
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

dns_apply_resolved() {
  local dns fallback
  is_systemd || { red "$(m 'systemd not detected.' '未检测到 systemd。')"; return 1; }
  systemctl list-unit-files | grep -q '^systemd-resolved.service' || { red "systemd-resolved not found."; return 1; }
  dns="$(input_default "$(m 'Primary DNS servers, space-separated' '主 DNS，空格分隔')" "1.1.1.1 8.8.8.8")"
  fallback="$(input_default "$(m 'Fallback DNS servers, space-separated' '备用 DNS，空格分隔')" "1.0.0.1 8.8.4.4")"
  confirm_yes "$(m 'Apply DNS via systemd-resolved?' '通过 systemd-resolved 应用 DNS？')" || return 0
  mkdir -p /etc/systemd/resolved.conf.d
  backup_path /etc/systemd/resolved.conf.d/10-vps-init-dns.conf >/dev/null || true
  cat > /etc/systemd/resolved.conf.d/10-vps-init-dns.conf <<EOF2
[Resolve]
DNS=$dns
FallbackDNS=$fallback
DNSSEC=no
Cache=yes
EOF2
  systemctl enable --now systemd-resolved
  systemctl restart systemd-resolved
  dns_audit
}

dns_apply_resolvconf() {
  local dns1 dns2
  dns1="$(input_default "nameserver 1" "1.1.1.1")"
  dns2="$(input_default "nameserver 2" "8.8.8.8")"
  yellow "$(m 'Direct /etc/resolv.conf edits may be overwritten by cloud-init, DHCP, NetworkManager, or systemd-resolved.' '直接修改 /etc/resolv.conf 可能被 cloud-init、DHCP、NetworkManager 或 systemd-resolved 覆盖。')"
  confirm_yes "$(m 'Edit /etc/resolv.conf directly?' '直接编辑 /etc/resolv.conf？')" || return 0
  backup_path /etc/resolv.conf >/dev/null || true
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
  system_max="$(input_default "SystemMaxUse" "200M")"
  runtime_max="$(input_default "RuntimeMaxUse" "100M")"
  retention="$(input_default "MaxRetentionSec" "7day")"
  mkdir -p /etc/systemd/journald.conf.d
  backup_path /etc/systemd/journald.conf.d/99-vps-init-size-limit.conf >/dev/null || true
  cat > /etc/systemd/journald.conf.d/99-vps-init-size-limit.conf <<EOF2
[Journal]
SystemMaxUse=$system_max
RuntimeMaxUse=$runtime_max
MaxRetentionSec=$retention
Compress=yes
EOF2
  systemctl restart systemd-journald || true
  journalctl --disk-usage || true
}

logs_vacuum() {
  is_systemd || { red "$(m 'systemd not detected.' '未检测到 systemd。')"; return 1; }
  local size
  size="$(input_default "$(m 'Vacuum journal down to size' '清理 journald 到指定大小')" "200M")"
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

# ---------- backup / baseline ----------
backup_3xui() {
  local out_dir tar_file
  out_dir="/root/3x-ui-backup-$(date +%F-%H%M%S)"
  tar_file="${out_dir}.tar.gz"
  mkdir -p "$out_dir"
  [ -f /etc/x-ui/x-ui.db ] && cp -a /etc/x-ui/x-ui.db "$out_dir/" || yellow "Missing /etc/x-ui/x-ui.db"
  [ -f /usr/local/x-ui/bin/1stream.dat ] && cp -a /usr/local/x-ui/bin/1stream.dat "$out_dir/" || yellow "Missing /usr/local/x-ui/bin/1stream.dat"
  [ -f /usr/local/x-ui/bin/config.json ] && cp -a /usr/local/x-ui/bin/config.json "$out_dir/" || true
  [ -d /usr/local/x-ui/bin ] && ls -lah /usr/local/x-ui/bin > "$out_dir/x-ui-bin-list.txt" 2>/dev/null || true
  find /root/.acme.sh /etc/letsencrypt /root/cert /etc/ssl -maxdepth 5 2>/dev/null \
    \( -name 'fullchain.cer' -o -name 'fullchain.pem' -o -name '*.key' -o -name 'privkey.pem' -o -name 'cert.pem' \) \
    -type f -print > "$out_dir/found-certs.txt" || true
  tar -czf "$tar_file" -C /root "$(basename "$out_dir")"
  green "$(m "3x-ui backup created: $tar_file" "3x-ui 备份已创建：$tar_file")"
  ls -lh "$tar_file"
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
  yellow "$(m 'Low-risk baseline includes: basic tools, BBR if supported, memory profile, proxy sysctl, nofile, journald limit.' '低风险基线包括：基础工具、BBR（如支持）、内存配置、代理 sysctl、nofile、journald 限额。')"
  yellow "$(m 'It does NOT change SSH, UFW, DNS, or Fail2ban.' '它不会修改 SSH、UFW、DNS 或 Fail2ban。')"
  confirm_yes "$(m 'Run low-risk baseline?' '执行低风险基线？')" || return 0
  install_basic_tools || true
  enable_bbr || true
  apply_memory_sysctl "$(recommend_swappiness)" "50" || true
  setup_swapfile || true
  setup_zram || true
  apply_proxy_sysctl || true
  raise_nofile_limits || true
  logs_limit_journald || true
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
    echo "13) $(m 'Backup 3x-ui + 1stream.dat' '备份 3x-ui + 1stream.dat')"
    echo "14) $(m 'Run low-risk baseline' '执行低风险基线')"
    echo "15) $(m 'List config backups' '列出配置备份')"
    echo "16) $(m 'Switch language' '切换语言')"
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
      13) backup_3xui; pause ;;
      14) low_risk_baseline; pause ;;
      15) list_backups; pause ;;
      16) language_menu; pause ;;
      0) exit 0 ;;
      *) yellow "$(m 'Invalid choice' '无效选项')"; pause ;;
    esac
  done
}

need_root
choose_language
require_debian_family
main_menu
