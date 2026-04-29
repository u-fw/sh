#!/usr/bin/env bash
# freedom.sh v9.2-final
# VLESS + REALITY 自动配置脚本：用户选择 Xray-core / sing-box；缺失则用官方脚本安装
# - Xray-core: xray x25519 / uuid / vlessenc / mldsa65 / run -test
# - sing-box: sing-box generate reality-keypair / uuid / check

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_VERSION="v9.2-final"
DEFAULT_SNI="v1-dy.ixigua.com"
DEFAULT_PORT="443"

KERNEL=""
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
BLOCK_CN="true"

log() { echo -e "${CYAN}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
fatal() { echo -e "${RED}$*${NC}" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" == "0" ]] || fatal "❌ 请用 root 运行：sudo bash $0"
}

install_base_deps() {
  local missing=()
  for c in curl jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  command -v qrencode >/dev/null 2>&1 || missing+=("qrencode")

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  log "📦 安装基础依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}" >/dev/null
  else
    fatal "❌ 找不到支持的包管理器，请手动安装：${missing[*]}"
  fi
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

sanitize_sni() {
  local v="$1"
  v="${v#http://}"
  v="${v#https://}"
  v="${v%%/*}"
  v="${v%%:*}"
  echo "$v"
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
  # 用法：extract_vlessenc_value "文本" "ML-KEM-768" "decryption"
  local text="$1"
  local alg="$2"
  local key="$3"
  printf '%s\n' "$text" | awk -v alg="$alg" -v key="$key" '
    index($0, alg) { f = 1 }
    f && $0 ~ "\\\"" key "\\\"[[:space:]]*:" {
      line = $0
      sub(".*\\\"" key "\\\"[[:space:]]*:[[:space:]]*\\\"", "", line)
      while (line !~ /\"/) {
        if ((getline more) <= 0) break
        line = line more
      }
      sub("\\\".*", "", line)
      gsub(/[[:space:]\r\n,]/, "", line)
      print line
      exit
    }
  '
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
  ip="$(curl -fsS4 --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS4 --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "$ip"
}

install_xray_official() {
  log "⬇️ 使用 XTLS 官方 Xray-install 安装/更新 Xray-core..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || fatal "❌ Xray 安装后仍未找到 xray 命令"
  systemctl enable xray >/dev/null 2>&1 || true
}

install_singbox_official() {
  log "⬇️ 使用 sing-box 官方 install.sh 安装/更新 sing-box..."
  curl -fsSL https://sing-box.app/install.sh | sh
  command -v sing-box >/dev/null 2>&1 || fatal "❌ sing-box 安装后仍未找到 sing-box 命令"
  systemctl enable sing-box >/dev/null 2>&1 || true
}

ensure_selected_kernel_installed() {
  case "$KERNEL" in
    xray)
      if ! command -v xray >/dev/null 2>&1; then
        warn "⚠️ 未找到 xray。"
        read -r -p "👉 是否使用 XTLS 官方脚本安装 Xray-core？[Y/n]: " ans
        case "${ans:-Y}" in
          n|N|no|NO) fatal "❌ 已取消安装，退出。" ;;
          *) install_xray_official ;;
        esac
      fi
      BIN="$(command -v xray)"
      SERVICE_NAME="xray"
      CONFIG_DIR="/usr/local/etc/xray"
      CONFIG_PATH="$CONFIG_DIR/config.json"
      ;;
    sing-box)
      if ! command -v sing-box >/dev/null 2>&1; then
        warn "⚠️ 未找到 sing-box。"
        read -r -p "👉 是否使用 sing-box 官方脚本安装 sing-box？[Y/n]: " ans
        case "${ans:-Y}" in
          n|N|no|NO) fatal "❌ 已取消安装，退出。" ;;
          *) install_singbox_official ;;
        esac
      fi
      BIN="$(command -v sing-box)"
      SERVICE_NAME="sing-box"
      CONFIG_DIR="/etc/sing-box"
      CONFIG_PATH="$CONFIG_DIR/config.json"
      ;;
    *) fatal "内部错误：未知内核 $KERNEL" ;;
  esac
}

