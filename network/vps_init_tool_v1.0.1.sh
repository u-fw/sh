#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.1"
SCRIPT_NAME="VPS Init Tool"
BACKUP_ROOT="/root/vps-init-backups"
SWAPFILE="/swapfile"
CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"

red() { printf '[BAD] %s\n' "$*"; }
green() { printf '[OK] %s\n' "$*"; }
yellow() { printf '[WARN] %s\n' "$*"; }
blue() { printf '%s\n' "$*"; }
muted() { printf '%s\n' "$*"; }

term_width() {
  local w
  w="$(tput cols 2>/dev/null || echo 88)"
  if [ "$w" -gt 120 ]; then w=120; fi
  if [ "$w" -lt 72 ]; then w=72; fi
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
  local k="$1"
  local v="${2:-}"
  printf '  %-28s %s\n' "$k" "$v"
}

status_ok() { printf '  %-8s %s\n' 'OK' "$*"; }
status_warn() { printf '  %-8s %s\n' 'WARN' "$*"; }
status_bad() { printf '  %-8s %s\n' 'BAD' "$*"; }
status_info() { printf '  %-8s %s\n' 'INFO' "$*"; }
print_block() { sed 's/^/    /'; }

pause() {
  echo
  read -r -p 'Press Enter to continue...' _ || true
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_systemd() {
  has_cmd systemctl && [ -d /run/systemd/system ]
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    red "Please run as root: sudo bash $0"
    exit 1
  fi
}

load_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    ID="unknown"
    PRETTY_NAME="unknown"
  fi
}

require_debian_family() {
  load_os_release
  case "${ID:-}" in
    debian|ubuntu)
      return 0
      ;;
    *)
      red "This script is intended for Debian/Ubuntu family systems. Detected: ${PRETTY_NAME:-unknown}"
      exit 1
      ;;
  esac
}

confirm_yes() {
  local prompt="$1"
  local ans
  echo
  yellow "$prompt"
  read -r -p 'Type YES to continue: ' ans || true
  [ "$ans" = 'YES' ]
}

input_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value || true
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

make_backup_dir() {
  mkdir -p "$BACKUP_ROOT"
}

backup_path() {
  local p="$1"
  local safe
  local dest
  [ -e "$p" ] || return 0
  make_backup_dir
  safe="$(echo "$p" | sed 's#/#_#g; s#^_##')"
  dest="$BACKUP_ROOT/${safe}.$(date +%F-%H%M%S).bak"
  cp -a "$p" "$dest"
  echo "Backup: $dest"
}

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

get_mem_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_root_avail_mb() {
  df -Pm / | awk 'NR==2 {print $4}'
}

recommend_swap_size() {
  local mem_mb
  local avail_mb
  local rec_mb
  local max_by_disk_mb
  mem_mb="$(get_mem_mb)"
  avail_mb="$(get_root_avail_mb)"
  max_by_disk_mb=$((avail_mb * 75 / 100))

  if [ "$mem_mb" -le 1024 ]; then
    rec_mb=1024
  elif [ "$mem_mb" -le 2048 ]; then
    rec_mb=2048
  elif [ "$mem_mb" -le 4096 ]; then
    rec_mb=2048
  elif [ "$mem_mb" -le 8192 ]; then
    rec_mb=4096
  else
    rec_mb=4096
  fi

  if [ "$max_by_disk_mb" -lt "$rec_mb" ]; then
    rec_mb="$max_by_disk_mb"
  fi
  if [ "$rec_mb" -lt 512 ]; then
    rec_mb=512
  fi
  echo "${rec_mb}M"
}

recommend_zram_size() {
  local mem_mb
  local rec_mb
  mem_mb="$(get_mem_mb)"
  if [ "$mem_mb" -le 1024 ]; then
    rec_mb=512
  elif [ "$mem_mb" -le 2048 ]; then
    rec_mb=1024
  elif [ "$mem_mb" -le 4096 ]; then
    rec_mb=1536
  elif [ "$mem_mb" -le 8192 ]; then
    rec_mb=2048
  else
    rec_mb=4096
  fi
  echo "${rec_mb}M"
}

recommend_swappiness() {
  local mem_mb
  mem_mb="$(get_mem_mb)"
  if [ "$mem_mb" -le 4096 ]; then
    echo 10
  else
    echo 1
  fi
}

