#!/usr/bin/env bash
# freedom.sh v10.2-xray
# VLESS + REALITY-VISION / XHTTP-TLS-VISION 自动配置脚本
# - 专精 Xray-core；未安装时可使用 XTLS 官方安装脚本安装
# - Xray-core: xray x25519 / uuid / vlessenc / mldsa65 / run -test
# - CN/private 阻断默认启用；未命中规则的流量走默认 direct 出站
# - 二维码默认不生成，最后按需生成，避免长链接导致 qrencode 报错
# - 启动前检测端口占用；非 xray 进程占用时明确报错
# - 写入配置前自动备份；非交互失败自动回滚，首次部署失败自动清理
# - 隐藏服务端私钥等敏感输出；公网 IP 优先使用 api.ip.sb/ip
# - 端口占用报错会明确显示进程名、PID 与监听地址
# - ML-DSA pqv 链接参数做 URL 编码；自动补齐 ss/iproute2 端口检测依赖

set -Eeuo pipefail
umask 077

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_VERSION="v10.2-xray"
DEFAULT_SNI="v1-dy.ixigua.com"
DEFAULT_PORT="443"
DEFAULT_NODE_NAME="Premium-Node"

BIN=""
SERVICE_NAME=""
CONFIG_PATH=""
CONFIG_DIR=""

PORT=""
SNI=""
SERVER_IP=""
SERVER_HOST_FOR_LINK=""
UUID=""
SHORT_ID=""
REALITY_PRIV=""
REALITY_PUB=""
VLESS_DEC="none"
VLESS_ENC="none"
MLDSA_SEED=""
MLDSA_VERIFY=""
MLDSA_LINK_PARAM=""
SPIDER_X=""
NODE_NAME=""
BACKUP_FILE=""
CONFIG_WRITTEN_THIS_RUN=0
ASSUME_YES="${FREEDOM_YES:-0}"
NONINTERACTIVE=0
NO_QR="${FREEDOM_NO_QR:-0}"
CHECK_ONLY=0
CLI_PORT="${FREEDOM_PORT:-}"
CLI_SNI="${FREEDOM_SNI:-}"
CLI_NODE_NAME="${FREEDOM_NODE_NAME:-}"
CLI_SERVER="${FREEDOM_SERVER:-}"
XRAY_ENCRYPTION_CHOICE="${FREEDOM_XRAY_ENCRYPTION:-x25519}"
ENABLE_MLDSA="${FREEDOM_MLDSA:-0}"
SNI_CHECK="${FREEDOM_SNI_CHECK:-1}"
SNI_CHECK_TIMEOUT="${FREEDOM_SNI_CHECK_TIMEOUT:-8}"
ASN_CHECK="${FREEDOM_ASN_CHECK:-1}"
ALLOW_NONSTANDARD_REALITY_PORT="${FREEDOM_ALLOW_NONSTANDARD_REALITY_PORT:-0}"
UPDATE_XRAY="${FREEDOM_UPDATE_XRAY:-0}"
LAST_SNI_REMOTE_IP=""
DEPLOY_MODE="${FREEDOM_MODE:-reality}"
TLS_CERT_MODE="${FREEDOM_TLS_CERT_MODE:-public}"
TLS_CERT_FILE="${FREEDOM_TLS_CERT_FILE:-}"
TLS_KEY_FILE="${FREEDOM_TLS_KEY_FILE:-}"
XHTTP_PATH="${FREEDOM_XHTTP_PATH:-}"
XHTTP_TRANSPORT_PROFILE="${FREEDOM_XHTTP_PROFILE:-${FREEDOM_XHTTP_ALPN:-cdn-stable}}"
XHTTP_ORIGIN_ALPN_JSON='["h2","http/1.1"]'
XHTTP_CLIENT_ALPN_JSON='["h2","http/1.1"]'
ROUTE_PROFILE="${FREEDOM_ROUTE_PROFILE:-compatible}"

info() { echo -e "${CYAN}[INFO] $*${NC}"; }
ok() { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
fatal() { echo -e "${RED}[ERROR] $*${NC}" >&2; exit 1; }

usage_error() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
  echo "Use --help to view usage." >&2
  exit 2
}

require_option_value() {
  local opt="$1" value="${2:-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    usage_error "Missing value for $opt"
  fi
}