choose_kernel() {
  echo -e "\n${CYAN}请选择要部署的内核：${NC}"
  echo "1) Xray-core"
  echo "2) sing-box"
  while true; do
    read -r -p "👉 内核选择 [1/2，默认 1]: " ksel
    ksel="${ksel:-1}"
    case "$ksel" in
      1) KERNEL="xray"; break ;;
      2) KERNEL="sing-box"; break ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done
  ensure_selected_kernel_installed
}

read_common_inputs() {
  clear || true
  success "🚀 VLESS-REALITY 自动化构建 ${SCRIPT_VERSION}"
  echo -e "${CYAN}当前内核：${KERNEL} (${BIN})${NC}"

  while true; do
    read -r -p "👉 监听端口 (默认 ${DEFAULT_PORT}): " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    valid_port "$PORT" && break
    warn "端口无效，请输入 1-65535。"
  done

  read -r -p "👉 伪装域名/SNI (默认 ${DEFAULT_SNI}): " SNI
  SNI="$(sanitize_sni "${SNI:-$DEFAULT_SNI}")"
  [[ -n "$SNI" ]] || fatal "❌ SNI 不能为空"

  read -r -p "👉 是否保留原脚本的 CN/private 阻断路由？[Y/n]: " block_ans
  case "${block_ans:-Y}" in
    n|N|no|NO) BLOCK_CN="false" ;;
    *) BLOCK_CN="true" ;;
  esac

  SERVER_IP="$(get_public_ip)"
  if [[ -z "$SERVER_IP" ]]; then
    read -r -p "👉 未能自动获取公网 IP，请手动输入服务器地址/IP: " SERVER_IP
  fi
  [[ -n "$SERVER_IP" ]] || fatal "❌ 服务器地址/IP 不能为空"
  SERVER_HOST_FOR_LINK="$(url_host "$SERVER_IP")"
}

gen_uuid() {
  if [[ "$KERNEL" == "xray" ]]; then
    "$BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    "$BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  fi
}

gen_short_id() {
  openssl rand -hex 8 | tr -d '[:space:]'
}

