#!/bin/bash
# ==============================================================================
# Xray VLESS-XHTTP 容器/NAT 穿透模式 (Cloudflare 官方 Tunnel 隧道入栈 + WARP AI 分流)
# 专为 Docker / PRoot / NAT VPS / 无公网入站端口容器环境设计
# 仅部署 Cloudflare 优选节点，免证书、免公网端口、防封锁，纯用户态 WireGuard WARP 出口分流
# ==============================================================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

CONFIG="/etc/xray/config.json"
TUNNEL_CONF="/etc/xray/tunnel.conf"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限执行此脚本！${PLAIN}"
    exit 1
fi

is_systemd() {
    [ -d /run/systemd/system ] && systemctl --version >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

echo -e "${BLUE}====================================================================${PLAIN}"
echo -e "${GREEN}    Xray 容器/NAT 穿透模式安装向导 (Cloudflare Tunnel + WARP 分流)   ${PLAIN}"
echo -e "${BLUE}====================================================================${PLAIN}"
echo -e "${CYAN}说明：此模式利用 Cloudflare 官方隧道从容器内部主动向外建立连接，${PLAIN}"
echo -e "${CYAN}      无需容器开放任何公网端口，本地无需申请 SSL 证书；${PLAIN}"
echo -e "${CYAN}      同时集成纯用户态 WireGuard WARP 出口，解锁 OpenAI / Gemini AI 分流！${PLAIN}"
echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"

# 1. 交互式输入 Cloudflare Tunnel Token
DEFAULT_TOKEN=""
[ -f "$TUNNEL_CONF" ] && DEFAULT_TOKEN=$(grep -E '^CF_TUNNEL_TOKEN=' "$TUNNEL_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'\')

while true; do
    if [ -n "$DEFAULT_TOKEN" ]; then
        read -p "请输入 Cloudflare Tunnel Token [回车保持现有]: " INPUT_TOKEN
        [ -z "$INPUT_TOKEN" ] && INPUT_TOKEN="$DEFAULT_TOKEN"
    else
        read -p "请输入 Cloudflare Tunnel Token (隧道密钥): " INPUT_TOKEN
    fi

    # 清洗用户可能误粘贴的整串命令 (例如 cloudflared tunnel run --token eyJh... 或 service install eyJh...)
    CF_TOKEN=$(echo "$INPUT_TOKEN" | sed -E 's/.*(--token|service install)[ =]+//; s/^[ \t]*//; s/[ \t]*$//' | tr -d '\r\n"')
    if [ -n "$CF_TOKEN" ]; then
        break
    else
        echo -e "${RED}❌ Token 不能为空，请从 Cloudflare Zero Trust 控制台复制！${PLAIN}"
    fi
done

# 2. 交互式输入隧道绑定的公共域名
DEFAULT_DOMAIN=""
[ -f "$TUNNEL_CONF" ] && DEFAULT_DOMAIN=$(grep -E '^CF_TUNNEL_DOMAIN=' "$TUNNEL_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'\')

while true; do
    if [ -n "$DEFAULT_DOMAIN" ]; then
        read -p "请输入 Cloudflare 绑定的隧道域名 (如 tryaltare.20000805.xyz) [回车保持现有]: " INPUT_DOMAIN
        [ -z "$INPUT_DOMAIN" ] && INPUT_DOMAIN="$DEFAULT_DOMAIN"
    else
        read -p "请输入 Cloudflare 绑定的隧道域名 (如 tryaltare.20000805.xyz): " INPUT_DOMAIN
    fi

    CF_DOMAIN=$(echo "$INPUT_DOMAIN" | sed -E 's#^https?://##; s#/.*$##' | tr -d ' \r\n"' | tr '[:upper:]' '[:lower:]')
    if [ -n "$CF_DOMAIN" ]; then
        break
    else
        echo -e "${RED}❌ 域名不能为空！${PLAIN}"
    fi
done

# 3. 本地监听端口
read -p "请输入本地 Xray 监听端口 [默认 8080]: " LOCAL_PORT
LOCAL_PORT=$(echo "$LOCAL_PORT" | tr -dc '0-9')
[ -z "$LOCAL_PORT" ] && LOCAL_PORT=8080

echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"
echo -e "配置确认："
echo -e "  - 隧道域名 : ${CYAN}${CF_DOMAIN}${PLAIN}"
echo -e "  - 本地端口 : ${CYAN}127.0.0.1:${LOCAL_PORT}${PLAIN}"
echo -e "  - AI 分流  : ${GREEN}OpenAI + Gemini -> Cloudflare WARP (WireGuard 原生出站)${PLAIN}"
echo -e "  - 运行环境 : $(is_systemd && echo "${GREEN}标准系统 (Systemd)${PLAIN}" || echo "${YELLOW}轻量容器/沙箱 (进程自守护)${PLAIN}")"
echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"

echo -e "\n${GREEN}>>> [TUNNEL 1/6] 安装必要系统依赖...${PLAIN}"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl unzip procps ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip procps ca-certificates
fi

echo -e "${GREEN}>>> [TUNNEL 2/6] 下载并安装 Xray 官方内核与规则库...${PLAIN}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) FILE="Xray-linux-64.zip" ;;
  aarch64|arm64) FILE="Xray-linux-arm64-v8a.zip" ;;
  *) echo -e "${RED}不支持的 CPU 架构: $ARCH${PLAIN}"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
curl -sSL "https://github.com/XTLS/Xray-core/releases/latest/download/${FILE}" -o "${TMP_DIR}/xray.zip"
mkdir -p /usr/local/bin /etc/xray /usr/local/share/xray
unzip -qo "${TMP_DIR}/xray.zip" xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -rf "$TMP_DIR"

ensure_dat() {
    local file=$1
    local target="/usr/local/share/xray/$file"
    local size=0
    [ -f "$target" ] && size=$(wc -c < "$target" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000000 ]; then
        curl -sSL --retry 3 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$file" -o "$target" || \
        curl -sSL --retry 3 "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/$file" -o "$target"
    fi
    cp -f "$target" /usr/local/bin/
    cp -f "$target" /etc/xray/
}
ensure_dat geosite.dat
ensure_dat geoip.dat

echo -e "${GREEN}>>> [TUNNEL 3/6] 下载 Cloudflare 官方 cloudflared 客户端...${PLAIN}"
CF_BIN="/usr/local/bin/cloudflared"
case "$ARCH" in
  x86_64|amd64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
  *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
esac
curl -sSL "$CF_URL" -o "$CF_BIN"
chmod +x "$CF_BIN"

echo -e "${GREEN}>>> [TUNNEL 4/6] 配置 Cloudflare WARP 原生 WireGuard 出口分流...${PLAIN}"
WARP_DIR="/var/lib/cloudflare-warp"
mkdir -p "$WARP_DIR"

if ! command -v warp-cli >/dev/null 2>&1; then
    echo -e "${CYAN}安装官方 Cloudflare WARP 客户端用于安全获取原生密钥...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
        . /etc/os-release 2>/dev/null || true
        CODENAME="${VERSION_CODENAME:-bookworm}"
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
        apt-get update -y && apt-get install -y cloudflare-warp 2>/dev/null || true
    fi
fi

NEED_REG=false
if [ ! -f "${WARP_DIR}/reg.json" ] || [ ! -f "${WARP_DIR}/conf.json" ]; then
    NEED_REG=true
elif ! grep -q 'curve25519' "${WARP_DIR}/conf.json" 2>/dev/null; then
    NEED_REG=true
fi

if [ "$NEED_REG" = "true" ] && command -v warp-cli >/dev/null 2>&1; then
    echo -e "${CYAN}向 Cloudflare 官方注册专属 WARP WireGuard 账户...${PLAIN}"
    pkill -x warp-svc 2>/dev/null || true
    nohup /usr/bin/warp-svc >/dev/null 2>&1 &
    sleep 2
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos tunnel protocol set WireGuard 2>/dev/null || true
    sleep 1
    pkill -x warp-svc 2>/dev/null || true
fi

WARP_SECRET_KEY=$(grep -o '"secret_key":"[^"]*' "${WARP_DIR}/reg.json" 2>/dev/null | cut -d'"' -f4 || true)
WARP_IPV4=$(grep -o '"v4":"[^"]*' "${WARP_DIR}/conf.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
WARP_IPV6=$(grep -o '"v6":"[^"]*' "${WARP_DIR}/conf.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
[ -z "$WARP_IPV4" ] && WARP_IPV4="172.16.0.2"
[ -z "$WARP_IPV6" ] && WARP_IPV6="2606:4700:110:81ec:2cd0:332c:af20:33e5"
WARP_ENDPOINT="162.159.192.1:2408"
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

if [ -n "$WARP_SECRET_KEY" ]; then
    echo -e "${GREEN}✅ Cloudflare WARP WireGuard 凭据就绪！${PLAIN}"
    WARP_OUTBOUND_JSON='{
      "tag": "warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "'"${WARP_SECRET_KEY}"'",
        "address": [
          "'"${WARP_IPV4}"'/32",
          "'"${WARP_IPV6}"'/128"
        ],
        "peers": [
          {
            "publicKey": "'"${WARP_PUBKEY}"'",
            "endpoint": "'"${WARP_ENDPOINT}"'"
          }
        ],
        "mtu": 1280
      }
    },'
    WARP_ROUTING_RULE='{
        "type": "field",
        "outboundTag": "warp-out",
        "domain": [
          "geosite:openai",
          "geosite:google-gemini",
          "geosite:google-deepmind"
        ]
      },'
    WARP_ENABLED_FLAG="1"