parse_size_to_mb() {
  local s="$1"
  local n
  case "$s" in
    *G|*g)
      n="${s%G}"
      n="${n%g}"
      echo $((n * 1024))
      ;;
    *M|*m)
      n="${s%M}"
      n="${n%m}"
      echo "$n"
      ;;
    *)
      n="$(echo "$s" | tr -cd '0-9' | head -c 8)"
      echo "${n:-1024}"
      ;;
  esac
}

apply_memory_sysctl() {
  local swappiness="${1:-10}"
  local vfs_cache_pressure="${2:-50}"
  backup_path /etc/sysctl.d/99-memory-tuning.conf >/dev/null || true
  cat > /etc/sysctl.d/99-memory-tuning.conf <<EOF2
vm.swappiness=$swappiness
vm.vfs_cache_pressure=$vfs_cache_pressure
EOF2
  sysctl --system >/dev/null || true
}

install_basic_tools() {
  blue 'Installing basic tools...'
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
  green 'Basic tools installed.'
}

show_system_status() {
  load_os_release
  title 'System Status'
  kv 'Tool' "$SCRIPT_NAME $VERSION"
  kv 'OS' "${PRETTY_NAME:-unknown}"
  kv 'Kernel' "$(uname -r)"
  kv 'Arch' "$(uname -m)"
  kv 'Hostname' "$(hostname)"
  kv 'Systemd' "$(is_systemd && echo yes || echo no)"

  section 'Memory / Swap'
  free -h | print_block || true
  echo
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true

  section 'Disk'
  df -hT / | print_block || true

  section 'Network / BBR'
  kv 'tcp_congestion_control' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  kv 'default_qdisc' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  kv 'available algorithms' "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"

  section 'Listening ports'
  ss -tuln 2>/dev/null | awk 'NR==1 || NR<=40' | print_block || true
}

memory_report() {
  local mem_mb
  local swap_rec
  local zram_rec
  local swappiness_rec
  local swap_lines
  local zram_active
  mem_mb="$(get_mem_mb)"
  swap_rec="$(recommend_swap_size)"
  zram_rec="$(recommend_zram_size)"
  swappiness_rec="$(recommend_swappiness)"
  swap_lines="$(swapon --show --noheadings 2>/dev/null | wc -l | awk '{print $1}')"
  zram_active="$(swapon --show --noheadings 2>/dev/null | awk '$1 ~ /zram/ {print $1}' | paste -sd, -)"

  section 'Memory audit'
  kv 'RAM' "${mem_mb} MB"
  kv 'Current swappiness' "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
  kv 'Current vfs_cache_pressure' "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo unknown)"
  kv 'Active swap devices' "${swap_lines:-0}"
  kv 'Active ZRAM' "${zram_active:-none}"
  echo
  status_info "Recommended swapfile: $swap_rec"
  status_info "Recommended ZRAM: $zram_rec"
  status_info "Recommended swappiness: $swappiness_rec; vfs_cache_pressure: 50"
  echo
  muted '  Current free -h:'
  free -h | print_block || true
  echo
  muted '  Current swapon:'
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | print_block || swapon --show | print_block || true
  echo
  if [ "$mem_mb" -le 2048 ]; then
    status_warn 'Small VPS profile: ZRAM + swapfile is recommended.'
  elif [ "$mem_mb" -le 8192 ]; then
    status_info 'Medium VPS profile: swapfile recommended; ZRAM optional.'
  else
    status_info 'Large VPS profile: usually swapfile only; ZRAM optional.'
  fi
}

