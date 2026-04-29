#!/bin/bash

# ==========================================
# VLESS-REALITY-PQC 终极自动化构建脚本 v6.0
# 支持内核: Xray-core (v26+) / sing-box (v1.8+)
# 核心特性: 双层后量子加密 / 终极防呆路由 / 全自动规则库更新 / 终端二维码
# 适用系统: Debian/Ubuntu (推荐 Debian 13)
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
NC='\033[0m'

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. 权限与系统基础检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 权限运行此脚本。${NC}"
  exit 1
fi

echo -e "${CYAN}📦 正在同步系统时间并安装必备依赖...${NC}"
apt-get update -y > /dev/null 2>&1
# 增加 cron 依赖以备 Xray 自动更新所需
apt-get install -y jq openssl curl uuid-runtime qrencode sudo ntpdate cron > /dev/null 2>&1
ntpdate -u pool.ntp.org > /dev/null 2>&1 # 同步时间防止 REALITY 握手失败

SERVER_IP=$(curl -s4 ifconfig.me)

# 2. 交互配置
clear
echo -e "${GREEN}${BOLD}====================================================${NC}"
echo -e "${GREEN}${BOLD}   🚀 VLESS-REALITY-PQC 终极自动化构建脚本 v6.0   ${NC}"
echo -e "${GREEN}${BOLD}====================================================${NC}"
echo -e "请选择内核组件 (脚本将自动处理安装、守护与路由库)："
echo -e "  ${CYAN}1)${NC} 🛡️ ${BOLD}Xray-core${NC} (支持 ML-KEM-768 双层后量子加密)"
echo -e "  ${CYAN}2)${NC} ⚡ ${BOLD}sing-box${NC} (极致轻量，自带 SRS 规则热更新)"
echo -e "${GREEN}====================================================${NC}"
read -p "请输入选项 [1-2, 默认 1]: " CORE_CHOICE
CORE_CHOICE=${CORE_CHOICE:-1}

echo -e "\n${YELLOW}--- 基础参数设置 ---${NC}"
read -p "👉 监听端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "👉 伪装域名 (需支持 TLS 1.3，默认 v1-dy.ixigua.com): " SNI
SNI=${SNI:-"v1-dy.ixigua.com"}
read -p "📝 节点备注名称 (默认 Premium-Node): " RAW_REMARK
RAW_REMARK=${RAW_REMARK:-"Premium-Node"}

URI_REMARK=$(jq -nr --arg v "$RAW_REMARK" '$v|@uri')
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)

# ==========================================
# 模块 A: Xray 核心逻辑
# ==========================================
if [ "$CORE_CHOICE" == "1" ]; then
    if ! command -v xray &> /dev/null; then
        echo -e "${YELLOW}⏳ 正在调用官方脚本安装 Xray-core...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    echo -e "\n${YELLOW}--- Xray 内层加密级别选择 ---${NC}"
    echo "1) None (经典纯净版 - 仅靠外层 TLS 保护)"
    echo "2) X25519 (经典加密版 - 抵御经典计算机)"
    echo -e "3) ${BOLD}ML-KEM-768 (后量子终极版 - 抵御量子计算机) [推荐]${NC}"
    read -p "请输入选择 [1-3, 默认 3]: " ENC_CHOICE
    ENC_CHOICE=${ENC_CHOICE:-3}

    echo -e "\n${CYAN}🔐 正在生成 Xray 密码学资产...${NC}"
    X25519_OUT=$(xray x25519)
    X_PRIV=$(echo "$X25519_OUT" | grep "Private key:" | awk '{print $3}')
    X_PUB=$(echo "$X25519_OUT" | grep "Public key:" | awk '{print $3}')
    MLDSA_OUT=$(xray mldsa65)
    M_SEED=$(echo "$MLDSA_OUT" | grep "Seed:" | awk '{print $2}')
    M_VERIFY=$(echo "$MLDSA_OUT" | grep "Verify:" | awk '{print $2}')

    if [ "$ENC_CHOICE" == "1" ]; then
        V_SERVER="none"; V_CLIENT="none"
    else
        VENC_OUT=$(echo "$ENC_CHOICE" | xray vlessenc 2>/dev/null)
        V_SERVER=$(echo "$VENC_OUT" | grep "Server:" | awk '{print $2}')
        V_CLIENT=$(echo "$VENC_OUT" | grep "Client:" | awk '{print $2}')
    fi

    CONFIG_PATH="/usr/local/etc/xray/config.json"
    cat << EOF > $CONFIG_PATH
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
      "decryption": "$V_SERVER"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "target": "$SNI:443", "xver": 0,
        "serverNames": [ "$SNI" ], "privateKey": "$X_PRIV",
        "shortIds": [ "$SHORT_ID" ], "mldsa65Seed": "$M_SEED", "maxTimeDiff": 60000
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" }],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["geosite:google", "geosite:github", "geosite:telegram", "geosite:microsoft", "geosite:apple", "geosite:cloudflare"], "outboundTag": "direct" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

    # --- Xray 专属：部署 Loyalsoldier 规则自动更新任务 ---
    echo -e "${CYAN}🔄 正在配置 Xray 路由规则库全自动更新任务...${NC}"
    cat << 'EOF' > /usr/local/bin/update_xray_geo.sh
