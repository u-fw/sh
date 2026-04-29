#!/bin/bash
# v8.1 终极进化版 - 支持 X25519 与 PQC 双重动态协议提取

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# 1. 环境准备
apt-get update -y > /dev/null 2>&1
apt-get install -y jq openssl curl uuid-runtime qrencode ntpdate > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1

SERVER_IP=$(curl -s4 ifconfig.me)
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

clear
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v8.1 (全动态匹配)${NC}"
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名: " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

# 2. 内核资产生成
XRAY_BIN=$(command -v xray)
[ -z "$XRAY_BIN" ] && XRAY_BIN="/usr/local/bin/xray"

# 3. 提取 REALITY 基础密钥对 (拍平处理，防止缩进干扰)
X_KEYS=$($XRAY_BIN x25519 2>&1 | tr -d '\n\r')
X_PRIV=$(echo "$X_KEYS" | sed 's/.*Private key: //g' | sed 's/Public key:.*//g' | tr -d '[:space:]')
X_PUB=$(echo "$X_KEYS" | sed 's/.*Public key: //g' | tr -d '[:space:]')

# 4. 加密协议选择
echo -e "\n1) None / 2) X25519 (经典动态) / 3) ML-KEM-768 (后量子动态)"
read -p "选择加密 [默认 3]: " ENC_CHOICE
ENC_CHOICE=${ENC_CHOICE:-3}

V_SRV="none"; V_CLI="none"; PQC_JSON=""; M_VER_PARAM=""

# 5. 核心逻辑：按块提取加密字符串
V_OUT=$($XRAY_BIN vlessenc 2>&1)

if [ "$ENC_CHOICE" == "3" ]; then
    # 【后量子提取】
    echo -e "${CYAN}🧬 提取 ML-KEM-768 动态资产...${NC}"
    V_SRV=$(echo "$V_OUT" | awk '/ML-KEM-768/{f=1} f&&/"decryption":/{print $2; exit}' | tr -d '",')
    V_CLI=$(echo "$V_OUT" | awk '/ML-KEM-768/{f=1} f&&/"encryption":/{print $2; exit}' | tr -d '",')
    
    # 提取超长 Verify
    ML_RAW=$($XRAY_BIN mldsa65 2>&1)
    M_SEED=$(echo "$ML_RAW" | grep "Seed:" | awk '{print $2}' | tr -d '[:space:]')
    M_VER=$(echo "$ML_RAW" | sed -n '/Verify:/,$p' | sed 's/Verify: //' | tr -d '\n\r[:space:]')
    
    PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
    M_VER_PARAM="&mldsa65Verify=$M_VER"

elif [ "$ENC_CHOICE" == "2" ]; then
    # 【X25519 动态提取】对应你 image_c19936.png 里的第一个块
    echo -e "${CYAN} klasik 提取 X25519 动态资产...${NC}"
    V_SRV=$(echo "$V_OUT" | awk '/X25519/{f=1} f&&/"decryption":/{print $2; exit}' | tr -d '",')
    V_CLI=$(echo "$V_OUT" | awk '/X25519/{f=1} f&&/"encryption":/{print $2; exit}' | tr -d '",')
fi

# 检查资产是否为空 (防止 Xray 没输出)
if [ -z "$X_PRIV" ] || ([ "$ENC_CHOICE" -ne 1 ] && [ -z "$V_SRV" ]); then
    echo -e "${RED}❌ 核心资产抓取失败！${NC}"
    exit 1
fi

# 6. 写入配置
cat << EOF > /usr/local/etc/xray/config.json
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
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" }],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }
}
EOF

# 7. 重启服务
systemctl restart xray
sleep 2

if systemctl is-active xray &> /dev/null; then
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VER_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLI}#Node"
    echo -e "\n${GREEN}🎉 构建成功！${NC}\n${CYAN}${LINK}${NC}\n"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 启动失败。${NC}"
    $XRAY_BIN -test -config /usr/local/etc/xray/config.json
fi