setup_swapfile() {
  local size
  local swappiness
  local vfs_cache_pressure
  local mb
  size="$(input_default 'Swapfile size; use 0 to skip' "$(recommend_swap_size)")"
  case "$size" in
    0|0M|0m|0G|0g)
      yellow 'Swapfile skipped.'
      return 0
      ;;
  esac
  swappiness="$(input_default 'vm.swappiness' "$(recommend_swappiness)")"
  vfs_cache_pressure="$(input_default 'vm.vfs_cache_pressure' '50')"

  blue "Configuring $SWAPFILE size=$size"
  if swapon --show | awk '{print $1}' | grep -qx "$SWAPFILE"; then
    yellow "$SWAPFILE is currently active. To recreate it, it must be swapoff first."
    confirm_yes "Recreate active $SWAPFILE?" || return 0
    swapoff "$SWAPFILE" || { red 'swapoff failed. Memory may be too tight. Aborting.'; return 1; }
  elif [ -e "$SWAPFILE" ]; then
    confirm_yes "$SWAPFILE exists and will be reformatted. Continue?" || return 0
  fi

  rm -f "$SWAPFILE"
  if has_cmd fallocate; then
    fallocate -l "$size" "$SWAPFILE" || true
  fi
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

  green 'Swapfile configured.'
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
  local size_expr
  local algo
  size_expr="$(input_default 'ZRAM size/expression, e.g. 512M / 2G / ram / 2 / min(ram / 2, 1024M)' "$(recommend_zram_size)")"
  algo="$(input_default 'Compression algorithm' 'zstd')"
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
    case "$size_hint_mb" in
      *M|*m)
        size_hint_mb="${size_hint_mb%M}"
        size_hint_mb="${size_hint_mb%m}"
        grep -q '^SIZE=' /etc/default/zramswap 2>/dev/null && sed -i "s/^#\?SIZE=.*/SIZE=${size_hint_mb}/" /etc/default/zramswap || echo "SIZE=${size_hint_mb}" >> /etc/default/zramswap
        ;;
      *)
        sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null || true
        ;;
    esac
    grep -q '^PRIORITY=' /etc/default/zramswap 2>/dev/null && sed -i 's/^#\?PRIORITY=.*/PRIORITY=100/' /etc/default/zramswap || echo 'PRIORITY=100' >> /etc/default/zramswap
  fi
  systemctl restart zramswap.service 2>/dev/null || systemctl restart zram-config.service 2>/dev/null || true
}

setup_zram_fallback() {
  local size
  local mb
  size="$(input_default 'ZRAM fallback size' "$(recommend_zram_size)")"
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
  local enable
  local size_hint
  enable="$(input_default 'Enable/configure ZRAM? yes/no' 'yes')"
  if [ "$enable" != 'yes' ]; then
    yellow 'ZRAM skipped.'
    return 0
  fi
  is_systemd || { red 'systemd not detected. ZRAM auto-start setup skipped.'; return 1; }
  zram_supported || { red 'ZRAM not supported by this kernel/VPS layer.'; return 1; }

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
  green 'ZRAM status:'
  free -h
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show
}

memory_optimize_menu() {
  while true; do
    clear
    blue '===== Memory / Swap / ZRAM ====='
    echo '1) Memory audit report'
    echo '2) Configure/Reconfigure swapfile'
    echo '3) Configure/Reconfigure ZRAM'
    echo '4) Apply VM sysctl only'
    echo '5) Apply full recommended memory profile'
    echo '0) Back'
    echo
    read -r -p 'Choose: ' c
    case "$c" in
      1) memory_report; pause ;;
      2) setup_swapfile; pause ;;
      3) setup_zram; pause ;;
      4)
        apply_memory_sysctl "$(input_default 'vm.swappiness' "$(recommend_swappiness)")" "$(input_default 'vm.vfs_cache_pressure' '50')"
        green 'VM memory sysctl applied.'
        pause
        ;;
      5)
        memory_report
        confirm_yes 'Apply recommended memory profile?' || { pause; continue; }
        apply_memory_sysctl "$(recommend_swappiness)" '50'
        setup_swapfile
        setup_zram
        pause
        ;;
      0) return ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

enable_bbr() {
  blue 'Enabling BBR if supported...'
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    red 'BBR is not supported or is blocked by the virtualization layer.'
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
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF2
  sysctl --system >/dev/null || true
  green 'Proxy sysctl tuning applied.'
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
  green 'nofile limits written. Reboot or restart services for full effect.'
}

current_ssh_port_guess() {
  local p
  if has_cmd sshd; then
    p="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
  else
    p=''
  fi
  echo "${p:-22}"
}

