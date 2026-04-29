#!/usr/bin/env bash
# freedom.sh v9.0-final
# VLESS + REALITY 自动配置脚本：分别适配 Xray-core / sing-box
# - Xray: 使用 xray x25519 / uuid / vlessenc / mldsa65 / run -test
# - sing-box: 使用 sing-box generate reality-keypair / uuid / rand / check

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_VERSION="v9.0-final"
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

install_deps() {
  local missing=()
  for c in jq curl openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  command -v qrencode >/dev/null 2>&1 || missing+=("qrencode")

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  log "📦 安装依赖：${missing[*]}"
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
  # 用法：field_after_colon "文本" "PrivateKey|Private"
  local text="$1"
  local pattern="$2"
  echo "$text" | awk -F':[[:space:]]*' -v pat="$pattern" '
    BEGIN { IGNORECASE=1 }
    $1 ~ ("^(" pat ")$") { gsub(/[[:space:]\r\n\"]/, "", $2); print $2; exit }
  '
}

first_json_value_after_marker() {
  # 用法：first_json_value_after_marker "文本" "Authentication: ML-KEM-768" "decryption"
  # 兼容 xray vlessenc 当前的“分段文本 + JSON 字段”输出。
  local text="$1"
  local marker="$2"
  local key="$3"
  echo "$text" | awk -v marker="$marker" -v key="$key" '
    index($0, marker) { f=1; next }
    f && $0 ~ "\"" key "\"[[:space:]]*:" {
      line=$0
      sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
      while (line !~ /\"/) {
        if ((getline more) <= 0) break
        line=line more
      }
      sub("\".*", "", line)
      gsub(/[[:space:]\r\n]/, "", line)
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

choose_kernel() {
  local has_xray="false"
  local has_sing="false"
  command -v xray >/dev/null 2>&1 && has_xray="true"
  command -v sing-box >/dev/null 2>&1 && has_sing="true"

  echo -e "\n${CYAN}请选择内核：${NC}"
  echo "1) 自动检测"
  echo "2) Xray-core"
  echo "3) sing-box"
  read -r -p "👉 内核选择 [默认 1]: " ksel
  ksel="${ksel:-1}"

  case "$ksel" in
    2) [[ "$has_xray" == "true" ]] || fatal "❌ 未找到 xray 可执行文件"; KERNEL="xray" ;;
    3) [[ "$has_sing" == "true" ]] || fatal "❌ 未找到 sing-box 可执行文件"; KERNEL="sing-box" ;;
    1|*)
      if [[ "$has_xray" == "true" ]]; then
        KERNEL="xray"
      elif [[ "$has_sing" == "true" ]]; then
        KERNEL="sing-box"
      else
        fatal "❌ 未找到 xray 或 sing-box。请先安装其中一个内核。"
      fi
      ;;
  esac

  if [[ "$KERNEL" == "xray" ]]; then
    BIN="$(command -v xray)"
    SERVICE_NAME="xray"
    CONFIG_DIR="/usr/local/etc/xray"
    CONFIG_PATH="$CONFIG_DIR/config.json"
  else
    BIN="$(command -v sing-box)"
    SERVICE_NAME="sing-box"
    CONFIG_DIR="/etc/sing-box"
    CONFIG_PATH="$CONFIG_DIR/config.json"
  fi
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
  local sid=""
  if [[ "$KERNEL" == "sing-box" ]]; then
    sid="$($BIN generate rand --hex 8 2>/dev/null || true)"
  fi
  [[ -n "$sid" ]] || sid="$(openssl rand -hex 8)"
  echo "$sid" | tr -d '[:space:]'
}

gen_reality_keys_xray() {
  log "🔑 生成 Xray REALITY X25519 密钥..."
  local out
  out="$($BIN x25519 2>&1)" || { echo "$out"; fatal "❌ xray x25519 执行失败"; }

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private")"
  # 新版 Xray 客户端侧字段叫 Password；部分旧输出/第三方构建可能仍显示 PublicKey/Public。
  REALITY_PUB="$(field_after_colon "$out" "Password|PublicKey|Public")"

  [[ -n "$REALITY_PRIV" ]] || { echo "$out"; fatal "❌ 未能提取 Xray PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { echo "$out"; fatal "❌ 未能提取 Xray Password/PublicKey，不能生成 pbk"; }
  [[ "$REALITY_PRIV" != *Private* && "$REALITY_PRIV" != *Password* ]] || fatal "❌ Xray 私钥提取异常：$REALITY_PRIV"
}

gen_reality_keys_singbox() {
  log "🔑 生成 sing-box REALITY 密钥..."
  local out
  out="$($BIN generate reality-keypair 2>&1)" || { echo "$out"; fatal "❌ sing-box generate reality-keypair 执行失败"; }

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private")"
  REALITY_PUB="$(field_after_colon "$out" "PublicKey|Public")"

  [[ -n "$REALITY_PRIV" ]] || { echo "$out"; fatal "❌ 未能提取 sing-box PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { echo "$out"; fatal "❌ 未能提取 sing-box PublicKey，不能生成 pbk"; }
}

gen_xray_vless_encryption() {
  echo -e "\n${CYAN}Xray VLESS Encryption：${NC}"
  echo "1) none，兼容性最好"
  echo "2) X25519 认证，由 xray vlessenc 生成"
  echo "3) ML-KEM-768 认证，由 xray vlessenc 生成，后量子认证"
  read -r -p "👉 选择加密 [默认 3]: " enc_choice
  enc_choice="${enc_choice:-3}"

  VLESS_DEC="none"
  VLESS_ENC="none"

  if [[ "$enc_choice" == "1" ]]; then
    return 0
  fi

  "$BIN" help 2>/dev/null | grep -q "vlessenc" || fatal "❌ 当前 Xray 不支持 vlessenc，请升级 Xray-core"

  local out marker
  out="$($BIN vlessenc 2>&1)" || { echo "$out"; fatal "❌ xray vlessenc 执行失败"; }

  if [[ "$enc_choice" == "2" ]]; then
    marker="Authentication: X25519"
  else
    marker="Authentication: ML-KEM-768"
  fi

  VLESS_DEC="$(first_json_value_after_marker "$out" "$marker" "decryption")"
  VLESS_ENC="$(first_json_value_after_marker "$out" "$marker" "encryption")"

  [[ -n "$VLESS_DEC" && -n "$VLESS_ENC" ]] || {
    echo "$out"
    fatal "❌ 未能从 xray vlessenc 输出中提取 decryption/encryption"
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

  "$BIN" help 2>/dev/null | grep -q "mldsa65" || fatal "❌ 当前 Xray 不支持 mldsa65，请升级 Xray-core"

  log "🧬 生成 Xray ML-DSA-65 Seed/Verify..."
  local out
  out="$($BIN mldsa65 2>&1)" || { echo "$out"; fatal "❌ xray mldsa65 执行失败"; }

  MLDSA_SEED="$(field_after_colon "$out" "Seed")"
  # Verify 可能很长，保留从 Verify: 到结尾并拍平成一行。
  MLDSA_VERIFY="$(echo "$out" | sed -n '/^[[:space:]]*Verify[[:space:]]*:/,$p' | sed '1s/^[^:]*:[[:space:]]*//' | tr -d '\n\r[:space:]')"

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
            curve_preferences: ["X25519MLKEM768", "X25519"],
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
  install_deps
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