#!/bin/bash
curl -sL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o /usr/local/share/xray/geoip.dat
curl -sL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o /usr/local/share/xray/geosite.dat
systemctl restart xray
EOF
    chmod +x /usr/local/bin/update_xray_geo.sh
    # 立即执行一次，确保初次安装即为最新规则
    /usr/local/bin/update_xray_geo.sh > /dev/null 2>&1
    # 写入 crontab（每周一凌晨4点自动更新）
    (crontab -l 2>/dev/null | grep -v "update_xray_geo.sh"; echo "0 4 * * 1 /usr/local/bin/update_xray_geo.sh > /dev/null 2>&1") | crontab -

    # 重启与守护
    systemctl daemon-reload
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray
    
    sleep 2
    if systemctl is-active xray &> /dev/null; then
        STATUS_MSG="${GREEN}● Xray 运行状态: 正在运行 (已设为开机自启，路由库每周自动更新)${NC}"
    else
        echo -e "${RED}❌ Xray 启动失败！请检查端口 $PORT 是否被占用。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}&mldsa65Verify=${M_VERIFY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${V_CLIENT}#${URI_REMARK}"

# ==========================================
# 模块 B: sing-box 核心逻辑
# ==========================================
elif [ "$CORE_CHOICE" == "2" ]; then
    if ! command -v sing-box &> /dev/null; then
        echo -e "${YELLOW}⏳ 正在调用官方脚本安装 sing-box...${NC}"
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    echo -e "\n${CYAN}🔐 正在生成 sing-box 密码学资产...${NC}"
    SB_KEYS=$(sing-box generate reality-keypair)
    X_PRIV=$(echo "$SB_KEYS" | grep "PrivateKey:" | awk '{print $2}')
    X_PUB=$(echo "$SB_KEYS" | grep "PublicKey:" | awk '{print $2}')

    CONFIG_PATH="/etc/sing-box/config.json"
    cat << EOF > $CONFIG_PATH
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": $PORT, "tcp_fast_open": true,
    "sniffing": { "enabled": true, "override_destination": true },
    "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
    "tls": {
      "enabled": true, "server_name": "$SNI",
      "reality": {
        "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 },
        "private_key": "$X_PRIV", "short_id": [ "$SHORT_ID" ], "max_time_diff": "1m"
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }],
  "route": {
    "rule_set": [
      {
        "tag": "geosite-global", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "download_detour": "direct", "update_interval": "1d"
      },
      {
        "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct", "update_interval": "1d"
      },
      {
        "tag": "geoip-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "direct", "update_interval": "1d"
      }
    ],
    "rules": [
      { "rule_set": "geosite-global", "outbound": "direct" },
      { "protocol": "bittorrent", "outbound": "block" },
      { "rule_set": "geosite-cn", "outbound": "block" },
      { "rule_set": "geoip-cn", "outbound": "block" },
      { "ip_is_private": true, "outbound": "block" }
    ],
    "final": "direct"
  }
}
EOF
    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box

    sleep 2
    if systemctl is-active sing-box &> /dev/null; then
        STATUS_MSG="${GREEN}● sing-box 运行状态: 正在运行 (已设为开机自启，SRS 规则库后台每日热更新)${NC}"
    else
        echo -e "${RED}❌ sing-box 启动失败！请检查端口 $PORT 是否被占用。${NC}"
        exit 1
    fi
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${X_PUB}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${URI_REMARK}"
fi

# ==========================================
# 模块 C: 结果输出与存档
# ==========================================
echo -e "\n${YELLOW}${BOLD}======================================================================${NC}"
echo -e "$STATUS_MSG"
echo -e "${GREEN}🎉 终极节点构建完成！配置链接已存档至 /root/vless_node_link.txt${NC}"
echo -e "${YELLOW}======================================================================${NC}\n"

echo -e "${CYAN}${BOLD}${LINK}${NC}\n"

echo -e "${YELLOW}📷 推荐直接使用手机客户端扫码导入：${NC}"
qrencode -t ANSIUTF8 "$LINK"
echo "$LINK" > /root/vless_node_link.txt