ssh_audit() {
  section 'SSH audit'
  if ! has_cmd sshd; then
    status_bad 'sshd not found.'
    return 1
  fi
  local port pass root pub maxauth maxsessions maxstartups grace forwarding x11
  port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  pass="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2; exit}')"
  root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}')"
  pub="$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication / {print $2; exit}')"
  maxauth="$(sshd -T 2>/dev/null | awk '/^maxauthtries / {print $2; exit}')"
  maxsessions="$(sshd -T 2>/dev/null | awk '/^maxsessions / {print $2; exit}')"
  maxstartups="$(sshd -T 2>/dev/null | awk '/^maxstartups / {print $2; exit}')"
  grace="$(sshd -T 2>/dev/null | awk '/^logingracetime / {print $2; exit}')"
  forwarding="$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding / {print $2; exit}')"
  x11="$(sshd -T 2>/dev/null | awk '/^x11forwarding / {print $2; exit}')"

  kv 'Port' "${port:-unknown}"
  kv 'PubkeyAuthentication' "${pub:-unknown}"
  kv 'PasswordAuthentication' "${pass:-unknown}"
  kv 'PermitRootLogin' "${root:-unknown}"
  kv 'MaxAuthTries' "${maxauth:-unknown}"
  kv 'MaxSessions' "${maxsessions:-unknown}"
  kv 'MaxStartups' "${maxstartups:-unknown}"
  kv 'LoginGraceTime' "${grace:-unknown}"
  kv 'AllowTcpForwarding' "${forwarding:-unknown}"
  kv 'X11Forwarding' "${x11:-unknown}"
  echo
  if [ "$pub" = 'yes' ]; then status_ok 'Public-key authentication is enabled.'; else status_bad 'PubkeyAuthentication is not enabled.'; fi
  if [ "$pass" = 'yes' ]; then status_warn 'Password login is enabled. Add/verify keys before disabling it.'; else status_ok 'Password login is disabled.'; fi
  if [ "$root" = 'yes' ]; then status_warn 'Root login is fully allowed. Prefer prohibit-password or a sudo user.'; else status_ok "Root login policy is not fully open: $root."; fi
  if [ "$port" = '22' ]; then status_warn 'SSH uses port 22. Acceptable, but noisy; Fail2ban/key-only is important.'; else status_info "SSH uses a non-default port: $port."; fi
  case "$maxauth" in
    1|2|3) status_ok 'MaxAuthTries is strict enough.' ;;
    *) status_warn 'Consider MaxAuthTries 3.' ;;
  esac
}

ssh_install_key() {
  local user key home auth
  user="$(input_default 'Target user' 'root')"
  read -r -p 'Paste SSH public key: ' key || true
  [ -n "$key" ] || { red 'Empty key.'; return 1; }
  if [ "$user" = 'root' ]; then
    home='/root'
  else
    home="$(getent passwd "$user" | cut -d: -f6)"
  fi
  [ -d "$home" ] || { red "User home not found: $home"; return 1; }
  mkdir -p "$home/.ssh"
  auth="$home/.ssh/authorized_keys"
  touch "$auth"
  chmod 700 "$home/.ssh"
  chmod 600 "$auth"
  grep -qxF "$key" "$auth" || echo "$key" >> "$auth"
  chown -R "$user:$user" "$home/.ssh" 2>/dev/null || true
  green "Public key installed for $user."
}

ssh_write_hardening() {
  local port allow_user disable_password permit_root strict_forwarding
  port="$(input_default 'New SSH port' "$(current_ssh_port_guess)")"
  allow_user="$(input_default 'AllowUsers value, empty means do not set' '')"
  disable_password="$(input_default 'Disable password login? yes/no' 'no')"
  permit_root="$(input_default 'PermitRootLogin value' 'prohibit-password')"
  strict_forwarding="$(input_default 'Disable SSH forwarding/X11/tunnel features? yes/no' 'no')"

  backup_path /etc/ssh/sshd_config >/dev/null || true
  mkdir -p /etc/ssh/sshd_config.d
  backup_path /etc/ssh/sshd_config.d/99-vps-init-hardening.conf >/dev/null || true

  cat > /etc/ssh/sshd_config.d/99-vps-init-hardening.conf <<EOF2
# Managed by $SCRIPT_NAME $VERSION
Port $port
PubkeyAuthentication yes
PermitRootLogin $permit_root
MaxAuthTries 3
MaxSessions 3
MaxStartups 10:30:60
LoginGraceTime 30
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF2
  if [ "$disable_password" = 'yes' ]; then
    cat >> /etc/ssh/sshd_config.d/99-vps-init-hardening.conf <<'EOF2'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF2
  else
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
  fi
  if [ "$strict_forwarding" = 'yes' ]; then
    cat >> /etc/ssh/sshd_config.d/99-vps-init-hardening.conf <<'EOF2'
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
AllowStreamLocalForwarding no
EOF2
  fi
  [ -n "$allow_user" ] && echo "AllowUsers $allow_user" >> /etc/ssh/sshd_config.d/99-vps-init-hardening.conf

  if ! sshd -t; then
    red 'sshd config test failed. Removing new fragment.'
    rm -f /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
    sshd -t || true
    return 1
  fi

  if has_cmd ufw; then
    ufw allow "$port/tcp" comment 'SSH' || true
  fi

  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  green "SSH config applied. Keep current session open and test a new login: ssh -p $port <user>@<ip>"
  ssh_audit
}