normalize_deploy_mode() {
  case "${1:-}" in
    1|reality|REALITY|reality-vision|REALITY-VISION|raw-reality|RAW-REALITY|raw-reality-vision|RAW-REALITY-VISION|vision|VISION)
      printf '%s\n' "reality"
      ;;
    2|cdn|CDN|xhttp|XHTTP|xhttp-tls|XHTTP-TLS|xhttp-tls-vision|XHTTP-TLS-VISION|cdn-xhttp-tls|CDN-XHTTP-TLS)
      printf '%s\n' "cdn-xhttp-tls"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_xhttp_path() {
  local path="$1"
  [[ -n "$path" && ${#path} -le 128 ]] || return 1
  [[ "$path" == /* && "$path" != "/" ]] || return 1
  [[ "$path" != *" "* && "$path" != *"?"* && "$path" != *"#"* ]] || return 1
  [[ "$path" =~ ^/[A-Za-z0-9._~/%-]+$ ]] || return 1
}

xhttp_origin_alpn_json() {
  local choice
  choice="$(normalize_xhttp_transport_profile "${1:-cdn-stable}")" || return 1
  case "$choice" in
    cdn-stable|cdn-h3)
      printf '%s\n' '["h2","http/1.1"]'
      ;;
    cdn-h2)
      printf '%s\n' '["h2"]'
      ;;
    direct-h3)
      printf '%s\n' '["h3"]'
      ;;
    *)
      return 1
      ;;
  esac
}

xhttp_client_alpn_json() {
  local choice
  choice="$(normalize_xhttp_transport_profile "${1:-cdn-stable}")" || return 1
  case "$choice" in
    cdn-stable)
      printf '%s\n' '["h2","http/1.1"]'
      ;;
    cdn-h2)
      printf '%s\n' '["h2"]'
      ;;
    cdn-h3|direct-h3)
      printf '%s\n' '["h3"]'
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_xhttp_transport_profile() {
  case "${1:-cdn-stable}" in
    1|stable|STABLE|cdn-stable|CDN-STABLE|h2-http1|H2-HTTP1|h2,http/1.1)
      printf '%s\n' "cdn-stable"
      ;;
    2|h2|H2|h2-only|H2-ONLY|cdn-h2|CDN-H2)
      printf '%s\n' "cdn-h2"
      ;;
    3|cdn-h3|CDN-H3|edge-h3|EDGE-H3)
      printf '%s\n' "cdn-h3"
      ;;
    4|h3|H3|h3-only|H3-ONLY|quic|QUIC|direct-h3|DIRECT-H3)
      printf '%s\n' "direct-h3"
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_route_profile() {
  case "${1:-compatible}" in
    1|compatible|COMPATIBLE|asis|AsIs|ASIS)
      printf '%s\n' "compatible"
      ;;
    2|strict|STRICT|ip-if-non-match|IPIfNonMatch|ipifnonmatch)
      printf '%s\n' "strict"
      ;;
    *)
      return 1
      ;;
  esac
}

routing_domain_strategy() {
  case "$(normalize_route_profile "${1:-compatible}")" in
    compatible) printf '%s\n' "AsIs" ;;
    strict) printf '%s\n' "IPIfNonMatch" ;;
  esac
}

cloudflare_https_port_supported() {
  case "${1:-}" in
    443|2053|2083|2087|2096|8443) return 0 ;;
    *) return 1 ;;
  esac
}

flag_enabled() {
  case "${1:-0}" in
    1|yes|YES|true|TRUE|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

reality_port_is_standard() {
  [[ "${1:-}" == "443" ]]
}

enforce_reality_port_policy() {
  [[ "${DEPLOY_MODE:-reality}" == "reality" ]] || return 0
  reality_port_is_standard "$PORT" && return 0
  warn "REALITY is expected to listen on TCP/443 so its destination port matches normal HTTPS traffic."
  warn "Selected non-standard REALITY port: ${PORT}"
  if flag_enabled "$ALLOW_NONSTANDARD_REALITY_PORT"; then
    warn "Explicit non-standard REALITY port override accepted."
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    fatal "Non-standard REALITY ports require --allow-nonstandard-reality-port."
  fi
  confirm_yes_default_no "Continue with REALITY on non-standard port ${PORT}?" \
    || fatal "Cancelled. Use TCP/443 for REALITY or choose XHTTP-TLS for supported CDN HTTPS ports."
  ALLOW_NONSTANDARD_REALITY_PORT=1
}

validate_tls_cert_mode() {
  normalize_tls_cert_mode "${1:-public}" >/dev/null
}

normalize_tls_cert_mode() {
  case "${1:-public}" in
    1|public|PUBLIC|public-ca|PUBLIC-CA)
      printf '%s\n' "public"
      ;;
    2|cloudflare|CLOUDFLARE|cloudflare-origin|CLOUDFLARE-ORIGIN|cloudflare-origin-ca|CLOUDFLARE-ORIGIN-CA|cf|CF|cf-origin|CF-ORIGIN)
      printf '%s\n' "cloudflare-origin"
      ;;
    *)
      return 1
      ;;
  esac
}

cert_covers_domain() {
  local cert_file="$1" domain="$2"
  openssl x509 -in "$cert_file" -noout -checkhost "$domain" >/dev/null 2>&1
}

check_tls_cert_files() {
  local domain="${1:-${SNI:-}}" cert_pub key_pub
  command -v openssl >/dev/null 2>&1 || { warn "openssl is required to validate TLS certificate files."; return 1; }
  [[ -n "$domain" ]] || { warn "TLS certificate validation requires a non-empty SNI domain."; return 1; }
  [[ -r "$TLS_CERT_FILE" ]] || { warn "TLS certificate file not readable: $TLS_CERT_FILE"; return 1; }
  [[ -r "$TLS_KEY_FILE" ]] || { warn "TLS private key file not readable: $TLS_KEY_FILE"; return 1; }
  openssl x509 -in "$TLS_CERT_FILE" -noout >/dev/null 2>&1 || { warn "Invalid TLS certificate file: $TLS_CERT_FILE"; return 1; }
  openssl pkey -in "$TLS_KEY_FILE" -noout >/dev/null 2>&1 || { warn "Invalid TLS private key file: $TLS_KEY_FILE"; return 1; }
  openssl x509 -checkend 0 -noout -in "$TLS_CERT_FILE" >/dev/null 2>&1 || { warn "TLS certificate is expired: $TLS_CERT_FILE"; return 1; }
  openssl x509 -checkend 1209600 -noout -in "$TLS_CERT_FILE" >/dev/null 2>&1 || warn "TLS certificate expires within 14 days: $TLS_CERT_FILE"
  cert_pub="$(openssl x509 -in "$TLS_CERT_FILE" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  key_pub="$(openssl pkey -in "$TLS_KEY_FILE" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  [[ -n "$cert_pub" && -n "$key_pub" && "$cert_pub" == "$key_pub" ]] || { warn "TLS private key does not match certificate"; return 1; }
  cert_covers_domain "$TLS_CERT_FILE" "$domain" || { warn "TLS certificate does not cover SNI domain: $domain"; return 1; }
  if [[ "${TLS_CERT_MODE:-public}" == "public" ]]; then
    openssl verify -purpose sslserver -verify_hostname "$domain" -untrusted "$TLS_CERT_FILE" "$TLS_CERT_FILE" >/dev/null 2>&1 \
      || { warn "Public TLS certificate chain is not trusted or incomplete: $TLS_CERT_FILE"; return 1; }
  fi
}

validate_tls_cert_files() {
  check_tls_cert_files "$SNI" || fatal "TLS certificate validation failed"
  check_tls_files_service_readable || fatal "Xray service cannot read the configured TLS certificate/key"
}

warn_cloudflare_origin_ca_scope() {
  warn "Cloudflare Origin CA requires Cloudflare proxy with Full(strict); direct clients and browsers will not trust this certificate."
  warn "Restrict origin access to Cloudflare IP ranges; do not expose this certificate endpoint directly to the Internet."
}

warn_reality_target_scope() {
  warn "REALITY forwards authentication failures to its target. Prefer a stable TLS 1.3 site in the same ASN that you trust/control."
  warn "Avoid generic CDN targets whose upstream can be selected or abused as an open forwarding destination."
}

clear_screen() {
  [[ "${NONINTERACTIVE:-0}" == "1" ]] && return 0
  clear 2>/dev/null || true
}

is_auto_yes() {
  case "${ASSUME_YES:-0}" in
    1|yes|YES|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

input_default() {
  local prompt="$1" default="$2" value
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  read -r -p "$prompt [$default]: " value || true
  printf '%s\n' "${value:-$default}"
}

confirm_yes_default_yes() {
  local prompt="$1" ans=""
  if is_auto_yes || [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "$prompt [Y/n]: " ans || true
  case "${ans:-Y}" in
    n|N|no|NO) return 1 ;;
    *) return 0 ;;
  esac
}

confirm_yes_default_no() {
  local prompt="$1" ans=""
  if is_auto_yes; then
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    return 1
  fi
  read -r -p "$prompt [y/N]: " ans || true
  case "${ans:-N}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_systemd_available() {
  command -v systemctl >/dev/null 2>&1 || fatal "未找到 systemctl；此脚本需要 systemd 管理 xray 服务。"
  if ! systemctl list-units --type=service >/dev/null 2>&1; then
    fatal "当前环境无法使用 systemd。若在容器内运行，请改用支持 systemd 的 VPS/宿主机环境。"
  fi
}

redact_sensitive_text() {
  # 仅用于错误诊断输出，避免在终端直接暴露服务端私钥/种子。
  sed -E \
    -e 's/^([[:space:]]*(PrivateKey|Private key|Private)[^:]*:[[:space:]]*).*/\1<redacted>/I' \
    -e 's/^([[:space:]]*(Seed)[^:]*:[[:space:]]*).*/\1<redacted>/I' \
    -e 's/("(decryption|encryption|privateKey|mldsa65Seed)"[[:space:]]*:[[:space:]]*")[^"]+"/\1<redacted>"/I'
}

service_unit_exists() {
  local svc="$1"
  systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service" \
    || systemctl list-units --all --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"
}

xray_service_user() {
  local user=""
  command -v systemctl >/dev/null 2>&1 || { printf '%s\n' root; return 0; }
  user="$(systemctl show "${SERVICE_NAME:-xray}" -p User --value 2>/dev/null || true)"
  printf '%s\n' "${user:-root}"
}

service_user_can_read() {
  local user="$1" path="$2"
  if [[ "$user" == "root" ]]; then
    [[ -r "$path" ]]
  elif [[ "$(id -u)" == "0" ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- test -r "$path"
  elif [[ "$(id -un 2>/dev/null || true)" == "$user" ]]; then
    [[ -r "$path" ]]
  else
    return 2
  fi
}

check_tls_files_service_readable() {
  local user rc=0 path
  command -v systemctl >/dev/null 2>&1 || return 0
  service_unit_exists "${SERVICE_NAME:-xray}" || return 0
  user="$(xray_service_user)"
  for path in "$TLS_CERT_FILE" "$TLS_KEY_FILE"; do
    if service_user_can_read "$user" "$path"; then
      continue
    else
      rc=$?
    fi
    if [[ "$rc" -eq 2 ]]; then
      warn "Cannot verify TLS file access as service user ${user} without root privileges: $path"
      continue
    fi
    warn "Xray service user ${user} cannot read: $path"
    warn "Grant only that service account/group read and parent-directory traverse access; do not make the private key world-readable."
    return 1
  done
  ok "TLS certificate and key are readable by Xray service user: ${user}"
}

print_service_diagnostics() {
  local svc="$1"
  warn "${svc}.service 状态："
  systemctl status "$svc" --no-pager -l >&2 || true
  warn "${svc}.service 最近日志："
  journalctl -u "$svc" -n 80 --no-pager >&2 || true
}

secure_config_permissions() {
  local user="" group=""
  [[ -n "${CONFIG_PATH:-}" && -f "$CONFIG_PATH" ]] || return 0

  user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)"
  if [[ -n "$user" && "$user" != "root" ]]; then
    group="$(id -gn "$user" 2>/dev/null || true)"
    if [[ -n "$group" ]]; then
      chown "root:$group" "$CONFIG_PATH" 2>/dev/null || true
      chmod 640 "$CONFIG_PATH" 2>/dev/null || true
      return 0
    fi
  fi

  chown root:root "$CONFIG_PATH" 2>/dev/null || true
  chmod 600 "$CONFIG_PATH" 2>/dev/null || true
}

restore_backup() {
  [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]] || return 1
  cp -a "$BACKUP_FILE" "$CONFIG_PATH"
  secure_config_permissions
  ok "已恢复备份配置：$BACKUP_FILE -> $CONFIG_PATH"

  if service_unit_exists "$SERVICE_NAME"; then
    info "尝试重启 ${SERVICE_NAME}.service 以恢复旧配置"
    if systemctl restart "$SERVICE_NAME"; then
      sleep 2
      if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "${SERVICE_NAME}.service 已恢复运行。"
      else
        warn "${SERVICE_NAME}.service 重启后仍未处于 active 状态。"
        print_service_diagnostics "$SERVICE_NAME"
      fi
    else
      warn "恢复备份后重启 ${SERVICE_NAME}.service 失败。"
      print_service_diagnostics "$SERVICE_NAME"
    fi
  fi
}

fatal_with_rollback() {
  local msg="$1"
  local ans=""
  if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
    warn "$msg"
    if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
      warn "Non-interactive failure; restoring the previous configuration automatically."
      restore_backup || warn "恢复备份失败，请手动检查：$BACKUP_FILE"
      fatal "$msg"
    fi
    read -r -p "是否恢复本次备份配置？[Y/n]: " ans || ans="Y"
    case "${ans:-Y}" in
      y|Y|yes|YES|"") restore_backup || warn "恢复备份失败，请手动检查：$BACKUP_FILE" ;;
      *) warn "已保留当前新配置。备份位置：$BACKUP_FILE" ;;
    esac
  elif [[ "${CONFIG_WRITTEN_THIS_RUN:-0}" == "1" && -f "${CONFIG_PATH:-}" ]]; then
    warn "$msg"
    warn "Fresh deployment failed; removing the new configuration and stopping ${SERVICE_NAME:-xray}.service."
    rm -f -- "$CONFIG_PATH" || warn "Failed to remove new configuration: $CONFIG_PATH"
    if service_unit_exists "${SERVICE_NAME:-xray}"; then
      systemctl stop "${SERVICE_NAME:-xray}" >/dev/null 2>&1 || warn "Failed to stop ${SERVICE_NAME:-xray}.service"
    fi
  fi
  fatal "$msg"
}

need_root() {
  [[ "$(id -u)" == "0" ]] || fatal "请使用 root 运行：sudo bash $0"
}

install_packages() {
  local pkgs=("$@")
  ((${#pkgs[@]} > 0)) || return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}" >/dev/null
  else
    fatal "找不到支持的包管理器，请手动安装：${pkgs[*]}"
  fi
}

install_port_detection_dep() {
  # 端口占用检测优先依赖 ss。极简系统可能没有 ss，这里按发行版补齐。
  command -v ss >/dev/null 2>&1 && return 0
  command -v lsof >/dev/null 2>&1 && return 0
  command -v netstat >/dev/null 2>&1 && return 0

  info "安装端口检测依赖：ss"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache iproute2 >/dev/null
  else
    warn "找不到支持的包管理器，无法自动安装 ss；端口检测将尽力使用已有工具。"
  fi

  if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    warn "未找到 ss/lsof/netstat，端口占用预检查可能无法执行。"
  fi
}

install_base_deps() {
  local missing=()
  for c in curl jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if ((${#missing[@]} > 0)); then
    info "安装基础依赖：${missing[*]}"
    install_packages "${missing[@]}"
  fi

  install_port_detection_dep
}

sync_time_best_effort() {
  timedatectl set-ntp true >/dev/null 2>&1 || true
  if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u pool.ntp.org >/dev/null 2>&1 || true
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

validate_domain_name() {
  local host="$1" label
  [[ -n "$host" && ${#host} -le 253 ]] || return 1
  [[ "$host" != *" "* && "$host" != *"/"* && "$host" != *":"* ]] || return 1
  [[ "$host" == *.* ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS='.' read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_ipv6_literal() {
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
      for part in "${left_parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count_left=$((count_left + 1))
      done
    fi
    if [[ -n "$right" ]]; then
      IFS=: read -ra right_parts <<< "$right"
      for part in "${right_parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count_right=$((count_right + 1))
      done
    fi
    total=$((count_left + count_right))
    ((total < 8))
    return $?
  fi

  IFS=: read -ra parts <<< "$ip"
  [[ "${#parts[@]}" -eq 8 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
}

validate_link_host() {
  local host="$1" colon_count
  [[ -n "$host" && ${#host} -le 253 ]] || return 1
  [[ "$host" != http://* && "$host" != https://* ]] || return 1
  [[ "$host" != *" "* && "$host" != *"/"* && "$host" != *"?"* && "$host" != *"#"* ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9.:-]+$ ]] || return 1
  colon_count="$(awk -F: '{print NF-1}' <<< "$host")"
  if [[ "$colon_count" == "1" ]]; then
    warn "server host:port is not accepted; use --server <host> and --port <port> separately."
    return 1
  fi
  if [[ "$colon_count" -gt 1 ]]; then
    validate_ipv6_literal "$host"
    return $?
  fi
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    ip_to_int "$host" >/dev/null 2>&1
    return $?
  fi
  validate_domain_name "$host" && return 0
  return 1 # malformed hostname
}

ip_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  [[ ! "$a" =~ ^0[0-9]+$ && ! "$b" =~ ^0[0-9]+$ && ! "$c" =~ ^0[0-9]+$ && ! "$d" =~ ^0[0-9]+$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) || return 1
  echo $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

ip_in_range() {
  local ip_num="$1" start="$2" end="$3" start_num end_num
  start_num="$(ip_to_int "$start")" || return 1
  end_num="$(ip_to_int "$end")" || return 1
  ((ip_num >= start_num && ip_num <= end_num))
}

ipv6_is_non_global() {
  local lower first first_value
  lower="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  case "$lower" in
    ::|::1|2001:db8:*|2001:0db8:*) return 0 ;;
  esac

  first="${lower%%:*}"
  [[ "$first" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  first_value=$((16#$first))
  ((first_value >= 16#fc00 && first_value <= 16#fdff)) && return 0
  ((first_value >= 16#fe80 && first_value <= 16#febf)) && return 0
  ((first_value >= 16#ff00 && first_value <= 16#ffff)) && return 0
  return 1
}

is_private_or_local_ip() {
  local ip="$1" ip_num
  ip="${ip#[}"
  ip="${ip%]}"

  if ip_num="$(ip_to_int "$ip" 2>/dev/null)"; then
    # Non-global IPv4 ranges that should not be auto-used in public share links.
    ip_in_range "$ip_num" 0.0.0.0 0.255.255.255 && return 0
    ip_in_range "$ip_num" 10.0.0.0 10.255.255.255 && return 0
    ip_in_range "$ip_num" 100.64.0.0 100.127.255.255 && return 0
    ip_in_range "$ip_num" 127.0.0.0 127.255.255.255 && return 0
    ip_in_range "$ip_num" 169.254.0.0 169.254.255.255 && return 0
    ip_in_range "$ip_num" 172.16.0.0 172.31.255.255 && return 0
    ip_in_range "$ip_num" 192.0.0.0 192.0.0.255 && return 0
    ip_in_range "$ip_num" 192.0.2.0 192.0.2.255 && return 0
    ip_in_range "$ip_num" 192.168.0.0 192.168.255.255 && return 0
    ip_in_range "$ip_num" 198.18.0.0 198.19.255.255 && return 0
    ip_in_range "$ip_num" 198.51.100.0 198.51.100.255 && return 0
    ip_in_range "$ip_num" 203.0.113.0 203.0.113.255 && return 0
    ip_in_range "$ip_num" 224.0.0.0 255.255.255.255 && return 0
    return 1
  fi

  ipv6_is_non_global "$ip"
}

sanitize_sni() {
  local v="$1"
  v="${v#http://}"
  v="${v#https://}"
  v="${v%%/*}"
  v="${v%%:*}"
  echo "$v"
}

metric_value() {
  local text="$1" key="$2"
  printf '%s\n' "$text" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

sni_check_enabled() {
  case "${SNI_CHECK:-1}" in
    0|no|NO|false|FALSE|off|OFF|skip|SKIP) return 1 ;;
    *) return 0 ;;
  esac
}

xray_tls_ping_probe() {
  local host="$1" xray_bin="" out
  xray_bin="${BIN:-}"
  [[ -n "$xray_bin" && -x "$xray_bin" ]] || xray_bin="$(command -v xray 2>/dev/null || true)"
  [[ -n "$xray_bin" ]] || return 2

  if ! out="$("$xray_bin" tls ping "$host" 2>&1)"; then
    if printf '%s\n' "$out" | grep -Eiq 'unknown|unsupported|usage|help'; then
      return 2
    fi
    printf '%s\n' "$out" | sed 's/^/  /'
    return 1
  fi

  printf '%s\n' "$out" | sed 's/^/  /'
  if printf '%s\n' "$out" | grep -Eiq 'TLSv?1\.3|TLS 1\.3|tls13'; then
    ok "xray tls ping reports TLS 1.3 support."
  else
    warn "xray tls ping passed, but TLS 1.3 was not explicit in output."
  fi
  if printf '%s\n' "$out" | grep -Eiq '(^|[^A-Za-z0-9])h2([^A-Za-z0-9]|$)|HTTP/2'; then
    ok "xray tls ping reports H2 support."
  else
    warn "xray tls ping passed, but H2 was not explicit in output."
  fi
}

probe_sni_domain() {
  local host="$1" timeout="${SNI_CHECK_TIMEOUT:-8}"
  local out http_code http_version remote_ip time_connect time_appconnect redirect_url
  local tls_out tls_rc=0 tls_ok=0 h2_ok=0 timeout_cmd=() xray_ping_rc=0
  LAST_SNI_REMOTE_IP=""

  if ! sni_check_enabled; then
    warn "SNI reachability check skipped."
    return 0
  fi

  validate_domain_name "$host" || return 1

  info "Checking SNI with official xray tls ping: ${host}"
  set +e
  xray_tls_ping_probe "$host"
  xray_ping_rc=$?
  set -e
  if [[ "$xray_ping_rc" -eq 0 ]]; then
    ok "xray tls ping probe passed."
  elif [[ "$xray_ping_rc" -eq 1 ]]; then
    warn "xray tls ping probe failed for ${host}."
    return 1
  else
    warn "xray tls ping is unavailable; falling back to openssl s_client."
  fi

  if command -v openssl >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd=(timeout "$timeout")
    fi

    info "Checking SNI TLS 1.3 and ALPN/H2 with openssl: ${host}:443"
    set +e
    tls_out="$("${timeout_cmd[@]}" openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 -alpn h2,http/1.1 </dev/null 2>&1)"
    tls_rc=$?
    set -e

    if [[ "$tls_rc" -ne 0 ]]; then
      warn "SNI TLS 1.3 probe failed for ${host}:"
      printf '%s\n' "$tls_out" | sed -n '1,12p' | sed 's/^/  /'
      return 1
    fi

    if printf '%s\n' "$tls_out" | grep -Eq 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3|New, TLSv1\.3,'; then
      tls_ok=1
      ok "SNI TLS 1.3 probe passed."
    else
      warn "SNI target did not negotiate TLS 1.3."
    fi

    if printf '%s\n' "$tls_out" | grep -Eq 'ALPN protocol: h2|ALPN Protocol:[[:space:]]*h2'; then
      h2_ok=1
      ok "SNI ALPN/H2 probe passed."
    else
      warn "SNI target did not negotiate HTTP/2 via ALPN."
    fi

    if [[ "$tls_ok" -ne 1 ]]; then
      warn "REALITY targets are expected to support TLS 1.3."
      return 1
    fi
    if [[ "$h2_ok" -ne 1 ]]; then
      warn "SNI target did not negotiate H2. H2 is recommended, not mandatory; continuing."
    fi
  elif [[ "$xray_ping_rc" -eq 0 ]]; then
    warn "openssl is missing; skipped secondary TLS 1.3/ALPN check."
  else
    warn "openssl is required for fallback SNI TLS 1.3/ALPN check."
    return 1
  fi

  command -v curl >/dev/null 2>&1 || { warn "curl is missing; skipped SNI latency/HTTP status check."; return 0; }

  info "Checking SNI reachability: https://${host}/"
  if ! out="$(curl -sS --connect-timeout 4 --max-time "$timeout" -o /dev/null \
    -w 'http_code=%{http_code}\nhttp_version=%{http_version}\nremote_ip=%{remote_ip}\ntime_connect=%{time_connect}\ntime_appconnect=%{time_appconnect}\nredirect_url=%{redirect_url}\n' \
    "https://${host}/" 2>&1)"; then
    warn "SNI check failed for ${host}:"
    printf '%s\n' "$out" | sed 's/^/  /'
    return 1
  fi

  http_code="$(metric_value "$out" "http_code")"
  http_version="$(metric_value "$out" "http_version")"
  remote_ip="$(metric_value "$out" "remote_ip")"
  LAST_SNI_REMOTE_IP="$remote_ip"
  time_connect="$(metric_value "$out" "time_connect")"
  time_appconnect="$(metric_value "$out" "time_appconnect")"
  redirect_url="$(metric_value "$out" "redirect_url")"

  ok "SNI reachable: ${host} remote=${remote_ip:-unknown} connect=${time_connect:-unknown}s tls=${time_appconnect:-unknown}s http=${http_code:-unknown}/${http_version:-unknown}"

  if [[ -n "${redirect_url:-}" ]]; then
    warn "SNI target redirects to ${redirect_url}; REALITY targets are usually better when the chosen domain is not just a redirect."
  fi

  if awk -v t="${time_appconnect:-0}" 'BEGIN { exit !(t > 2.0) }'; then
    warn "SNI TLS handshake took ${time_appconnect}s; a closer or faster target may improve first-connection latency."
  fi

  if curl -V 2>/dev/null | grep -qw HTTP2; then
    if curl --http2 -sS --connect-timeout 4 --max-time "$timeout" -o /dev/null "https://${host}/" >/dev/null 2>&1; then
      ok "SNI HTTP/2 probe passed."
    else
      warn "SNI HTTP/2 probe failed; REALITY targets are usually better when TLS 1.3/H2 is available."
    fi
  else
    warn "curl has no HTTP/2 support; skipped H2 probe."
  fi
}

field_after_colon() {
  # 用法：field_after_colon "文本" "PrivateKey|Password|PublicKey"
  # 兼容：
  #   PrivateKey: xxx
  #   Password (PublicKey): xxx
  #   PublicKey: xxx
  #   Private key: xxx
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | awk -v pat="$pattern" '
    BEGIN {
      n = split(pat, names, /\|/)
      for (i = 1; i <= n; i++) {
        want[i] = tolower(names[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", want[i])
      }
    }
    index($0, ":") {
      line = $0
      key = line
      sub(/:.*/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

      key_no_paren = key
      sub(/[[:space:]]*\(.*/, "", key_no_paren)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key_no_paren)

      key_l = tolower(key)
      key_np_l = tolower(key_no_paren)

      val = line
      sub(/^[^:]*:[[:space:]]*/, "", val)
      gsub(/[[:space:]\r\n\"]/, "", val)

      for (i = 1; i <= n; i++) {
        if (key_l == want[i] || key_np_l == want[i] || index(key_l, want[i]) == 1) {
          if (val != "") {
            print val
            exit
          }
        }
      }
    }
  '
}

extract_vlessenc_value() {
  local text="$1"
  local alg="$2"
  local key="$3"
  printf '%s\n' "$text" | awk -v alg="$alg" -v key="$key" '
    index($0, alg) { f = 1 }
    f && $0 ~ "\"" key "\"[[:space:]]*:" {
      line = $0
      sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
      while (line !~ /"/) {
        if ((getline more) <= 0) break
        line = line more
      }
      sub("\".*", "", line)
      gsub(/[[:space:]\r\n,]/, "", line)
      print line
      exit
    }
  '
}

url_encode() {
  # URL encode for VLESS URI fragment/query values.
  jq -rn --arg v "$1"  '$v|@uri'
}

url_host() {
  local h="$1"
  if [[ "$h" == *:* && "$h" != \[*\] ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

get_public_ip() {
  local ip=""
  # 优先使用 ip.sb；失败时多源兜底。
  for endpoint in \
    "https://api.ip.sb/ip" \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://ipv4.icanhazip.com"; do
    ip="$(curl -fsS4 --max-time 6 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$ip" ]] && break
  done
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "$ip"
}

parse_asn_response() {
  jq -er '
    select((.asn // "") != "")
    | ((.asn | tostring) + "|" + (.asn_organization // .organization // .isp // "unknown"))
  ' <<< "$1" 2>/dev/null
}

lookup_ip_asn() {
  local ip="$1" response
  [[ -n "$ip" ]] || return 1
  if response="$(curl -fsS --connect-timeout 4 --max-time 8 "https://api.ip.sb/geoip/${ip}" 2>/dev/null)" \
    && parse_asn_response "$response"; then
    return 0
  fi
  lookup_ipv4_asn_cymru "$ip"
}

lookup_ipv4_asn_cymru() {
  local ip="$1" a b c d query response data asn org_response org_data org
  ip_to_int "$ip" >/dev/null 2>&1 || return 1
  IFS=. read -r a b c d <<< "$ip"
  query="${d}.${c}.${b}.${a}.origin.asn.cymru.com"
  response="$(curl -fsS --connect-timeout 4 --max-time 8 -G \
    --data-urlencode "name=${query}" --data-urlencode "type=TXT" \
    https://dns.google/resolve 2>/dev/null)" || return 1
  data="$(jq -er '.Answer[]? | select(.type == 16) | .data' <<< "$response" 2>/dev/null | head -n1)" || return 1
  asn="$(awk -F'|' '{ gsub(/[[:space:]]/, "", $1); print $1 }' <<< "$data")"
  [[ "$asn" =~ ^[0-9]+$ ]] || return 1

  org_response="$(curl -fsS --connect-timeout 4 --max-time 8 -G \
    --data-urlencode "name=AS${asn}.asn.cymru.com" --data-urlencode "type=TXT" \
    https://dns.google/resolve 2>/dev/null || true)"
  org_data="$(jq -r '.Answer[]? | select(.type == 16) | .data' <<< "$org_response" 2>/dev/null | head -n1)"
  org="$(awk -F'|' '{ value=$NF; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' <<< "$org_data")"
  printf '%s|%s\n' "$asn" "${org:-unknown}"
}

resolve_domain_public_ip() {
  local host="$1" ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '$2 == "STREAM" { print $1; exit }')"
    [[ -n "$ip" ]] || ip="$(getent ahosts "$host" 2>/dev/null | awk '$2 == "STREAM" { print $1; exit }')"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(curl -sS --connect-timeout 4 --max-time 8 -o /dev/null -w '%{remote_ip}' "https://${host}/" 2>/dev/null || true)"
  fi
  printf '%s\n' "$ip"
}

asn_check_enabled() {
  flag_enabled "${ASN_CHECK:-1}"
}

check_reality_target_asn() {
  local host="$1" vps_ip target_ip vps_record target_record vps_asn target_asn
  local vps_org target_org
  asn_check_enabled || { warn "REALITY same-ASN check skipped."; return 2; }

  vps_ip="$(get_public_ip)"
  target_ip="${LAST_SNI_REMOTE_IP:-}"
  [[ -n "$target_ip" ]] || target_ip="$(resolve_domain_public_ip "$host")"
  if [[ -z "$vps_ip" || -z "$target_ip" ]]; then
    warn "Unable to determine VPS or REALITY target IP; same-ASN check is advisory and was skipped."
    return 2
  fi
  if is_private_or_local_ip "$vps_ip" || is_private_or_local_ip "$target_ip"; then
    warn "Same-ASN check requires public IP addresses: VPS=${vps_ip}, target=${target_ip}"
    return 2
  fi

  vps_record="$(lookup_ip_asn "$vps_ip")" || { warn "Unable to query ASN for VPS IP ${vps_ip}; continuing without ASN enforcement."; return 2; }
  target_record="$(lookup_ip_asn "$target_ip")" || { warn "Unable to query ASN for target IP ${target_ip}; continuing without ASN enforcement."; return 2; }
  IFS='|' read -r vps_asn vps_org <<< "$vps_record"
  IFS='|' read -r target_asn target_org <<< "$target_record"

  info "VPS ASN: AS${vps_asn} ${vps_org} (${vps_ip})"
  info "Target ASN: AS${target_asn} ${target_org} (${target_ip})"
  if [[ "$vps_asn" == "$target_asn" ]]; then
    ok "REALITY target is in the same ASN as this VPS."
    return 0
  fi
  warn "REALITY target is not in the same ASN as this VPS. This is advisory, but it is not the preferred XTLS target selection."
  return 1
}

listener_protocol() {
  if [[ "${DEPLOY_MODE:-reality}" == "cdn-xhttp-tls" ]] && [[ "$(normalize_xhttp_transport_profile "${XHTTP_TRANSPORT_PROFILE:-cdn-stable}" 2>/dev/null || true)" == "direct-h3" ]]; then
    printf '%s\n' "udp"
  else
    printf '%s\n' "tcp"
  fi
}

port_listener_summary() {
  # 输出当前监听占用者，格式尽量统一为：进程名 pid=PID 地址。
  # 优先使用 ss；没有 ss 时兜底 lsof/netstat。
  local port="$1" proto="${2:-tcp}"
  local lines=""

  if command -v ss >/dev/null 2>&1; then
    if [[ "$proto" == "udp" ]]; then
      lines="$(ss -H -lunp "sport = :${port}" 2>/dev/null || true)"
    else
      lines="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
    fi
    if [[ -n "$lines" ]]; then
      printf '%s\n' "$lines" | awk '
        {
          line = $0
          found = 0
          while (match(line, /"[^"]+",pid=[0-9]+/)) {
            s = substr(line, RSTART, RLENGTH)
            name = s
            sub(/^"/, "", name)
            sub(/",pid=.*/, "", name)
            pid = s
            sub(/.*pid=/, "", pid)
            print name " pid=" pid " listen=" $4
            line = substr(line, RSTART + RLENGTH)
            found = 1
          }
          if (!found) print "unknown " $0
        }
      ' | sort -u
    fi
    return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    if [[ "$proto" == "udp" ]]; then
      lsof -nP -iUDP:"${port}" 2>/dev/null | awk 'NR>1 {print $1 " pid=" $2 " " $9}' | sort -u
    else
      lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1 " pid=" $2 " " $9}' | sort -u
    fi
    return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    if [[ "$proto" == "udp" ]]; then
      netstat -lunp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $7 " " $4}' | sort -u
    else
      netstat -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $7 " " $4}' | sort -u
    fi
    return 0
  fi

  return 1
}

check_port_available_or_handle() {
  # 如果端口只被当前 xray 服务占用，则允许继续，因为 systemctl restart 会重载本服务。
  # 如果端口被其他进程占用，明确告知占用者，避免脚本擅自停止无关服务。
  local owners=""
  local names=""
  local non_current=""
  local proto
  proto="$(listener_protocol)"

  if ! owners="$(port_listener_summary "$PORT" "$proto")"; then
    warn "未找到 ss/lsof/netstat，跳过端口占用预检查。"
    return 0
  fi

  [[ -z "$owners" ]] && return 0

  warn "检测到 ${proto^^} 端口 ${PORT} 已被占用："
  printf '%s\n' "$owners" | sed 's/^/  - /'

  names="$(printf '%s\n' "$owners" | awk '{print $1}' | sed 's#^.*/##' | sort -u)"
  non_current="$(printf '%s\n' "$names" | grep -vxF "$SERVICE_NAME" || true)"

  if [[ -z "$non_current" ]]; then
    warn "端口 ${PORT} 当前由本次选择的 ${SERVICE_NAME} 占用；后续重启会重载本服务，继续。"
    return 0
  fi

  local owner_oneline=""
  owner_oneline="$(printf '%s\n' "$owners" | awk 'BEGIN{first=1} { if (!first) printf "; "; printf "%s", $0; first=0 }')"
  fatal "${proto^^} 端口 ${PORT} 被非当前服务占用：${owner_oneline}。请换端口，或手动停止占用进程后重试。"
}

download_and_run_installer() {
  local url="$1" shell_bin="$2" label="$3" installer rc
  installer="$(mktemp)"
  if ! curl -fsSL "$url" -o "$installer"; then
    rm -f "$installer"
    fatal "${label} 安装脚本下载失败：$url"
  fi
  if ! chmod 700 "$installer"; then
    rm -f "$installer"
    fatal "${label} 安装脚本权限设置失败"
  fi
  if "$shell_bin" "$installer" "${@:4}"; then
    rm -f "$installer"
    return 0
  fi
  rc=$?
  rm -f "$installer"
  return "$rc"
}

install_xray_official() {
  info "使用 XTLS 官方 Xray-install 安装/更新 Xray-core"
  download_and_run_installer "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" bash "Xray" install \
    || fatal "Xray 官方安装脚本执行失败"
  command -v xray >/dev/null 2>&1 || fatal "Xray 安装后仍未找到 xray 命令"
  systemctl enable xray >/dev/null 2>&1 || fatal "Xray service enable failed"
}

xray_required_capabilities() {
  # vlessenc is the modern-core baseline for this script, even when the user selects none.
  printf '%s\n' run uuid vlessenc
  if [[ "${DEPLOY_MODE:-reality}" == "reality" ]]; then
    printf '%s\n' x25519 tls
    flag_enabled "${ENABLE_MLDSA:-0}" && printf '%s\n' mldsa65
  fi
}

missing_xray_capabilities() {
  local help_text="$1" capability
  shift
  for capability in "$@"; do
    printf '%s\n' "$help_text" | awk -v wanted="$capability" '$1 == wanted { found = 1 } END { exit !found }' \
      || printf '%s\n' "$capability"
  done
}

xray_missing_required_capabilities() {
  local help_text tls_help missing
  local -a required=()
  help_text="$($BIN help 2>&1 || true)"
  mapfile -t required < <(xray_required_capabilities)
  missing="$(missing_xray_capabilities "$help_text" "${required[@]}")"
  [[ -n "$missing" ]] && printf '%s\n' "$missing"
  if [[ "${DEPLOY_MODE:-reality}" == "reality" ]]; then
    tls_help="$($BIN tls 2>&1 || true)"
    printf '%s\n' "$tls_help" | awk '$1 == "ping" { found = 1 } END { exit !found }' \
      || printf '%s\n' tls-ping
  fi
}

ensure_xray_capabilities() {
  local missing
  missing="$(xray_missing_required_capabilities)"
  if [[ -z "$missing" ]]; then
    ok "Xray supports the commands required by the selected deployment profile."
    return 0
  fi

  warn "Installed Xray is missing required capabilities: $(printf '%s' "$missing" | paste -sd, -)"
  if [[ "${NONINTERACTIVE:-0}" == "1" ]] && ! is_auto_yes; then
    fatal "Rerun with --update-xray (or --yes) to upgrade through the official XTLS installer."
  fi
  confirm_yes_default_yes "是否使用 XTLS 官方安装脚本升级 Xray-core？" \
    && install_xray_official \
    || fatal "Xray capability upgrade was cancelled."
  BIN="$(command -v xray)"
  missing="$(xray_missing_required_capabilities)"
  [[ -z "$missing" ]] || fatal "Xray still lacks required capabilities after upgrade: $(printf '%s' "$missing" | paste -sd, -)"
  ok "Xray capability check passed after official upgrade."
}

ensure_xray_installed() {
  local was_installed=1
  if ! command -v xray >/dev/null 2>&1; then
    was_installed=0
    warn "未找到 xray。"
    confirm_yes_default_yes "是否使用 XTLS 官方脚本安装 Xray-core？" \
      && install_xray_official \
      || fatal "已取消安装，退出。"
  elif flag_enabled "$UPDATE_XRAY"; then
    install_xray_official
  fi
  BIN="$(command -v xray)"
  SERVICE_NAME="xray"
  CONFIG_DIR="/usr/local/etc/xray"
  CONFIG_PATH="$CONFIG_DIR/config.json"
  if [[ "$was_installed" == "1" ]]; then
    info "Installed Xray: $($BIN version 2>/dev/null | head -n1 || printf 'unknown version')"
  fi
}

preflight_check() {
  local failures=0 port sni host owners mode proto route_strategy missing
  port="${CLI_PORT:-$DEFAULT_PORT}"
  sni="$(sanitize_sni "${CLI_SNI:-$DEFAULT_SNI}")"
  host="${CLI_SERVER:-}"
  if ! DEPLOY_MODE="$(normalize_deploy_mode "$DEPLOY_MODE")"; then
    warn "Invalid deploy mode: $DEPLOY_MODE"
    failures=$((failures + 1))
    DEPLOY_MODE="reality"
  fi

  info "Read-only preflight for freedom.sh ${SCRIPT_VERSION} (${DEPLOY_MODE})"

  if valid_port "$port"; then
    ok "Port looks valid: $port"
  else
    warn "Invalid port: $port"
    failures=$((failures + 1))
  fi
  if [[ "$DEPLOY_MODE" == "reality" ]] && ! reality_port_is_standard "$port"; then
    warn "REALITY is expected to listen on TCP/443; selected port is ${port}."
    if flag_enabled "$ALLOW_NONSTANDARD_REALITY_PORT"; then
      warn "Explicit non-standard REALITY port override is set."
    else
      warn "Add --allow-nonstandard-reality-port only if this is intentional."
      failures=$((failures + 1))
    fi
  fi

  if validate_domain_name "$sni"; then
    ok "SNI/domain looks valid: $sni"
    if [[ "$DEPLOY_MODE" == "reality" ]]; then
      if ! probe_sni_domain "$sni"; then
        warn "SNI reachability check failed: $sni"
        failures=$((failures + 1))
      fi
      check_reality_target_asn "$sni" || true
      warn_reality_target_scope
    else
      info "CDN XHTTP TLS mode uses this value as the certificate/SNI domain; REALITY target probing is skipped."
    fi
  else
    warn "Invalid SNI/domain: $sni"
    failures=$((failures + 1))
  fi

  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    if [[ -z "$host" ]]; then
      info "CDN XHTTP TLS mode will default the share address to the TLS/SNI domain. Use --server for a preferred CDN IP or hostname."
    fi
    if [[ -n "$XHTTP_PATH" ]]; then
      validate_xhttp_path "$XHTTP_PATH" || { warn "Invalid XHTTP path: $XHTTP_PATH"; failures=$((failures + 1)); }
    fi
    if XHTTP_TRANSPORT_PROFILE="$(normalize_xhttp_transport_profile "$XHTTP_TRANSPORT_PROFILE")"; then
      XHTTP_ORIGIN_ALPN_JSON="$(xhttp_origin_alpn_json "$XHTTP_TRANSPORT_PROFILE")"
      XHTTP_CLIENT_ALPN_JSON="$(xhttp_client_alpn_json "$XHTTP_TRANSPORT_PROFILE")"
      ok "XHTTP transport profile looks valid: $XHTTP_TRANSPORT_PROFILE; origin=$XHTTP_ORIGIN_ALPN_JSON client=$XHTTP_CLIENT_ALPN_JSON"
      if [[ "$XHTTP_TRANSPORT_PROFILE" == "cdn-h3" ]]; then
        info "CDN-H3 keeps the Xray origin on TCP H1/H2; only the client-to-CDN edge uses H3."
      elif [[ "$XHTTP_TRANSPORT_PROFILE" == "direct-h3" ]]; then
        warn "DIRECT-H3 makes Xray listen on UDP/${port}; use it only for controlled diagnostics, not as the CDN default."
      fi
    else
      warn "Invalid XHTTP transport profile: $XHTTP_TRANSPORT_PROFILE"
      failures=$((failures + 1))
    fi
    if TLS_CERT_MODE="$(normalize_tls_cert_mode "$TLS_CERT_MODE")"; then
      ok "TLS cert mode looks valid: $TLS_CERT_MODE"
      if [[ "$TLS_CERT_MODE" == "cloudflare-origin" ]]; then
        warn_cloudflare_origin_ca_scope
        if ! cloudflare_https_port_supported "$port"; then
          warn "Cloudflare does not proxy HTTPS on port ${port}. Supported HTTPS ports: 443, 2053, 2083, 2087, 2096, 8443."
          failures=$((failures + 1))
        fi
      fi
    else
      warn "Invalid TLS cert mode: $TLS_CERT_MODE"
      failures=$((failures + 1))
    fi
    if [[ -z "$TLS_CERT_FILE" || -z "$TLS_KEY_FILE" ]]; then
      warn "CDN XHTTP TLS mode requires --tls-cert-file and --tls-key-file."
      failures=$((failures + 1))
    else
      check_tls_cert_files "$sni" || failures=$((failures + 1))
    fi
  fi

  if ROUTE_PROFILE="$(normalize_route_profile "$ROUTE_PROFILE")"; then
    route_strategy="$(routing_domain_strategy "$ROUTE_PROFILE")"
    ok "Routing profile looks valid: $ROUTE_PROFILE => $route_strategy"
    [[ "$ROUTE_PROFILE" == "strict" ]] && warn "STRICT resolves unmatched domains so CN/private IP rules can match; GeoDNS differences may affect global services."
  else
    warn "Invalid routing profile: $ROUTE_PROFILE"
    failures=$((failures + 1))
  fi

  if [[ -n "$host" ]]; then
    if validate_link_host "$host"; then
      ok "Server/link host looks valid: $host"
      if is_private_or_local_ip "$host"; then
        warn "Server/link host is private/local; this is usually only suitable for LAN testing."
      fi
    else
      warn "Invalid server/link host: $host"
      failures=$((failures + 1))
    fi
  fi

  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    ok "systemd is available"
  else
    warn "systemd was not detected; service management may fail"
    failures=$((failures + 1))
  fi

  for c in curl jq openssl; do
    if command -v "$c" >/dev/null 2>&1; then
      ok "Dependency found: $c"
    else
      warn "Dependency missing: $c"
    fi
  done

  if command -v xray >/dev/null 2>&1; then
    BIN="$(command -v xray)"
    SERVICE_NAME="xray"
    CONFIG_DIR="/usr/local/etc/xray"
    CONFIG_PATH="$CONFIG_DIR/config.json"
    ok "Xray found: $BIN"
    "$BIN" version 2>/dev/null | head -n1 || true
    missing="$(xray_missing_required_capabilities)"
    if [[ -n "$missing" ]]; then
      warn "Xray is missing capabilities required by this profile: $(printf '%s' "$missing" | paste -sd, -)"
      warn "Deployment can upgrade it with --update-xray."
      failures=$((failures + 1))
    else
      ok "Xray capability check passed for the selected profile."
    fi
    if service_unit_exists "$SERVICE_NAME"; then
      ok "systemd unit found: ${SERVICE_NAME}.service"
      if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" && -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ]]; then
        check_tls_files_service_readable || failures=$((failures + 1))
      fi
    else
      warn "systemd unit not found: ${SERVICE_NAME}.service"
    fi
    if [[ -f "$CONFIG_PATH" ]]; then
      mode="$(stat -c '%a %U:%G' "$CONFIG_PATH" 2>/dev/null || true)"
      ok "Existing config: $CONFIG_PATH ${mode}"
    fi
  else
    warn "Xray is not installed; deployment can install it when run without --check"
  fi

  proto="$(listener_protocol)"
  if owners="$(port_listener_summary "$port" "$proto")" && [[ -n "$owners" ]]; then
    warn "${proto^^} port ${port} is already listening:"
    printf '%s\n' "$owners" | sed 's/^/  - /'
  fi

  if [[ "$failures" -gt 0 ]]; then
    fatal "Preflight found ${failures} blocking issue(s)."
  fi
  ok "Preflight finished without blocking issues."
}

read_common_inputs() {
  local auto_detected_server=0 mode_input default_xhttp_path mode_default cert_mode_input cert_mode_default
  local sni_prompt transport_input transport_default route_input route_default
  clear_screen
  case "$(normalize_deploy_mode "$DEPLOY_MODE" 2>/dev/null || printf '%s\n' reality)" in
    cdn-xhttp-tls) mode_default="2" ;;
    *) mode_default="1" ;;
  esac
  mode_input="$(input_default "Deployment profile: 1=REALITY-VISION (direct), 2=XHTTP-TLS-VISION (CDN)" "$mode_default")"
  DEPLOY_MODE="$(normalize_deploy_mode "$mode_input")" || fatal "Invalid deploy mode: $mode_input"
  ok "VLESS/Xray automated deployment ${SCRIPT_VERSION}"
  info "当前核心：Xray-core (${BIN})"

  while true; do
    PORT="$(input_default "监听端口" "${CLI_PORT:-$DEFAULT_PORT}")"
    valid_port "$PORT" && break
    [[ "${NONINTERACTIVE:-0}" == "1" ]] && fatal "端口无效：$PORT"
    warn "端口无效，请输入 1-65535。"
  done
  enforce_reality_port_policy

  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    sni_prompt="TLS/SNI domain"
  else
    sni_prompt="REALITY target SNI"
  fi
  SNI="$(sanitize_sni "$(input_default "$sni_prompt" "${CLI_SNI:-$DEFAULT_SNI}")")"
  [[ -n "$SNI" ]] || fatal "SNI 不能为空"
  validate_domain_name "$SNI" || fatal "Invalid SNI/domain: $SNI"
  if [[ "$DEPLOY_MODE" == "reality" ]] && ! probe_sni_domain "$SNI"; then
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
      fatal "SNI reachability check failed: $SNI. Use --sni <better-domain> or --skip-sni-check to bypass."
    fi
    confirm_yes_default_no "SNI reachability check failed. Continue anyway?" \
      || fatal "已取消。请更换 SNI，或确认目标站 HTTPS/TLS 可用后重试。"
  fi
  if [[ "$DEPLOY_MODE" == "reality" ]]; then
    check_reality_target_asn "$SNI" || true
  fi
  [[ "$DEPLOY_MODE" == "reality" ]] && warn_reality_target_scope
  NODE_NAME="$(input_default "节点名称" "${CLI_NODE_NAME:-$DEFAULT_NODE_NAME}")"

  case "$(normalize_route_profile "$ROUTE_PROFILE" 2>/dev/null || printf '%s\n' compatible)" in
    strict) route_default="2" ;;
    *) route_default="1" ;;
  esac
  route_input="$(input_default "Routing profile: 1=COMPATIBLE (AsIs), 2=STRICT CN/IP (IPIfNonMatch)" "$route_default")"
  ROUTE_PROFILE="$(normalize_route_profile "$route_input")" || fatal "Invalid routing profile: $route_input"
  if [[ "$ROUTE_PROFILE" == "strict" ]]; then
    warn "STRICT resolves unmatched domains before IP rules; this strengthens CN/private IP blocking but GeoDNS may affect global services."
  else
    info "COMPATIBLE blocks CN domains and IP-form CN/private destinations without extra server-side DNS resolution."
  fi

  SERVER_IP="${CLI_SERVER:-}"
  if [[ -z "$SERVER_IP" && "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    SERVER_IP="$(input_default "CDN address/domain for share link" "$SNI")"
    auto_detected_server=0
    info "CDN mode defaults the share address to the TLS/SNI domain. Use --server for a preferred CDN IP or hostname."
  elif [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(get_public_ip)"
    auto_detected_server=1
  fi
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(input_default "服务器地址/IP" "")"
    auto_detected_server=0
  fi
  [[ -n "$SERVER_IP" ]] || fatal "服务器地址/IP 不能为空"
  validate_link_host "$SERVER_IP" || fatal "Invalid server/link host: $SERVER_IP"
  if [[ "$auto_detected_server" == "1" ]] && is_private_or_local_ip "$SERVER_IP"; then
    fatal "Auto-detected server address is private/local: $SERVER_IP. Please rerun with --server <public-ip-or-domain>."
  fi
  SERVER_HOST_FOR_LINK="$(url_host "$SERVER_IP")"

  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    default_xhttp_path="${XHTTP_PATH:-$(generate_xhttp_path)}"
    XHTTP_PATH="$(input_default "XHTTP request path" "$default_xhttp_path")"
    validate_xhttp_path "$XHTTP_PATH" || fatal "Invalid XHTTP path: $XHTTP_PATH"

    case "$(normalize_tls_cert_mode "$TLS_CERT_MODE" 2>/dev/null || printf '%s\n' public)" in
      cloudflare-origin) cert_mode_default="2" ;;
      *) cert_mode_default="1" ;;
    esac
    cert_mode_input="$(input_default "Certificate profile: 1=PUBLIC CA, 2=CLOUDFLARE ORIGIN CA" "$cert_mode_default")"
    TLS_CERT_MODE="$(normalize_tls_cert_mode "$cert_mode_input")" || fatal "Invalid TLS cert mode: $cert_mode_input"
    if [[ "$TLS_CERT_MODE" == "cloudflare-origin" ]]; then
      warn_cloudflare_origin_ca_scope
      cloudflare_https_port_supported "$PORT" \
        || fatal "Cloudflare does not proxy HTTPS on port ${PORT}. Use 443, 2053, 2083, 2087, 2096, or 8443."
    fi

    TLS_CERT_FILE="$(input_default "TLS certificate file path" "$TLS_CERT_FILE")"
    TLS_KEY_FILE="$(input_default "TLS private key file path" "$TLS_KEY_FILE")"
    validate_tls_cert_files

    case "$(normalize_xhttp_transport_profile "$XHTTP_TRANSPORT_PROFILE" 2>/dev/null || printf '%s\n' cdn-stable)" in
      cdn-h2) transport_default="2" ;;
      cdn-h3) transport_default="3" ;;
      direct-h3)
        if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
          transport_default="direct-h3"
        else
          warn "DIRECT-H3 is available only through --xhttp-profile direct-h3 for controlled diagnostics."
          transport_default="1"
        fi
        ;;
      *) transport_default="1" ;;
    esac
    transport_input="$(input_default "Transport profile: 1=CDN-STABLE, 2=CDN-H2, 3=CDN-H3" "$transport_default")"
    XHTTP_TRANSPORT_PROFILE="$(normalize_xhttp_transport_profile "$transport_input")" || fatal "Invalid XHTTP transport profile: $transport_input"
    XHTTP_ORIGIN_ALPN_JSON="$(xhttp_origin_alpn_json "$XHTTP_TRANSPORT_PROFILE")"
    XHTTP_CLIENT_ALPN_JSON="$(xhttp_client_alpn_json "$XHTTP_TRANSPORT_PROFILE")"
    if [[ "$XHTTP_TRANSPORT_PROFILE" == "cdn-h3" ]]; then
      info "CDN-H3 keeps the Xray origin on TCP H1/H2; the client requests H3 only at the CDN edge."
    elif [[ "$XHTTP_TRANSPORT_PROFILE" == "direct-h3" ]]; then
      warn "DIRECT-H3 makes Xray listen on UDP/${PORT}; use it only for direct controlled testing."
    fi
  fi
}

gen_uuid() {
  "$BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

gen_short_id() {
  openssl rand -hex 8 | tr -d '[:space:]'
}

generate_xhttp_path() {
  local token
  token="$(gen_uuid | tr -dc 'A-Za-z0-9' | cut -c 1-16)"
  [[ -n "$token" ]] || token="$(openssl rand -hex 8 2>/dev/null || date +%s)"
  printf '/cdn-%s\n' "$token"
}

generate_spider_x() {
  local token choice
  token="$(gen_uuid | tr -dc 'A-Za-z0-9' | cut -c 1-12)"
  [[ -n "$token" ]] || token="$(date +%s)"
  choice=$((16#${token:0:2} % 4))
  case "$choice" in
    0) printf '/assets/%s.js\n' "$token" ;;
    1) printf '/static/%s.css\n' "$token" ;;
    2) printf '/api/v1/%s\n' "$token" ;;
    *) printf '/search?q=%s\n' "$token" ;;
  esac
}

gen_reality_keys_xray() {
  info "生成 Xray REALITY X25519 密钥"
  local out
  out="$($BIN x25519 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray x25519 执行失败"; }

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private key|Private")"
  REALITY_PUB="$(field_after_colon "$out" "Password|PublicKey|Public key|Public")"

  # 兜底：兼容 Password (PublicKey): xxx。
  if [[ -z "$REALITY_PUB" ]]; then
    REALITY_PUB="$(printf '%s\n' "$out" | grep -Ei '^\s*Password(\s*\([^)]*\))?\s*:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]\r\n\"' || true)"
  fi

  [[ -n "$REALITY_PRIV" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 Xray PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 Xray Password/PublicKey，不能生成 pbk"; }
  [[ "$REALITY_PRIV" != *Private* && "$REALITY_PRIV" != *Password* ]] || fatal "Xray 私钥提取异常"
  ok "REALITY private key generated."
  ok "REALITY pbk：$REALITY_PUB"
}

gen_xray_vless_encryption() {
  echo
  echo "Xray VLESS Encryption："
  echo "1) X25519 认证，由 xray vlessenc 生成（默认，链接较短）"
  echo "2) ML-KEM-768 认证，由 xray vlessenc 生成（更强认证，链接更长）"
  echo "3) none，兼容模式"
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    case "${XRAY_ENCRYPTION_CHOICE:-x25519}" in
      x25519|X25519|auto|vlessenc|on|yes|YES|true|TRUE) enc_choice="1" ;;
      ml-kem-768|ML-KEM-768|mlkem768|mlkem768x25519plus) enc_choice="2" ;;
      none|off|no|NO|false|FALSE) enc_choice="3" ;;
      *) fatal "Xray 加密参数无效：$XRAY_ENCRYPTION_CHOICE" ;;
    esac
  else
    read -r -p "选择加密 [默认 1]: " enc_choice
    enc_choice="${enc_choice:-1}"
  fi

  VLESS_DEC="none"
  VLESS_ENC="none"

  if [[ "$enc_choice" == "3" ]]; then
    return 0
  fi

  [[ "$enc_choice" == "1" || "$enc_choice" == "2" ]] || fatal "加密选项无效，只能选择 1、2 或 3。"

  local out alg
  out="$($BIN vlessenc 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray vlessenc 执行失败。当前 Xray 可能过旧，请升级。"; }

  if [[ "$enc_choice" == "1" ]]; then
    alg="X25519"
  else
    alg="ML-KEM-768"
  fi

  VLESS_DEC="$(extract_vlessenc_value "$out" "$alg" "decryption")"
  VLESS_ENC="$(extract_vlessenc_value "$out" "$alg" "encryption")"

  [[ -n "$VLESS_DEC" && -n "$VLESS_ENC" ]] || {
    printf '%s\n' "$out" | redact_sensitive_text
    fatal "未能从 xray vlessenc 输出中提取 ${alg} 的 decryption/encryption"
  }
  ok "Xray VLESS Encryption：${alg} auth"
}

tls_ping_sni_chain_length() {
  printf '%s\n' "$1" | awk '
    /Pinging with SNI/ { in_sni = 1; next }
    in_sni && /Certificate chain.s total length:/ {
      line = $0
      sub(/.*length:[[:space:]]*/, "", line)
      sub(/[[:space:]].*/, "", line)
      print line
      exit
    }
  '
}

tls_ping_sni_has_pq_kex() {
  printf '%s\n' "$1" | awk '
    /Pinging with SNI/ { in_sni = 1; next }
    in_sni && /TLS Post-Quantum key exchange:/ {
      found = 1
      if (tolower($0) ~ /true/) exit 0
      exit 1
    }
    END { if (!found) exit 1 }
  '
}

validate_mldsa_target() {
  local out chain_length
  info "Validating REALITY target certificate size for ML-DSA-65: $SNI"
  if ! out="$($BIN tls ping "$SNI" 2>&1)"; then
    printf '%s\n' "$out" | sed -n '1,16p' | sed 's/^/  /'
    fatal "Cannot validate the REALITY target for ML-DSA-65. Disable ML-DSA or choose a reachable target."
  fi
  chain_length="$(tls_ping_sni_chain_length "$out")"
  [[ "$chain_length" =~ ^[0-9]+$ ]] || fatal "xray tls ping did not report the target certificate-chain length; ML-DSA was not enabled."
  if ((chain_length <= 3500)); then
    fatal "REALITY target certificate chain is ${chain_length} bytes; ML-DSA requires more than 3500 bytes to avoid a size fingerprint."
  fi
  ok "REALITY target certificate chain is suitable for ML-DSA: ${chain_length} bytes"
  if tls_ping_sni_has_pq_kex "$out"; then
    ok "REALITY target supports post-quantum X25519MLKEM768 key exchange."
  else
    warn "Target key exchange is not post-quantum. ML-DSA protects the REALITY signature, but the transport key exchange remains X25519."
  fi
}

gen_xray_mldsa_optional() {
  echo
  echo "REALITY ML-DSA-65 额外签名："
  warn "开启后分享链接会明显变长；部分客户端或二维码工具可能处理失败。不确定时建议关闭。"
  case "${ENABLE_MLDSA:-0}" in
    1|yes|YES|true|TRUE) ;;
    *)
      confirm_yes_default_no "是否开启 ML-DSA-65？" || return 0
      ;;
  esac

  local out
  validate_mldsa_target
  out="$($BIN mldsa65 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray mldsa65 执行失败。当前 Xray 可能过旧，请升级。"; }

  MLDSA_SEED="$(field_after_colon "$out" "Seed")"
  MLDSA_VERIFY="$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*Verify[[:space:]]*:/,$p' | sed '1s/^[^:]*:[[:space:]]*//' | tr -d '\n\r[:space:]')"

  [[ -n "$MLDSA_SEED" && -n "$MLDSA_VERIFY" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 mldsa65 Seed/Verify"; }
  MLDSA_LINK_PARAM="&pqv=$(url_encode "$MLDSA_VERIFY")"
  ok "ML-DSA-65 已启用；Verify 长度：${#MLDSA_VERIFY}"
}

generate_assets() {
  UUID="$(gen_uuid | tr -d '[:space:]')"
  [[ -n "$UUID" ]] || fatal "UUID generation failed"

  gen_xray_vless_encryption
  if [[ "$DEPLOY_MODE" == "reality" ]]; then
    SHORT_ID="$(gen_short_id)"
    SPIDER_X="$(generate_spider_x)"
    [[ -n "$SHORT_ID" && -n "$SPIDER_X" ]] || fatal "shortId or spiderX generation failed"
    gen_reality_keys_xray
    gen_xray_mldsa_optional
  fi
}

backup_existing_config() {
  install -d -m 755 "$CONFIG_DIR"
  BACKUP_FILE=""
  if [[ -f "$CONFIG_PATH" ]]; then
    BACKUP_FILE="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a "$CONFIG_PATH" "$BACKUP_FILE"; then
      BACKUP_FILE=""
      fatal "Failed to back up existing Xray configuration; no changes were written."
    fi
    warn "已备份旧配置：$BACKUP_FILE"

    # 只保留最新 5 个备份，避免长期堆积。
    find "$CONFIG_DIR" -maxdepth 1 -type f -name "$(basename "$CONFIG_PATH").bak.*" -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR > 5 { sub(/^[^ ]+ /, ""); print }' \
      | while IFS= read -r old_backup; do
          rm -f -- "$old_backup"
        done
  fi
}

install_generated_config_atomically() {
  local tmp="$1"
  chmod 600 "$tmp" || return 1
  chown root:root "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$CONFIG_PATH" || return 1
  CONFIG_WRITTEN_THIS_RUN=1
}

validate_generated_config() {
  local config_file="$1" test_log warnings
  info "检查配置文件：$config_file"
  jq empty "$config_file" || return 1

  test_log="$(mktemp)"
  if ! "$BIN" run -test -c "$config_file" >"$test_log" 2>&1; then
    printf '\n--- fallback: xray -test -config ---\n' >> "$test_log"
    if ! "$BIN" -test -config "$config_file" >>"$test_log" 2>&1; then
      cat "$test_log" >&2
      rm -f "$test_log"
      return 1
    fi
  fi
  warnings="$(grep -Ei '(^|[^A-Za-z])(warn|warning)([^A-Za-z]|$)' "$test_log" || true)"
  if [[ -n "$warnings" ]]; then
    warn "Xray accepted the config with warning(s):"
    printf '%s\n' "$warnings" | redact_sensitive_text | sed 's/^/  /'
  fi
  rm -f "$test_log"
}

write_xray_config_xhttp_tls() {
  local tmp domain_strategy rules_json='[
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","domain":["geosite:cn"],"outboundTag":"block"},
    {"type":"field","ip":["geoip:cn"],"outboundTag":"block"}
  ]'
  domain_strategy="$(routing_domain_strategy "$ROUTE_PROFILE")" || fatal "Invalid routing profile: $ROUTE_PROFILE"

  tmp="$(mktemp --suffix=.json "${CONFIG_DIR}/config.tmp.XXXXXX")"
  if ! jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg vdec "$VLESS_DEC" \
    --arg xhttp_path "$XHTTP_PATH" \
    --arg tls_cert_file "$TLS_CERT_FILE" \
    --arg tls_key_file "$TLS_KEY_FILE" \
    --argjson alpn "$XHTTP_ORIGIN_ALPN_JSON" \
    --arg domain_strategy "$domain_strategy" \
    --argjson rules "$rules_json" \
    '
    {
      log: { loglevel: "warning" },
      inbounds: [
        {
          port: $port,
          protocol: "vless",
          settings: {
            clients: [ { id: $uuid, flow: "xtls-rprx-vision" } ],
            decryption: $vdec
          },
          streamSettings: {
            network: "xhttp",
            security: "tls",
            tlsSettings: {
              alpn: $alpn,
              minVersion: "1.2",
              maxVersion: "1.3",
              rejectUnknownSni: true,
              certificates: [
                {
                  certificateFile: $tls_cert_file,
                  keyFile: $tls_key_file
                }
              ]
            },
            xhttpSettings: {
              path: $xhttp_path
            }
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
          }
        }
      ],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "block" }
      ],
      routing: {
        domainStrategy: $domain_strategy,
        rules: $rules
      }
    }' > "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray XHTTP TLS config generation failed"
  fi
  if ! validate_generated_config "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray generated temp config test failed"
  fi
  if ! install_generated_config_atomically "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray config install failed"
  fi
  rm -f "$tmp"
}

write_xray_config() {
  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    write_xray_config_xhttp_tls
    return 0
  fi

  # Routing policy:
  # 1. The first outbound is direct, so unmatched traffic is allowed by default.
  # 2. Block private IPs first to avoid proxy access to local/cloud metadata networks.
  # 3. Block BitTorrent traffic that goes through this Xray inbound.
  # 4. Unmatched traffic uses the first outbound (direct); no explicit geolocation-!cn rule is needed.
  # 5. COMPATIBLE uses AsIs; STRICT uses IPIfNonMatch for final-IP enforcement.
  local tmp domain_strategy rules_json='[
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","domain":["geosite:cn"],"outboundTag":"block"},
    {"type":"field","ip":["geoip:cn"],"outboundTag":"block"}
  ]'
  domain_strategy="$(routing_domain_strategy "$ROUTE_PROFILE")" || fatal "Invalid routing profile: $ROUTE_PROFILE"

  tmp="$(mktemp --suffix=.json "${CONFIG_DIR}/config.tmp.XXXXXX")"
  if ! jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg vdec "$VLESS_DEC" \
    --arg sni "$SNI" \
    --arg private_key "$REALITY_PRIV" \
    --arg short_id "$SHORT_ID" \
    --arg mldsa_seed "$MLDSA_SEED" \
    --arg domain_strategy "$domain_strategy" \
    --argjson rules "$rules_json" \
    '
    {
      log: { loglevel: "warning" },
      inbounds: [
        {
          port: $port,
          protocol: "vless",
          settings: {
            clients: [ { id: $uuid, flow: "xtls-rprx-vision" } ],
            decryption: $vdec
          },
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: (
              {
                show: false,
                target: ($sni + ":443"),
                xver: 0,
                serverNames: [ $sni ],
                privateKey: $private_key,
                shortIds: [ $short_id ],
                maxTimeDiff: 60000
              }
              + (if $mldsa_seed != "" then { mldsa65Seed: $mldsa_seed } else {} end)
            )
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
          }
        }
      ],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "block" }
      ],
      routing: {
        domainStrategy: $domain_strategy,
        rules: $rules
      }
    }' > "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray config generation failed"
  fi
  if ! validate_generated_config "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray generated temp config test failed"
  fi
  if ! install_generated_config_atomically "$tmp"; then
    rm -f "$tmp"
    fatal_with_rollback "Xray config install failed"
  fi
  rm -f "$tmp"
}

validate_config() {
  validate_generated_config "$CONFIG_PATH" || fatal_with_rollback "Xray 配置测试失败"
}

verify_service_port_listening() {
  local owners names proto
  proto="$(listener_protocol)"
  if ! owners="$(port_listener_summary "$PORT" "$proto")"; then
    warn "未找到 ss/lsof/netstat，跳过启动后的端口监听验证。"
    return 0
  fi
  if [[ -z "$owners" ]]; then
    fatal_with_rollback "${SERVICE_NAME} is active but not listening on ${proto^^} port ${PORT}"
  fi
  names="$(printf '%s\n' "$owners" | awk '{print $1}' | sed 's#^.*/##' | sort -u)"
  if ! printf '%s\n' "$names" | grep -qxF "$SERVICE_NAME"; then
    warn "${proto^^} port ${PORT} is listening, but not by ${SERVICE_NAME}:"
    printf '%s\n' "$owners" | sed 's/^/  - /'
    fatal_with_rollback "${SERVICE_NAME} is not listening on ${proto^^} port ${PORT}"
  fi
  ok "${SERVICE_NAME} is listening on ${proto^^} port ${PORT}"
}

restart_service() {
  info "重启服务：$SERVICE_NAME"

  if ! service_unit_exists "$SERVICE_NAME"; then
    warn "没找到 systemd 服务 ${SERVICE_NAME}.service，仅已写入配置：$CONFIG_PATH"
    return 0
  fi

  if ! systemctl restart "$SERVICE_NAME"; then
    print_service_diagnostics "$SERVICE_NAME"
    fatal_with_rollback "${SERVICE_NAME} 重启命令执行失败"
  fi

  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    print_service_diagnostics "$SERVICE_NAME"
    fatal_with_rollback "${SERVICE_NAME} 启动失败"
  fi
  verify_service_port_listening
}

build_link() {
  local link encoded_name encoded_spider_x encoded_xhttp_path encoded_sni encoded_alpn
  encoded_name="$(url_encode "$NODE_NAME")"

  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    encoded_xhttp_path="$(url_encode "$XHTTP_PATH")"
    encoded_sni="$(url_encode "$SNI")"
    encoded_alpn="$(printf '%s\n' "$XHTTP_CLIENT_ALPN_JSON" | jq -r 'join(",")' | jq -Rr @uri)"
    link="vless://${UUID}@${SERVER_HOST_FOR_LINK}:${PORT}?type=xhttp&security=tls&host=${encoded_sni}&path=${encoded_xhttp_path}&mode=auto&fp=chrome&sni=${encoded_sni}&alpn=${encoded_alpn}&flow=xtls-rprx-vision&encryption=${VLESS_ENC}#${encoded_name}"
    echo "$link"
    return 0
  fi

  encoded_spider_x="$(url_encode "$SPIDER_X")"
  link="vless://${UUID}@${SERVER_HOST_FOR_LINK}:${PORT}?type=raw&security=reality&pbk=${REALITY_PUB}${MLDSA_LINK_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=${encoded_spider_x}&flow=xtls-rprx-vision&encryption=${VLESS_ENC}#${encoded_name}"
  echo "$link"
}

print_optional_qr() {
  local link="$1" qr_ans install_qr_ans
  case "${NO_QR:-0}" in
    1|yes|YES|true|TRUE)
      info "Skipped QR output."
      return 0
      ;;
  esac
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    info "Skipped QR output in non-interactive mode."
    return 0
  fi

  read -r -p "Generate QR code? Long links may fail in qrencode. [y/N]: " qr_ans
  case "${qr_ans:-N}" in
    y|Y|yes|YES)
      if ! command -v qrencode >/dev/null 2>&1; then
        warn "qrencode is not installed."
        read -r -p "Install qrencode now? [y/N]: " install_qr_ans
        case "${install_qr_ans:-N}" in
          y|Y|yes|YES) install_packages qrencode ;;
          *) warn "Skipped QR output."; return 0 ;;
        esac
      fi
      qrencode -t ANSIUTF8 "$link" || warn "QR generation failed. Copy the vless:// link above instead."
      ;;
    *) warn "Skipped QR output." ;;
  esac
}

print_result() {
  local link="$1"
  if [[ "$DEPLOY_MODE" == "cdn-xhttp-tls" ]]; then
    echo
    ok "Build complete"
    info "Core: Xray-core"
    info "Mode: VLESS Encryption + XHTTP-TLS + Vision (CDN)"
    info "Config: ${CONFIG_PATH}"
    info "UUID: ${UUID}"
    info "TLS/SNI domain: ${SNI}"
    info "XHTTP path: ${XHTTP_PATH}"
    info "XHTTP transport: ${XHTTP_TRANSPORT_PROFILE}"
    info "Origin ALPN: ${XHTTP_ORIGIN_ALPN_JSON}; client ALPN: ${XHTTP_CLIENT_ALPN_JSON}"
    info "Certificate profile: ${TLS_CERT_MODE}"
    info "Flow: xtls-rprx-vision (keep client Xray-core current)"
    [[ "$TLS_CERT_MODE" == "cloudflare-origin" ]] && warn_cloudflare_origin_ca_scope
    info "Node name: ${NODE_NAME}"
    info "Routing: ${ROUTE_PROFILE} ($(routing_domain_strategy "$ROUTE_PROFILE")); unmatched traffic uses direct"
    info "Link length: ${#link} chars"
    echo
    echo "$link"
    echo
    print_optional_qr "$link"
    return 0
  fi

  echo
  ok "构建完成"
  info "核心：Xray-core"
  info "配置：${CONFIG_PATH}"
  info "UUID：${UUID}"
  info "SNI：${SNI}"
  info "shortId：${SHORT_ID}"
  info "节点名称：${NODE_NAME}"
  info "pbk：${REALITY_PUB}"
  info "路由：${ROUTE_PROFILE} ($(routing_domain_strategy "$ROUTE_PROFILE"))；未命中规则的流量默认 direct"
  info "链接长度：${#link} 字符"
  echo
  echo "$link"
  echo

  case "${NO_QR:-0}" in
    1|yes|YES|true|TRUE)
      info "已跳过二维码输出。"
      return 0
      ;;
  esac
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    info "非交互模式已跳过二维码输出。"
    return 0
  fi

  read -r -p "是否生成二维码？长链接可能导致 qrencode 失败。[y/N]: " qr_ans
  case "${qr_ans:-N}" in
    y|Y|yes|YES)
      if ! command -v qrencode >/dev/null 2>&1; then
        warn "未安装 qrencode。"
        read -r -p "是否现在安装 qrencode？[y/N]: " install_qr_ans
        case "${install_qr_ans:-N}" in
          y|Y|yes|YES)
            install_packages qrencode
            ;;
          *) warn "跳过二维码输出。"; return 0 ;;
        esac
      fi

      if ! qrencode -t ANSIUTF8 "$link"; then
        warn "二维码生成失败。通常是链接过长造成的；复制上面的 vless:// 链接即可。"
      fi
      ;;
    *)
      info "已跳过二维码输出。"
      ;;
  esac
}

show_help() {
  cat <<EOF2
freedom.sh ${SCRIPT_VERSION}

Usage:
  bash freedom.sh [options]

Without options, runs the original interactive deployment flow.
With any deployment option, runs non-interactively using defaults for omitted values.

Options:
  --port PORT                     Listen port. Default: ${DEFAULT_PORT}.
  --sni DOMAIN                    REALITY target SNI or XHTTP-TLS certificate/SNI domain. Default: ${DEFAULT_SNI}.
  --node-name NAME                Share link node name. Default: ${DEFAULT_NODE_NAME}.
  --server HOST_OR_IP             Public server address for the share link.
                                  In XHTTP-TLS mode, omit this to use SNI; set it for preferred CDN IP/hostname.
  --mode MODE                     1/REALITY-VISION or 2/XHTTP-TLS-VISION. Default: REALITY-VISION.
  --cdn-xhttp-tls                 Shortcut for --mode XHTTP-TLS-VISION.
  --xhttp-path PATH               XHTTP request path for CDN mode.
  --xhttp-profile PROFILE         CDN-STABLE, CDN-H2, CDN-H3, or DIRECT-H3. Default: CDN-STABLE.
                                  CDN-H3 keeps the Xray origin on TCP H1/H2 and requests H3 only at the CDN edge.
                                  DIRECT-H3 makes Xray listen on UDP and is an advanced CLI-only diagnostic.
  --xhttp-alpn PROFILE            Legacy alias: stable/h2/h3 map to CDN-STABLE/CDN-H2/DIRECT-H3.
  --tls-cert-file PATH            TLS certificate file for CDN mode.
  --tls-key-file PATH             TLS private key file for CDN mode.
  --tls-cert-mode MODE            1/PUBLIC CA or 2/CLOUDFLARE ORIGIN CA. Default: PUBLIC CA.
  --route-profile PROFILE         COMPATIBLE (AsIs) or STRICT (IPIfNonMatch). Default: COMPATIBLE.
  --xray-encryption MODE          x25519, ml-kem-768, or none. Default: x25519.
                                  XHTTP-TLS-VISION clients should use a current Xray-core-compatible implementation.
  --enable-mldsa                  Enable Xray ML-DSA-65 extra signature.
  --skip-sni-check                Skip SNI HTTPS reachability and latency checks.
  --skip-asn-check                Skip the advisory REALITY VPS/target ASN comparison.
  --allow-nonstandard-reality-port
                                  Explicitly allow REALITY to listen on a port other than TCP/443.
  --update-xray                   Update Xray through the official XTLS installer before deployment.
  --check, --preflight            Run read-only preflight checks and exit.
  --yes, -y                       Auto-confirm installer prompts.
  --no-qr                         Skip QR output.
  --version                       Print version.
  --help, -h                      Show this help.

Environment:
  FREEDOM_PORT=443
  FREEDOM_SNI=${DEFAULT_SNI}
  FREEDOM_NODE_NAME=${DEFAULT_NODE_NAME}
  FREEDOM_SERVER=1.2.3.4
  FREEDOM_MODE=reality|cdn-xhttp-tls
  FREEDOM_XHTTP_PATH=/cdn-random
  FREEDOM_XHTTP_PROFILE=cdn-stable|cdn-h2|cdn-h3|direct-h3
  FREEDOM_XHTTP_ALPN=stable|h2|h3  # legacy alias
  FREEDOM_TLS_CERT_FILE=/path/fullchain.pem
  FREEDOM_TLS_KEY_FILE=/path/privkey.pem
  FREEDOM_TLS_CERT_MODE=public|cloudflare-origin
  FREEDOM_ROUTE_PROFILE=compatible|strict
  FREEDOM_XRAY_ENCRYPTION=x25519
  FREEDOM_MLDSA=0|1
  FREEDOM_SNI_CHECK=0|1
  FREEDOM_SNI_CHECK_TIMEOUT=8
  FREEDOM_ASN_CHECK=0|1
  FREEDOM_ALLOW_NONSTANDARD_REALITY_PORT=0|1
  FREEDOM_UPDATE_XRAY=0|1
  FREEDOM_YES=1
  FREEDOM_NO_QR=1
EOF2
}

handle_cli() {
  [ "$#" -eq 0 ] && return 0
  NONINTERACTIVE=1
  NO_QR=1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        show_help
        exit 0
        ;;
      --version)
        printf '%s\n' "$SCRIPT_VERSION"
        exit 0
        ;;
      --port)
        shift
        require_option_value "--port" "${1:-}"
        CLI_PORT="$1"
        ;;
      --sni)
        shift
        require_option_value "--sni" "${1:-}"
        CLI_SNI="$1"
        ;;
      --node-name)
        shift
        require_option_value "--node-name" "${1:-}"
        CLI_NODE_NAME="$1"
        ;;
      --server)
        shift
        require_option_value "--server" "${1:-}"
        CLI_SERVER="$1"
        ;;
      --mode)
        shift
        require_option_value "--mode" "${1:-}"
        DEPLOY_MODE="$(normalize_deploy_mode "$1")" || usage_error "Invalid --mode: $1"
        ;;
      --cdn-xhttp-tls)
        DEPLOY_MODE="cdn-xhttp-tls"
        ;;
      --xhttp-path)
        shift
        require_option_value "--xhttp-path" "${1:-}"
        XHTTP_PATH="$1"
        ;;
      --xhttp-alpn)
        shift
        require_option_value "--xhttp-alpn" "${1:-}"
        XHTTP_TRANSPORT_PROFILE="$(normalize_xhttp_transport_profile "$1")" || usage_error "Invalid --xhttp-alpn: $1"
        ;;
      --xhttp-profile)
        shift
        require_option_value "--xhttp-profile" "${1:-}"
        XHTTP_TRANSPORT_PROFILE="$(normalize_xhttp_transport_profile "$1")" || usage_error "Invalid --xhttp-profile: $1"
        ;;
      --tls-cert-file)
        shift
        require_option_value "--tls-cert-file" "${1:-}"
        TLS_CERT_FILE="$1"
        ;;
      --tls-key-file)
        shift
        require_option_value "--tls-key-file" "${1:-}"
        TLS_KEY_FILE="$1"
        ;;
      --tls-cert-mode)
        shift
        require_option_value "--tls-cert-mode" "${1:-}"
        TLS_CERT_MODE="$(normalize_tls_cert_mode "$1")" || usage_error "Invalid --tls-cert-mode: $1"
        ;;
      --route-profile)
        shift
        require_option_value "--route-profile" "${1:-}"
        ROUTE_PROFILE="$(normalize_route_profile "$1")" || usage_error "Invalid --route-profile: $1"
        ;;
      --xray-encryption)
        shift
        require_option_value "--xray-encryption" "${1:-}"
        XRAY_ENCRYPTION_CHOICE="$1"
        ;;
      --enable-mldsa)
        ENABLE_MLDSA=1
        ;;
      --skip-sni-check)
        SNI_CHECK=0
        ;;
      --skip-asn-check)
        ASN_CHECK=0
        ;;
      --allow-nonstandard-reality-port)
        ALLOW_NONSTANDARD_REALITY_PORT=1
        ;;
      --update-xray)
        UPDATE_XRAY=1
        ;;
      --check|--preflight)
        CHECK_ONLY=1
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      --no-qr)
        NO_QR=1
        ;;
      *)
        usage_error "Unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  if [[ "${CHECK_ONLY:-0}" == "1" ]]; then
    preflight_check
    exit 0
  fi

  need_root
  ensure_systemd_available
  install_base_deps
  sync_time_best_effort
  ensure_xray_installed
  read_common_inputs
  ensure_xray_capabilities
  check_port_available_or_handle
  generate_assets
  backup_existing_config

  write_xray_config

  secure_config_permissions
  validate_config
  restart_service
  print_result "$(build_link)"
}

handle_cli "$@"
main "$@"