gen_reality_keys_xray() {
  log "🔑 生成 Xray REALITY X25519 密钥..."
  local out
  out="$($BIN x25519 2>&1)" || { echo "$out"; fatal "❌ xray x25519 执行失败"; }
  echo "$out"

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private key|Private")"
  REALITY_PUB="$(field_after_colon "$out" "Password|PublicKey|Public key|Public")"

  # 兜底：新版 Xray 常见为 Password (PublicKey): xxx；如果 awk 仍然失败，用 grep/sed 再抓一次。
  if [[ -z "$REALITY_PUB" ]]; then
    REALITY_PUB="$(printf '%s\n' "$out" | grep -Ei '^\s*Password(\s*\([^)]*\))?\s*:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]\r\n\"' || true)"
  fi

  [[ -n "$REALITY_PRIV" ]] || { echo "$out"; fatal "❌ 未能提取 Xray PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { echo "$out"; fatal "❌ 未能提取 Xray Password/PublicKey，不能生成 pbk"; }
  [[ "$REALITY_PRIV" != *Private* && "$REALITY_PRIV" != *Password* ]] || fatal "❌ Xray 私钥提取异常：$REALITY_PRIV"
  log "✅ REALITY pbk：$REALITY_PUB"
}

gen_reality_keys_singbox() {
  log "🔑 生成 sing-box REALITY 密钥..."
  local out
  out="$($BIN generate reality-keypair 2>&1)" || { echo "$out"; fatal "❌ sing-box generate reality-keypair 执行失败"; }
  echo "$out"

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private key|Private")"
  REALITY_PUB="$(field_after_colon "$out" "PublicKey|Public key|Public")"

  [[ -n "$REALITY_PRIV" ]] || { echo "$out"; fatal "❌ 未能提取 sing-box PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { echo "$out"; fatal "❌ 未能提取 sing-box PublicKey，不能生成 pbk"; }
  log "✅ REALITY pbk：$REALITY_PUB"
}

gen_xray_vless_encryption() {
  echo -e "\n${CYAN}Xray VLESS Encryption：${NC}"
  echo "1) none，兼容性最好"
  echo "2) X25519，由 xray vlessenc 生成"
  echo "3) ML-KEM-768，由 xray vlessenc 生成"
  read -r -p "👉 选择加密 [默认 3]: " enc_choice
  enc_choice="${enc_choice:-3}"

  VLESS_DEC="none"
  VLESS_ENC="none"

  if [[ "$enc_choice" == "1" ]]; then
    return 0
  fi

  local out alg
  out="$($BIN vlessenc 2>&1)" || { echo "$out"; fatal "❌ xray vlessenc 执行失败。当前 Xray 可能过旧，请升级。"; }

  if [[ "$enc_choice" == "2" ]]; then
    alg="X25519"
  else
    alg="ML-KEM-768"
  fi

  VLESS_DEC="$(extract_vlessenc_value "$out" "$alg" "decryption")"
  VLESS_ENC="$(extract_vlessenc_value "$out" "$alg" "encryption")"

  [[ -n "$VLESS_DEC" && -n "$VLESS_ENC" ]] || {
    echo "$out"
    fatal "❌ 未能从 xray vlessenc 输出中提取 ${alg} 的 decryption/encryption"
  }
}

gen_xray_mldsa_optional() {
  echo -e "\n${CYAN}REALITY ML-DSA-65 额外签名：${NC}"
  warn "提示：开启后要求伪装目标证书链足够大；不确定时建议先关闭。"
  read -r -p "👉 是否开启 ML-DSA-65？[y/N]: " ans
  case "${ans:-N}" in
    y|Y|yes|YES) ;;
    *) return 0 ;;
  esac

  local out
  out="$($BIN mldsa65 2>&1)" || { echo "$out"; fatal "❌ xray mldsa65 执行失败。当前 Xray 可能过旧，请升级。"; }
  echo "$out"

  MLDSA_SEED="$(field_after_colon "$out" "Seed")"
  MLDSA_VERIFY="$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*Verify[[:space:]]*:/,$p' | sed '1s/^[^:]*:[[:space:]]*//' | tr -d '\n\r[:space:]')"

  [[ -n "$MLDSA_SEED" && -n "$MLDSA_VERIFY" ]] || { echo "$out"; fatal "❌ 未能提取 mldsa65 Seed/Verify"; }
  MLDSA_LINK_PARAM="&pqv=${MLDSA_VERIFY}"
}

generate_assets() {
  UUID="$(gen_uuid | tr -d '[:space:]')"
  SHORT_ID="$(gen_short_id)"
  [[ -n "$UUID" && -n "$SHORT_ID" ]] || fatal "❌ UUID 或 shortId 生成失败"

  if [[ "$KERNEL" == "xray" ]]; then
    gen_reality_keys_xray
    gen_xray_vless_encryption
    gen_xray_mldsa_optional
  else
    gen_reality_keys_singbox
    VLESS_DEC="none"
    VLESS_ENC="none"
    MLDSA_LINK_PARAM=""
  fi
}

backup_existing_config() {
  install -d -m 755 "$CONFIG_DIR"
  if [[ -f "$CONFIG_PATH" ]]; then
    local bak="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_PATH" "$bak"
    warn "已备份旧配置：$bak"
  fi
}

write_xray_config() {
  local block_cn_json
  if [[ "$BLOCK_CN" == "true" ]]; then
    block_cn_json='[
      {"type":"field","ip":["geoip:cn","geoip:private"],"outboundTag":"block"},
      {"type":"field","domain":["geosite:cn"],"outboundTag":"block"}
    ]'
  else
    block_cn_json='[]'
  fi

  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg vdec "$VLESS_DEC" \
    --arg sni "$SNI" \
    --arg private_key "$REALITY_PRIV" \
    --arg short_id "$SHORT_ID" \
    --arg mldsa_seed "$MLDSA_SEED" \
    --argjson rules "$block_cn_json" \
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
            network: "tcp",
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
      routing: { rules: $rules }
    }' > "$CONFIG_PATH"
}