ssh_restore_fragment() {
  confirm_yes 'Remove SSH fragment written by this script?' || return 0
  rm -f /etc/ssh/sshd_config.d/99-vps-init-hardening.conf
  sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true)
  green 'SSH fragment removed.'
}

ssh_menu() {
  while true; do
    clear
    blue '===== SSH ====='
    echo '1) SSH audit'
    echo '2) Install public key'
    echo '3) Configure SSH hardening fragment'
    echo '4) Restore/remove hardening fragment'
    echo '0) Back'
    read -r -p 'Choose: ' c
    case "$c" in
      1) ssh_audit; pause ;;
      2) ssh_install_key; pause ;;
      3) ssh_write_hardening; pause ;;
      4) ssh_restore_fragment; pause ;;
      0) return ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

ufw_install() {
  apt_install ufw
  green 'UFW installed.'
}

ufw_audit() {
  section 'Firewall audit'
  local ssh_port ufw_state
  ssh_port="$(current_ssh_port_guess)"
  if ! has_cmd ufw; then
    status_warn 'UFW is not installed.'
  else
    ufw_state="$(ufw status 2>/dev/null | awk 'NR==1 {print $2}')"
    kv 'UFW status' "${ufw_state:-unknown}"
    if ufw status | grep -q inactive; then
      status_warn "UFW is inactive. Safe-init can allow SSH $ssh_port/tcp before enabling."
    else
      status_ok 'UFW is active.'
    fi
    echo
    muted '  UFW rules:'
    ufw status numbered 2>/dev/null | sed -n '1,25p' | print_block || true
  fi
  echo
  muted '  Listening TCP/UDP ports:'
  ss -tuln 2>/dev/null | awk 'NR==1 || NR<=35' | print_block || true
  echo
  status_info "Current SSH port guess: $ssh_port/tcp."
  status_warn 'Admin panels such as 3x-ui should usually be restricted to your management IP/CIDR.'
  status_info 'If using Cloudflare CDN for 80/443, add CF allow rules first, then manually remove broad 80/443 rules after verification.'
}

ufw_init_safe() {
  ufw_install
  local ssh_port
  ssh_port="$(current_ssh_port_guess)"
  yellow "Will set: default deny incoming, allow outgoing, allow SSH $ssh_port/tcp, then enable UFW."
  confirm_yes 'Enable UFW safely?' || return 0
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$ssh_port/tcp" comment 'SSH'
  ufw --force enable
  ufw status verbose
}

ufw_allow_port() {
  ufw_install
  local port proto comment
  port="$(input_default 'Port or range' '443')"
  proto="$(input_default 'Protocol tcp/udp' 'tcp')"
  comment="$(input_default 'Comment' 'manual')"
  ufw allow "$port/$proto" comment "$comment"
  ufw status numbered
}

ufw_allow_ip_to_port() {
  ufw_install
  local ip port proto
  ip="$(input_default 'Allowed source IP/CIDR' '')"
  port="$(input_default 'Destination port' '')"
  proto="$(input_default 'Protocol tcp/udp' 'tcp')"
  [ -n "$ip" ] && [ -n "$port" ] || { red 'Source and port are required.'; return 1; }
  ufw allow from "$ip" to any port "$port" proto "$proto" comment "restricted-$port"
  ufw status numbered
}

ufw_limit_ssh() {
  ufw_install
  local ssh_port
  ssh_port="$(current_ssh_port_guess)"
  ufw limit "$ssh_port/tcp" comment 'rate-limit-ssh'
  ufw status numbered
}

