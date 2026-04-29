#!/bin/bash
# v6.5 终极精修版 - 修复 sing-box 规则集引用与 Xray 命令兼容性

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# 1. 基础依赖
apt-get update -y > /dev/null 2>&1
apt-get install -y jq openssl curl uuid-runtime qrencode ntpdate cron iproute2 > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1

SERVER_IP=$(curl -s4 ifconfig.me)
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

clear
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v6.5${NC}"
read -p "请输入内核选项 [1: Xray, 2: sing-box, 默认 1]: " CORE_CHOICE
CORE_CHOICE=${CORE_CHOICE:-1}
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名 (默认 v1-dy.ixigua.com): " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

# ==========================================
# 模块 A: Xray 逻辑 (精修)
# ==========================================
if [ "$CORE_CHOICE" == "1" ]; then
    SERVICE_NAME="xray"
    CONFIG_PATH="/usr/local/etc/xray/config.json"
    systemctl stop xray > /dev/null 2>&1
    [ ! -f "/usr/local/bin/xray" ] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    echo -e "\n1) None / 2) X25519 / 3) ML-KEM-768"
    read -p "加密选择 [默认 3]: " ENC_CHOICE
    ENC_CHOICE=${ENC_CHOICE:-3}

    X_KEYS=$(xray x25519)
    X_PRIV=$(echo "$X_KEYS" | grep "Private key:" | awk '{print $3}')
    X_PUB=$(echo "$X_KEYS" | grep "Public key:" | awk '{print $3}')

    PQC_JSON=""
    M_VER_PARAM=""
    V_SRV="none"; V_CLI="none"

    if [ "$ENC_CHOICE" == "3" ]; then
        ML_OUT=$(xray mldsa65 2>/dev/null)
        if [ $? -eq 0 ] && [ ! -z "$ML_OUT" ]; then
            M_SEED=$(echo "$ML_OUT" | grep "Seed:" | awk '{print $2}')
            M_VER=$(echo "$ML_OUT" | grep "Verify:" | awk '{print $2}')
            PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
            M_VER_PARAM="&mldsa65Verify=$M_VER"
            # 兼容性检查：探测 vlessenc 命令
            if xray vlessenc --help > /dev/null 2>&1; then
                V_OUT=$(xray vlessenc 3 2>/dev/null)
                V_SRV=$(echo "$V_OUT" | grep "Server:" | awk '{print $2}')
                V_CLI=$(echo "$V_OUT" | grep "Client:" | awk '{print $2}')
            fi
        else
            ENC_CHOICE=2
        fi
    fi
    
    if [ "$ENC_CHOICE" == "2" ]; then
        if xray vlessenc --help > /dev/null 2>&1; then
            V_OUT=$(xray vlessenc 2 2>/dev/null)
            V_SRV=$(echo "$V_OUT" | grep "Server:" | awk '{print $2}')
            V_CLI=$(echo "$V_OUT" | grep "Client:" | awk '{print $2}')
        fi
    fi

    cat << EOF > $CONFIG_PATH
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
      "decryption": "$V_SRV"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "target": "$SNI:443", "xver": 0,
        "serverNames": [ "$SNI" ], "privateKey": "$X_PRIV",
        "shortIds": [ "$SHORT_ID" ], $PQC_JSON "maxTimeDiff": 60000
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["geosite:google", "geosite:github", "geosite:cloudflare"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }
}
EOF
    # 终极语法校验
    if ! xray -test -config $CONFIG_PATH > /dev/null 2>&1; then
        echo -e "${RED}❌ Xray 配置校验失败。请手动运行 xray -test -config $CONFIG_PATH 调试。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VER_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLI}#Premium-Node"

# ==========================================
# 模块 B: sing-box 逻辑 (精准适配 Rule-Set)
# ==========================================
elif [ "$CORE_CHOICE" == "2" ]; then
    SERVICE_NAME="sing-box"
    CONFIG_PATH="/etc/sing-box/config.json"
    systemctl stop sing-box > /dev/null 2>&1
    [ ! -f "/usr/bin/sing-box" ] && bash <(curl -fsSL https://sing-box.app/install.sh)
    
    SB_KEYS=$(sing-box generate reality-keypair)
    X_PRIV=$(echo "$SB_KEYS" | grep "PrivateKey:" | awk '{print $2}')
    X_PUB=$(echo "$SB_KEYS" | grep "PublicKey:" | awk '{print $2}')

    cat << EOF > $CONFIG_PATH
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless", "listen": "::", "listen_port": $PORT, "tcp_fast_open": true,
    "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
    "tls": {
      "enabled": true, "server_name": "$SNI",
      "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 }, "private_key": "$X_PRIV", "short_id": [ "$SHORT_ID" ] }
    }
  }],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geoip-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "update_interval": "1d"
      },
      {
        "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "update_interval": "1d"
      }
    ],
    "rules": [
      { "ip_is_private": true, "outbound": "block" },
      { "rule_set": ["geoip-cn", "geosite-cn"], "outbound": "block" }
    ],
    "final": "direct"
  }
}
EOF
    if ! sing-box check -c $CONFIG_PATH > /dev/null 2>&1; then
        echo -e "${RED}❌ sing-box 配置校验失败。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#Premium-Node"
fi

# 启动与结果输出
systemctl daemon-reload
systemctl enable $SERVICE_NAME > /dev/null 2>&1
systemctl restart $SERVICE_NAME

sleep 2
if systemctl is-active $SERVICE_NAME &> /dev/null; then
    echo -e "${GREEN}🎉 构建成功！脚本版本: v6.5 Final${NC}"
    echo -e "${CYAN}${LINK}${NC}"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 服务启动失败，请检查端口 $PORT 是否冲突。${NC}"
fi