else
    echo -e "${YELLOW}⚠️ 未能获取到 WARP 密钥，默认退化为直连出站。${PLAIN}"
    WARP_OUTBOUND_JSON=""
    WARP_ROUTING_RULE=""
    WARP_ENABLED_FLAG="0"
fi

echo -e "${GREEN}>>> [TUNNEL 5/6] 写入隧道入栈与分流 Xray 配置...${PLAIN}"
UUID=$(grep -oE '"id": "[0-9a-fA-F-]{36}"' $CONFIG 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')

PATH_XC="/${UUID}-xc"

cat > "$CONFIG" << JSON
{
  "log": {
    "loglevel": "error"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "tag": "xhttp-tunnel-in",
      "listen": "127.0.0.1",
      "port": ${LOCAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${PATH_XC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    ${WARP_OUTBOUND_JSON}
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      ${WARP_ROUTING_RULE}
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
JSON

# 保存隧道与 WARP 元数据供 xm 管理命令读取
cat > "$TUNNEL_CONF" << EOF
CF_TUNNEL_TOKEN="${CF_TOKEN}"
CF_TUNNEL_DOMAIN="${CF_DOMAIN}"
CF_LOCAL_PORT="${LOCAL_PORT}"
TUNNEL_MODE="1"
WARP_ENABLED="${WARP_ENABLED_FLAG}"
EOF
chmod 600 "$TUNNEL_CONF"

/usr/local/bin/xray -test -config "$CONFIG"

echo -e "${GREEN}>>> [TUNNEL 6/6] 启动并守护服务 (自动适配环境)...${PLAIN}"
if is_systemd; then
    echo -e "${CYAN}检测到 Systemd，正在配置守护服务...${PLAIN}"
    cat > /etc/systemd/system/xray.service << SERVICE
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/cloudflared.service << SERVICE
[Unit]
Description=Cloudflare Tunnel Agent
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable --now xray cloudflared
    systemctl restart xray cloudflared
else
    echo -e "${YELLOW}检测到非 Systemd 环境（Docker/PRoot 容器），采用后台自守护模式...${PLAIN}"
    pkill -x xray 2>/dev/null || true
    pkill -x cloudflared 2>/dev/null || true
    sleep 1

    nohup /usr/local/bin/xray run -c /etc/xray/config.json > /var/log/xray.log 2>&1 &
    nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN" > /var/log/cloudflared.log 2>&1 &

    # 在 .bashrc 和 /etc/profile 中注入保活启动钩子
    AUTORUN_CODE='
# [xray-xhttp-warp] Container Autostart Hook
if [ -f /etc/xray/tunnel.conf ]; then
    if ! pgrep -x xray >/dev/null 2>&1; then
        nohup /usr/local/bin/xray run -c /etc/xray/config.json >/var/log/xray.log 2>&1 &
    fi
    if ! pgrep -x cloudflared >/dev/null 2>&1; then
        . /etc/xray/tunnel.conf
        if [ -n "$CF_TUNNEL_TOKEN" ]; then
            nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" >/var/log/cloudflared.log 2>&1 &
        fi
    fi
fi'

    if ! grep -q "xray/tunnel.conf" /root/.bashrc 2>/dev/null; then
        echo "$AUTORUN_CODE" >> /root/.bashrc
    fi
    if [ -f /etc/profile ] && ! grep -q "xray/tunnel.conf" /etc/profile 2>/dev/null; then
        echo "$AUTORUN_CODE" >> /etc/profile
    fi
fi

# 安装 xm 管理命令
REPO_URL="https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "${SCRIPT_DIR}/xm_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/xm_ctl.sh" /usr/local/bin/xm
elif [ -f "${SCRIPT_DIR}/scripts/xm_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/scripts/xm_ctl.sh" /usr/local/bin/xm
else
    curl -sSL "${REPO_URL}/scripts/xm_ctl.sh" -o /usr/local/bin/xm 2>/dev/null || true
fi
chmod +x /usr/local/bin/xm
ln -sf /usr/local/bin/xm /usr/bin/xm 2>/dev/null || true

sleep 2

# 展示节点信息
if [ -x /usr/local/bin/xm ]; then
    /usr/local/bin/xm info
fi