cf_fetch_ranges() {
  apt_install curl ca-certificates
  mkdir -p /var/lib/vps-init
  curl -fsSL "$CF_IPV4_URL" -o /var/lib/vps-init/cloudflare-ips-v4.txt.tmp
  curl -fsSL "$CF_IPV6_URL" -o /var/lib/vps-init/cloudflare-ips-v6.txt.tmp
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' /var/lib/vps-init/cloudflare-ips-v4.txt.tmp || { red 'Invalid Cloudflare IPv4 list.'; return 1; }
  grep -Eq ':' /var/lib/vps-init/cloudflare-ips-v6.txt.tmp || { red 'Invalid Cloudflare IPv6 list.'; return 1; }
  mv /var/lib/vps-init/cloudflare-ips-v4.txt.tmp /var/lib/vps-init/cloudflare-ips-v4.txt
  mv /var/lib/vps-init/cloudflare-ips-v6.txt.tmp /var/lib/vps-init/cloudflare-ips-v6.txt
}

ufw_allow_cloudflare_web() {
  ufw_install
  local ports p f cidr
  ports="$(input_default 'Ports to allow from Cloudflare only, comma-separated' '80,443')"
  yellow 'This adds Cloudflare allow rules. It will NOT delete existing broad allow rules.'
  confirm_yes 'Continue?' || return 0
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
  yellow 'Review and remove broad 80/443 allow rules manually if true Cloudflare-only mode is required.'
}

ufw_reset_safe() {
  confirm_yes 'Reset ALL UFW rules?' || return 0
  ufw --force reset
  green 'UFW reset.'
}

ufw_menu() {
  while true; do
    clear
    blue '===== UFW Firewall ====='
    echo '1) Firewall audit'
    echo '2) Install UFW'
    echo '3) Safe init UFW'
    echo '4) Allow custom port'
    echo '5) Allow only IP/CIDR to port'
    echo '6) Rate-limit SSH'
    echo '7) Add Cloudflare ranges to 80/443'
    echo '8) Reset UFW'
    echo '0) Back'
    read -r -p 'Choose: ' c
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
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

fail2ban_audit() {
  section 'Fail2ban audit'
  if ! has_cmd fail2ban-client; then
    status_warn 'Fail2ban is not installed.'
    return 0
  fi
  local active jails tmp
  active="$(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
  jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
  kv 'Service' "$active"
  kv 'Jails' "${jails:-none}"
  tmp="/tmp/vps-init-f2b-sshd.$$"
  if fail2ban-client status sshd >"$tmp" 2>/dev/null; then
    status_ok 'sshd jail is active.'
    sed -n '1,20p' "$tmp" | print_block
  else
    status_warn 'sshd jail is not active or not found.'
  fi
  rm -f "$tmp"
}

fail2ban_setup_sshd() {
  apt_install fail2ban
  mkdir -p /etc/fail2ban/jail.d
  backup_path /etc/fail2ban/jail.d/sshd-vps-init.local >/dev/null || true
  local bantime findtime maxretry
  bantime="$(input_default 'bantime' '12h')"
  findtime="$(input_default 'findtime' '10m')"
  maxretry="$(input_default 'maxretry' '3')"
  cat > /etc/fail2ban/jail.d/sshd-vps-init.local <<EOF2
[sshd]
enabled = true
backend = systemd
port = ssh
filter = sshd
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
EOF2
  if has_cmd ufw; then
    echo 'banaction = ufw' >> /etc/fail2ban/jail.d/sshd-vps-init.local
  fi
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  fail2ban_audit
}

fail2ban_unban() {
  local jail ip
  jail="$(input_default 'Jail' 'sshd')"
  ip="$(input_default 'IP to unban' '')"
  [ -n "$ip" ] || return 1
  fail2ban-client set "$jail" unbanip "$ip" || true
}

fail2ban_menu() {
  while true; do
    clear
    blue '===== Fail2ban ====='
    echo '1) Audit'
    echo '2) Install/configure sshd jail'
    echo '3) Unban IP'
    echo '0) Back'
    read -r -p 'Choose: ' c
    case "$c" in
      1) fail2ban_audit; pause ;;
      2) fail2ban_setup_sshd; pause ;;
      3) fail2ban_unban; pause ;;
      0) return ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

dns_audit() {
  section 'DNS audit'
  local target nameservers resolved_state
  target="$(readlink -f /etc/resolv.conf 2>/dev/null || echo plain-file)"
  nameservers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)"
  kv '/etc/resolv.conf' "$target"
  kv 'Nameservers' "${nameservers:-none}"
  if is_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved.service'; then
    resolved_state="$(systemctl is-active systemd-resolved 2>/dev/null || echo inactive)"
    kv 'systemd-resolved' "$resolved_state"
  else
    kv 'systemd-resolved' 'not detected'
  fi
  if grep -qi cloud-init /etc/resolv.conf 2>/dev/null; then
    status_warn '/etc/resolv.conf appears cloud-init managed; direct edits may be overwritten.'
  fi
  if has_cmd resolvectl; then
    echo
    muted '  resolvectl DNS servers:'
    resolvectl dns 2>/dev/null | print_block || true
  fi
  echo
  status_info 'Use DNS test before applying changes on production servers.'
}

