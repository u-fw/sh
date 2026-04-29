#!/bin/bash
# v6.6 稳如老狗版 - 修复密钥抓取失效问题

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# 1. 环境准备
apt-get update -y > /dev/null 2>&1
apt-get install -y jq openssl curl uuid-runtime qrencode ntpdate cron iproute2 > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1

SERVER_IP=$(curl -s4 ifconfig.me)
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

clear
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v6.6${NC}"
read -p "请输入内核选项 [1: Xray, 2: sing-box, 默认 1]: " CORE_CHOICE
CORE_CHOICE=${CORE_CHOICE:-1}
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名 (默认 v1-dy.ixigua.com): " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

if [ "$CORE_CHOICE" == "1" ]; then
    SERVICE_NAME="xray"
    CONFIG_PATH="/usr/local/etc/xray/config.json"
    systemctl stop xray > /dev/null 2>&1
    [ ! -f "/usr/local/bin/xray" ] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    echo -e "\n1) None / 2) X25519 / 3) ML-KEM-768"
    read -p "加密选择 [默认 3]: " ENC_CHOICE
    ENC_CHOICE=${ENC_CHOICE:-3}

    # --- 【核心修复：鲁棒性抓取密钥】 ---
    echo -e "${CYAN}🔑 正在生成 REALITY 密钥对...${NC}"
    X_KEYS=$(xray x25519 2>/dev/null)
    X_PRIV=$(echo "$X_KEYS" | grep -i "Private key" | cut -d: -f2 | tr -d '[:space:]')
    X_PUB=$(echo "$X_KEYS" | grep -i "Public key" | cut -d: -f2 | tr -d '[:space:]')

    # 二次校验：如果还是空，说明 xray 命令执行有问题
    if [ -z "$X_PRIV" ] || [ -z "$X_PUB" ]; then
        echo -e "${RED}❌ 错误：无法生成 REALITY 密钥！请尝试手动运行 'xray x25519' 查看输出。${NC}"
        exit 1
    fi

    PQC_JSON=""
    M_VER_PARAM=""
    V_SRV="none"; V_CLI="none"

    if [ "$ENC_CHOICE" == "3" ]; then
        ML_OUT=$(xray mldsa65 2>/dev/null)
        if [ $? -eq 0 ] && [ ! -z "$ML_OUT" ]; then
            M_SEED=$(echo "$ML_OUT" | grep -i "Seed" | cut -d: -f2 | tr -d '[:space:]')
            M_VER=$(echo "$ML_OUT" | grep -i "Verify" | cut -d: -f2 | tr -d '[:space:]')
            [ ! -z "$M_SEED" ] && PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
            [ ! -z "$M_VER" ] && M_VER_PARAM="&mldsa65Verify=$M_VER"
            
            if xray vlessenc --help > /dev/null 2>&1; then
                V_OUT=$(xray vlessenc 3 2>/dev/null)
                V_SRV=$(echo "$V_OUT" | grep -i "Server" | cut -d: -f2 | tr -d '[:space:]')
                V_CLI=$(echo "$V_OUT" | grep -i "Client" | cut -d: -f2 | tr -d '[:space:]')
            fi
        else
            ENC_CHOICE=2
        fi
    fi

    if [ "$ENC_CHOICE" == "2" ] && xray vlessenc --help > /dev/null 2>&1; then
        V_OUT=$(xray vlessenc 2 2>/dev/null)
        V_SRV=$(echo "$V_OUT" | grep -i "Server" | cut -d: -f2 | tr -d '[:space:]')
        V_CLI=$(echo "$V_OUT" | grep -i "Client" | cut -d: -f2 | tr -d '[:space:]')
    fi

    # 兜底：防止变量解析失败导致空字符串
    V_SRV=${V_SRV:-"none"}
    V_CLI=${V_CLI:-"none"}

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
    # 语法校验
    if ! xray -test -config $CONFIG_PATH > /dev/null 2>&1; then
        echo -e "${RED}❌ Xray 配置校验仍未通过。版本号：$(xray -version | head -n1)${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VER_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLI}#Premium-Node"

elif [ "$CORE_CHOICE" == "2" ]; then
    # sing-box 逻辑保持不变，但增加同样的鲁棒抓取
    SERVICE_NAME="sing-box"
    CONFIG_PATH="/etc/sing-box/config.json"
    systemctl stop sing-box > /dev/null 2>&1
    [ ! -f "/usr/bin/sing-box" ] && bash <(curl -fsSL https://sing-box.app/install.sh)
    
    SB_KEYS=$(sing-box generate reality-keypair)
    X_PRIV=$(echo "$SB_KEYS" | grep -i "PrivateKey" | cut -d: -f2 | tr -d '[:space:]')
    X_PUB=$(echo "$SB_KEYS" | grep -i "PublicKey" | cut -d: -f2 | tr -d '[:space:]')

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
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      },
      {
        "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
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
    if ! sing-box check -c $CONFIG_PATH > /dev/null 2>&1; then echo "❌ sing-box 校验失败"; exit 1; fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#Premium-Node"
fi

systemctl daemon-reload
systemctl enable $SERVICE_NAME > /dev/null 2>&1
systemctl restart $SERVICE_NAME

sleep 2
if systemctl is-active $SERVICE_NAME &> /dev/null; then
    echo -e "${GREEN}🎉 构建成功！脚本版本: v6.6 Final${NC}"
    echo -e "${CYAN}${LINK}${NC}"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 服务启动失败。请检查端口 $PORT。${NC}"
fi