write_singbox_config() {
  local route_set_json rules_json
  if [[ "$BLOCK_CN" == "true" ]]; then
    route_set_json='[
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "direct"
      }
    ]'
    rules_json='[
      {"ip_is_private": true, "action": "route", "outbound": "block"},
      {"rule_set": "geosite-cn", "action": "route", "outbound": "block"},
      {"rule_set": "geoip-cn", "action": "route", "outbound": "block"}
    ]'
  else
    route_set_json='[]'
    rules_json='[]'
  fi

  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg private_key "$REALITY_PRIV" \
    --arg short_id "$SHORT_ID" \
    --argjson route_set "$route_set_json" \
    --argjson rules "$rules_json" \
    '
    {
      log: { level: "warn", timestamp: true },
      inbounds: [
        {
          type: "vless",
          tag: "vless-in",
          listen: "::",
          listen_port: $port,
          users: [ { uuid: $uuid, flow: "xtls-rprx-vision" } ],
          tls: {
            enabled: true,
            server_name: $sni,
            reality: {
              enabled: true,
              handshake: { server: $sni, server_port: 443 },
              private_key: $private_key,
              short_id: [ $short_id ],
              max_time_difference: "1m"
            }
          }
        }
      ],
      outbounds: [
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" }
      ],
      route: {
        rule_set: $route_set,
        rules: $rules,
        final: "direct"
      },
      experimental: {
        cache_file: { enabled: true }
      }
    }' > "$CONFIG_PATH"
}

validate_config() {
  log "🧪 检查配置文件..."
  jq empty "$CONFIG_PATH" || fatal "❌ JSON 语法错误：$CONFIG_PATH"

  if [[ "$KERNEL" == "xray" ]]; then
    if ! "$BIN" run -test -c "$CONFIG_PATH" >/tmp/freedom-xray-test.log 2>&1; then
      if ! "$BIN" -test -config "$CONFIG_PATH" >/tmp/freedom-xray-test.log 2>&1; then
        cat /tmp/freedom-xray-test.log >&2
        fatal "❌ Xray 配置测试失败"
      fi
    fi
  else
    "$BIN" check -c "$CONFIG_PATH" >/tmp/freedom-singbox-check.log 2>&1 || {
      cat /tmp/freedom-singbox-check.log >&2
      fatal "❌ sing-box 配置测试失败"
    }
  fi
}

restart_service() {
  log "🔁 重启服务：$SERVICE_NAME"

  if ! systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service"; then
    warn "⚠️ 没找到 systemd 服务 ${SERVICE_NAME}.service，仅已写入配置：$CONFIG_PATH"
    return 0
  fi

  systemctl restart "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" || {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    fatal "❌ ${SERVICE_NAME} 启动失败"
  }
}

build_link() {
  local link
  link="vless://${UUID}@${SERVER_HOST_FOR_LINK}:${PORT}?type=tcp&security=reality&pbk=${REALITY_PUB}${MLDSA_LINK_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${VLESS_ENC}#Premium-Node"
  echo "$link"
}

print_result() {
  local link="$1"
  echo
  success "🎉 构建完成"
  echo -e "${CYAN}内核：${KERNEL}${NC}"
  echo -e "${CYAN}配置：${CONFIG_PATH}${NC}"
  echo -e "${CYAN}UUID：${UUID}${NC}"
  echo -e "${CYAN}SNI：${SNI}${NC}"
  echo -e "${CYAN}shortId：${SHORT_ID}${NC}"
  echo -e "${CYAN}pbk：${REALITY_PUB}${NC}"
  echo
  echo -e "${GREEN}${link}${NC}"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$link" || true
  else
    warn "未安装 qrencode，跳过二维码输出。"
  fi
}

main() {
  need_root
  install_base_deps
  sync_time_best_effort
  choose_kernel
  read_common_inputs
  generate_assets
  backup_existing_config

  if [[ "$KERNEL" == "xray" ]]; then
    write_xray_config
  else
    write_singbox_config
  fi

  chmod 644 "$CONFIG_PATH"
  validate_config
  restart_service
  print_result "$(build_link)"
}

main "$@"