dns_query_time_ms() {
  local server="$1"
  local name="$2"
  local start end tmp
  tmp="/tmp/vps-init-dig.$$.$RANDOM"
  start="$(date +%s%3N)"
  if timeout 3 dig +time=2 +tries=1 +short "@$server" "$name" A >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    end="$(date +%s%3N)"
    rm -f "$tmp"
    echo $((end - start))
  else
    rm -f "$tmp"
    echo 'fail'
  fi
}

dns_test() {
  apt_install dnsutils
  local servers names s n t total count fail avg
  servers='1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220'
  names='google.com cloudflare.com github.com debian.org'
  printf '%-18s %-10s %-10s\n' 'DNS' 'AVG(ms)' 'FAILS'
  for s in $servers; do
    total=0
    count=0
    fail=0
    for n in $names; do
      t="$(dns_query_time_ms "$s" "$n")"
      if [ "$t" = 'fail' ]; then
        fail=$((fail + 1))
      else
        total=$((total + t))
        count=$((count + 1))
      fi
    done
    if [ "$count" -gt 0 ]; then avg=$((total / count)); else avg='fail'; fi
    printf '%-18s %-10s %-10s\n' "$s" "$avg" "$fail"
  done
}

dns_apply_resolved() {
  local dns fallback
  is_systemd || { red 'systemd not detected.'; return 1; }
  systemctl list-unit-files | grep -q '^systemd-resolved.service' || { red 'systemd-resolved not found.'; return 1; }
  dns="$(input_default 'Primary DNS servers, space-separated' '1.1.1.1 8.8.8.8')"
  fallback="$(input_default 'Fallback DNS servers, space-separated' '1.0.0.1 8.8.4.4')"
  confirm_yes 'Apply DNS via systemd-resolved?' || return 0
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
  dns1="$(input_default 'nameserver 1' '1.1.1.1')"
  dns2="$(input_default 'nameserver 2' '8.8.8.8')"
  yellow 'Direct /etc/resolv.conf edits may be overwritten by cloud-init, DHCP, NetworkManager, or systemd-resolved.'
  confirm_yes 'Edit /etc/resolv.conf directly?' || return 0
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
    clear
    blue '===== DNS ====='
    echo '1) DNS audit'
    echo '2) Test common public resolvers'
    echo '3) Apply via systemd-resolved'
    echo '4) Apply by direct /etc/resolv.conf edit'
    echo '0) Back'
    read -r -p 'Choose: ' c
    case "$c" in
      1) dns_audit; pause ;;
      2) dns_test; pause ;;
      3) dns_apply_resolved; pause ;;
      4) dns_apply_resolvconf; pause ;;
      0) return ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

logs_audit() {
  section 'Logs audit'
  local journal_usage varlog_size
  if is_systemd; then
    journal_usage="$(journalctl --disk-usage 2>/dev/null | sed 's/^/ /')"
    kv 'journald usage' "${journal_usage:-unknown}"
    if [ -f /etc/systemd/journald.conf.d/99-vps-init-size-limit.conf ]; then
      status_ok 'vps-init journald size limit is configured.'
    else
      status_warn 'No vps-init journald limit found. Consider setting SystemMaxUse.'
    fi
  else
    status_warn 'systemd not detected; journald audit skipped.'
  fi
  varlog_size="$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
  kv '/var/log size' "${varlog_size:-unknown}"
  echo
  muted '  Largest /var/log entries:'
  du -ah /var/log 2>/dev/null | sort -hr | head -8 | print_block || true
}

logs_limit_journald() {
  is_systemd || { red 'systemd not detected.'; return 1; }
  local system_max runtime_max retention
  system_max="$(input_default 'SystemMaxUse' '200M')"
  runtime_max="$(input_default 'RuntimeMaxUse' '100M')"
  retention="$(input_default 'MaxRetentionSec' '7day')"
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
  is_systemd || { red 'systemd not detected.'; return 1; }
  local size
  size="$(input_default 'Vacuum journal down to size' '200M')"
  confirm_yes "Vacuum journald logs to $size?" || return 0
  journalctl --vacuum-size="$size"
  journalctl --disk-usage || true
}

