#!/bin/bash
# v8.2 终极手术刀版 - 修复密钥提取逻辑冲突，确保私钥纯净

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
echo -e "${GREEN}🚀 VLESS-REALITY-PQC 自动化构建 v8.2 (手术刀版)${NC}"
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名: " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}

# 2. 内核资产生成
XRAY_BIN=$(command -v xray)
[ -z "$XRAY_BIN" ] && XRAY_BIN="/usr/local/bin/xray"

# 3. 【核心修正】提取 REALITY 基础密钥对
echo -e "${CYAN}🔑 提取 REALITY 基础密钥...${NC}"
X_OUT=$($XRAY_BIN x25519 2>&1)
# 逻辑：找包含 Private 的行 -> 删掉冒号及以前的所有内容 -> 删掉所有空格
X_PRIV=$(echo "$X_OUT" | grep -i "Private" | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')
X_PUB=$(echo "$X_OUT" | grep -i "Public" | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')

# 4. 加密模式处理
echo -e "\n1) None / 2) X25519 (经典动态) / 3) ML-KEM-768 (后量子动态)"
read -p "选择加密 [默认 3]: " ENC_CHOICE
ENC_CHOICE=${ENC_CHOICE:-3}

V_SRV="none"; V_CLI="none"; PQC_JSON=""; M_VER_PARAM=""
V_OUT=$($XRAY_BIN vlessenc 2>&1)

if [ "$ENC_CHOICE" == "3" ]; then
    echo -e "${CYAN}🧬 提取 ML-KEM-768 动态资产...${NC}"
    # 精准切块提取加密字符串
    V_SRV=$(echo "$V_OUT" | awk '/ML-KEM-768/{f=1} f&&/"decryption":/{print $2; exit}' | tr -d '",[:space:]')
    V_CLI=$(echo "$V_OUT" | awk '/ML-KEM-768/{f=1} f&&/"encryption":/{print $2; exit}' | tr -d '",[:space:]')
    
    # 提取超长多行 Verify
    ML_RAW=$($XRAY_BIN mldsa65 2>&1)
    M_SEED=$(echo "$ML_RAW" | grep -i "Seed" | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')
    # 抓取从 Verify: 开始到结尾的所有内容，并拍平
    M_VER=$(echo "$ML_RAW" | sed -n '/Verify:/,$p' | sed 's/Verify:[[:space:]]*//' | tr -d '\n\r[:space:]')
    
    PQC_JSON="\"mldsa65Seed\": \"$M_SEED\","
    M_VER_PARAM="&mldsa65Verify=$M_VER"

elif [ "$ENC_CHOICE" == "2" ]; then
    echo -e "${CYAN} klasik 提取 X25519 动态资产...${NC}"
    V_SRV=$(echo "$V_OUT" | awk '/X25519/{f=1} f&&/"decryption":/{print $2; exit}' | tr -d '",[:space:]')
    V_CLI=$(echo "$V_OUT" | awk '/X25519/{f=1} f&&/"encryption":/{print $2; exit}' | tr -d '",[:space:]')
fi

# 🚨 防护检查：如果私钥里还带着标签词，说明提取还是失败了，强制拦截
if [[ "$X_PRIV" == *"Private"* ]] || [ -z "$X_PRIV" ]; then
    echo -e "${RED}❌ 密钥提取严重错误，请手动检查 xray x25519 输出格式。${NC}"
    exit 1
fi

# 5. 写入配置
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

# 6. 重启服务
systemctl restart xray
sleep 2

if systemctl is-active xray &> /dev/null; then
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}${M_VER_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLI}#Premium-Node"
    echo -e "\n${GREEN}🎉 构建成功！${NC}\n${CYAN}${LINK}${NC}\n"
    qrencode -t ANSIUTF8 "$LINK"
else
    echo -e "${RED}❌ 启动失败。配置有误。${NC}"
    $XRAY_BIN -test -config /usr/local/etc/xray/config.json
fi