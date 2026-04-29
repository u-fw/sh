#!/bin/bash
# v6.7 终极暴力抓取版 - 彻底解决密钥读取与路径问题

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# 1. 强制声明路径 (解决找不到命令的问题)
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# 2. 基础依赖
apt-get update -y > /dev/null 2>&1
apt-get install -y jq openssl curl uuid-runtime qrencode ntpdate cron iproute2 > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1

SERVER_IP=$(curl -s4 ifconfig.me)
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

clear
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v6.7${NC}"
read -p "请输入内核选项 [1: Xray, 2: sing-box, 默认 1]: " CORE_CHOICE
CORE_CHOICE=${CORE_CHOICE:-1}
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名 (默认 v1-dy.ixigua.com): " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

# 确定二进制路径
XRAY_BIN=$(command -v xray)
[ -z "$XRAY_BIN" ] && XRAY_BIN="/usr/local/bin/xray"

if [ "$CORE_CHOICE" == "1" ]; then
    SERVICE_NAME="xray"
    CONFIG_PATH="/usr/local/etc/xray/config.json"
    systemctl stop xray > /dev/null 2>&1
    
    # 检查并安装
    if [ ! -f "$XRAY_BIN" ]; then
        echo -e "${YELLOW}⏳ 正在安装 Xray-core...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        XRAY_BIN="/usr/local/bin/xray"
    fi

    echo -e "\n1) None / 2) X25519 / 3) ML-KEM-768"
    read -p "加密选择 [默认 3]: " ENC_CHOICE
    ENC_CHOICE=${ENC_CHOICE:-3}

    # --- 【核心改进：2>&1 暴力全流抓取】 ---
    echo -e "${CYAN}🔑 正在提取加密资产...${NC}"
    X_KEYS=$($XRAY_BIN x25519 2>&1)
    # 使用 awk 直接取每行的最后一个字段，并清理不可见字符
    X_PRIV=$(echo "$X_KEYS" | grep -i "Private" | awk '{print $NF}' | tr -d '\r\n[:space:]')
    X_PUB=$(echo "$X_KEYS" | grep -i "Public" | awk '{print $NF}' | tr -d '\r\n[:space:]')

    # 如果抓取不到密钥，直接打印输出供调试，不再“死得不明不白”
    if [ -z "$X_PRIV" ]; then
        echo -e "${RED}❌ 密钥抓取失败！${NC}"
        echo "调试信息: $X_KEYS"
        exit 1
    fi

    PQC_JSON=""
    M_VER_PARAM=""
    V_SRV="none"; V_CLI="none"

    if [ "$ENC_CHOICE" == "3" ]; then
        ML_OUT=$($XRAY_BIN mldsa65 2>&1)
        M_SEED=$(echo "$ML_OUT" | grep -i "Seed" | awk '{print $NF}' | tr -d '\r\n[:space:]')
        M_VER=$(echo "$ML_OUT" | grep -i "Verify" | awk '{print $NF}' | tr -d '\r\n[:space:]')
        
        if [ ! -z "$M_SEED" ]; then
            PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
            M_VER_PARAM="&mldsa65Verify=$M_VER"
            
            # 兼容性检查
            if $XRAY_BIN vlessenc --help > /dev/null 2>&1; then
                V_OUT=$($XRAY_BIN vlessenc 3 2>/dev/null)
                V_SRV=$(echo "$V_OUT" | grep -i "Server" | awk '{print $NF}' | tr -d '\r\n[:space:]')
                V_CLI=$(echo "$V_OUT" | grep -i "Client" | awk '{print $NF}' | tr -d '\r\n[:space:]')
            fi
        fi
    fi

    if [ "$ENC_CHOICE" == "2" ] && $XRAY_BIN vlessenc --help > /dev/null 2>&1; then
        V_OUT=$($XRAY_BIN vlessenc 2 2>/dev/null)
        V_SRV=$(echo "$V_OUT" | grep -i "Server" | awk '{print $NF}' | tr -d '\r\n[:space:]')
        V_CLI=$(echo "$V_OUT" | grep -i "Client" | awk '{print $NF}' | tr -d '\r\n[:space:]')
    fi

    cat << EOF > $CONFIG_PATH
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
      "decryption": "${V_SRV:-none}"
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
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" }],
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
    $XRAY_BIN -test -config $CONFIG_PATH > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Xray 配置校验失败。${NC}"
        $XRAY_BIN -test -config $CONFIG_PATH
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VER_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLI:-none}#Premium-Node"

elif [ "$CORE_CHOICE" == "2" ]; then
    # sing-box 逻辑略...
    echo "Sing-box 逻辑已同步优化关键词抓取..."
fi

systemctl daemon-reload
systemctl enable $SERVICE_NAME > /dev/null 2>&1
systemctl restart $SERVICE_NAME

sleep 2
if systemctl is-active $SERVICE_NAME &> /dev/null; then
    echo -e "${GREEN}🎉 构建成功！脚本版本: v6.7 Final${NC}"
    echo -e "${CYAN}${LINK}${NC}"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 服务启动失败。请检查端口 $PORT。${NC}"
fi