logs_menu() {
  while true; do
    clear
    blue '===== Logs ====='
    echo '1) Logs audit'
    echo '2) Limit journald size'
    echo '3) Vacuum journald now'
    echo '0) Back'
    read -r -p 'Choose: ' c
    case "$c" in
      1) logs_audit; pause ;;
      2) logs_limit_journald; pause ;;
      3) logs_vacuum; pause ;;
      0) return ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

backup_3xui() {
  local out_dir tar_file
  out_dir="/root/3x-ui-backup-$(date +%F-%H%M%S)"
  tar_file="${out_dir}.tar.gz"
  mkdir -p "$out_dir"
  [ -f /etc/x-ui/x-ui.db ] && cp -a /etc/x-ui/x-ui.db "$out_dir/" || yellow 'Missing /etc/x-ui/x-ui.db'
  [ -f /usr/local/x-ui/bin/1stream.dat ] && cp -a /usr/local/x-ui/bin/1stream.dat "$out_dir/" || yellow 'Missing /usr/local/x-ui/bin/1stream.dat'
  [ -f /usr/local/x-ui/bin/config.json ] && cp -a /usr/local/x-ui/bin/config.json "$out_dir/" || true
  [ -d /usr/local/x-ui/bin ] && ls -lah /usr/local/x-ui/bin > "$out_dir/x-ui-bin-list.txt" 2>/dev/null || true
  find /root/.acme.sh /etc/letsencrypt /root/cert /etc/ssl 2>/dev/null \
    \( -name 'fullchain.cer' -o -name 'fullchain.pem' -o -name '*.key' -o -name 'privkey.pem' -o -name 'cert.pem' \) \
    -maxdepth 5 -type f -print > "$out_dir/found-certs.txt" || true
  tar -czf "$tar_file" -C /root "$(basename "$out_dir")"
  green "3x-ui backup created: $tar_file"
  ls -lh "$tar_file"
}

audit_all() {
  clear
  title 'Full Environment Audit'
  load_os_release
  kv 'Time' "$(date '+%F %T %Z')"
  kv 'Host' "$(hostname)"
  kv 'OS' "${PRETTY_NAME:-unknown}"
  kv 'Kernel' "$(uname -r)"
  kv 'Arch' "$(uname -m)"
  memory_report
  ssh_audit || true
  ufw_audit || true
  fail2ban_audit || true
  dns_audit || true
  logs_audit || true
  section 'Summary'
  status_info 'Audit mode is read-only. No settings were changed.'
  status_info 'Use individual module menus to apply changes with confirmation.'
}

low_risk_baseline() {
  yellow 'Low-risk baseline includes: basic tools, BBR if supported, memory profile, proxy sysctl, nofile, journald limit.'
  yellow 'It does NOT change SSH, UFW, DNS, or Fail2ban.'
  confirm_yes 'Run low-risk baseline?' || return 0
  install_basic_tools || true
  enable_bbr || true
  apply_memory_sysctl "$(recommend_swappiness)" '50' || true
  setup_swapfile || true
  setup_zram || true
  apply_proxy_sysctl || true
  raise_nofile_limits || true
  logs_limit_journald || true
  green 'Baseline complete. Reboot is recommended.'
}

list_backups() {
  make_backup_dir
  find "$BACKUP_ROOT" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
}

main_menu() {
  while true; do
    clear
    blue "===== $SCRIPT_NAME $VERSION ====="
    echo '1) Full environment audit'
    echo '2) System status'
    echo '3) Memory / Swap / ZRAM'
    echo '4) SSH'
    echo '5) UFW Firewall / Cloudflare ranges'
    echo '6) Fail2ban'
    echo '7) DNS'
    echo '8) Logs / journald'
    echo '9) Enable BBR'
    echo '10) Proxy sysctl tuning'
    echo '11) Raise nofile limits'
    echo '12) Install basic tools'
    echo '13) Backup 3x-ui + 1stream.dat'
    echo '14) Run low-risk baseline'
    echo '15) List config backups'
    echo '0) Exit'
    echo
    read -r -p 'Choose: ' c
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
      0) exit 0 ;;
      *) yellow 'Invalid choice'; pause ;;
    esac
  done
}

need_root
require_debian_family
main_menu
