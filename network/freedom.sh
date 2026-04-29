#!/bin/bash

# ==========================================
# VLESS-REALITY-PQC 脚本 v6.3 (精准手术版)
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# 基础依赖安装
apt-get update -y > /dev/null 2>&1
apt-get install -y jq openssl curl uuid-runtime qrencode ntpdate cron iproute2 > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1

SERVER_IP=$(curl -s4 ifconfig.me)
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

clear
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v6.3${NC}"
echo -e "请选择内核组件："
echo -e "  1) Xray-core"
echo -e "  2) sing-box"
read -p "请输入选项 [1-2, 默认 1]: " CORE_CHOICE
CORE_CHOICE=${CORE_CHOICE:-1}

read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名 (默认 v1-dy.ixigua.com): " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

# --- 端口冲突精准检查 ---
PID_USING_PORT=$(ss -tlnp | grep ":$PORT " | awk -F'pid=' '{print $2}' | cut -d',' -f1)
if [ ! -z "$PID_USING_PORT" ]; then
    PROC_NAME=$(ps -p $PID_USING_PORT -o comm=)
    echo -e "${YELLOW}⚠️ 端口 $PORT 被 $PROC_NAME (PID: $PID_USING_PORT) 占用。${NC}"
    if [[ "$PROC_NAME" == "xray" || "$PROC_NAME" == "sing-box" ]]; then
        echo -e "${CYAN}检测到是旧版内核，正在自动清理...${NC}"
        kill -9 $PID_USING_PORT
    else
        echo -e "${RED}❌ 端口被其他服务占用，请更换端口重新运行脚本。${NC}"
        exit 1
    fi
fi

# ==========================================
# 模块 A: Xray 逻辑
# ==========================================
if [ "$CORE_CHOICE" == "1" ]; then
    SERVICE_NAME="xray"
    CONFIG_PATH="/usr/local/etc/xray/config.json"
    
    # 安装与清理
    systemctl stop xray > /dev/null 2>&1
    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    echo -e "\n1) None / 2) X25519 / 3) ML-KEM-768\n"
    read -p "加密选择 [默认 3]: " ENC_CHOICE
    ENC_CHOICE=${ENC_CHOICE:-3}

    X_KEYS=$(xray x25519)
    X_PRIV=$(echo "$X_KEYS" | grep "Private key:" | awk '{print $3}')
    X_PUB=$(echo "$X_KEYS" | grep "Public key:" | awk '{print $3}')

    # PQC 适配逻辑
    PQC_JSON=""
    M_VERIFY_PARAM=""
    V_SERVER="none"; V_CLIENT="none"

    if [ "$ENC_CHOICE" == "3" ]; then
        ML_OUT=$(xray mldsa65 2>/dev/null)
        if [ $? -eq 0 ] && [ ! -z "$ML_OUT" ]; then
            M_SEED=$(echo "$ML_OUT" | grep "Seed:" | awk '{print $2}')
            M_VERIFY=$(echo "$ML_OUT" | grep "Verify:" | awk '{print $2}')
            PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
            M_VERIFY_PARAM="&mldsa65Verify=$M_VERIFY"
            V_OUT=$(xray vlessenc 3 2>/dev/null)
            V_SERVER=$(echo "$V_OUT" | grep "Server:" | awk '{print $2}')
            V_CLIENT=$(echo "$V_OUT" | grep "Client:" | awk '{print $2}')
        else
            ENC_CHOICE=2
        fi
    fi

    if [ "$ENC_CHOICE" == "2" ]; then
        V_OUT=$(xray vlessenc 2 2>/dev/null)
        V_SERVER=$(echo "$V_OUT" | grep "Server:" | awk '{print $2}')
        V_CLIENT=$(echo "$V_OUT" | grep "Client:" | awk '{print $2}')
    fi

    cat << EOF > $CONFIG_PATH
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
      "decryption": "$V_SERVER"
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
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }],
  "routing": { "rules": [{ "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" }] }
}
EOF
    # 语法校验
    if ! xray -test -config $CONFIG_PATH > /dev/null 2>&1; then
        echo -e "${RED}❌ Xray 配置校验失败。可能是版本不支持当前参数。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VERIFY_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision&encryption=${V_CLIENT}#Premium-Node"

# ==========================================
# 模块 B: sing-box 逻辑
# ==========================================
elif [ "$CORE_CHOICE" == "2" ]; then
    SERVICE_NAME="sing-box"
    CONFIG_PATH="/etc/sing-box/config.json"

    systemctl stop sing-box > /dev/null 2>&1
    if ! command -v sing-box &> /dev/null; then
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    SB_KEYS=$(sing-box generate reality-keypair)
    X_PRIV=$(echo "$SB_KEYS" | grep "PrivateKey:" | awk '{print $2}')
    X_PUB=$(echo "$SB_KEYS" | grep "PublicKey:" | awk '{print $2}')

    cat << EOF > $CONFIG_PATH
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless", "listen": "::", "listen_port": $PORT,
    "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
    "tls": {
      "enabled": true, "server_name": "$SNI",
      "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 }, "private_key": "$X_PRIV", "short_id": [ "$SHORT_ID" ] }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rule_set": [{
        "tag": "geoip-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
    }],
    "rules": [{ "rule_set": "geoip-cn", "outbound": "direct" }]
  }
}
EOF
    # 语法校验
    if ! sing-box check -c $CONFIG_PATH > /dev/null 2>&1; then
        echo -e "${RED}❌ sing-box 配置校验失败。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Premium-Node"
fi

# 启动服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME > /dev/null 2>&1
systemctl restart $SERVICE_NAME

sleep 2
if systemctl is-active $SERVICE_NAME &> /dev/null; then
    echo -e "${GREEN}🎉 $SERVICE_NAME 构建成功！${NC}"
    echo -e "${CYAN}${LINK}${NC}"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 服务启动失败，请检查端口 $PORT。${NC}"
fi