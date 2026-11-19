#!/bin/bash
# ==============================================================================
# Xray VLESS-XHTTP (H3/TCP/CDN) + IPv6 S5 路由分流安装脚本
# ==============================================================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
PLAIN="\033[0m"

CERT_DIR="/root/ygkkkca"
CERT="${CERT_DIR}/cert.crt"
KEY="${CERT_DIR}/private.key"
SOCKS_PORT=40000
PORT_H3=8443
PORT_XC=443
CONFIG="/etc/xray/config.json"

if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    echo -e "${RED}❌ 未检测到证书文件！${PLAIN}"
    echo -e "${YELLOW}请确保已将证书存放在：${PLAIN}"
    echo "  公钥: $CERT"
    echo "  私钥: $KEY"
    exit 1
fi

echo -e "${GREEN}>>> [XRAY 1/5] 安装必要系统依赖...${PLAIN}"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl unzip openssl
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip openssl
fi

echo -e "${GREEN}>>> [XRAY 2/5] 下载官方最新 Xray 内核...${PLAIN}"
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

echo -e "${GREEN}>>> [XRAY 3/5] 下载并安装 geosite.dat 与 geoip.dat 规则库...${PLAIN}"
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

UUID=$(grep -oE '"id": "[0-9a-fA-F-]{36}"' $CONFIG 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')

IP=$(curl -s4 https://icanhazip.com || curl -s4 https://api.ipify.org)
SNI=$(openssl x509 -in "$CERT" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -n1 | grep -oE "(DNS:[^, ]+|IP Address:[^, ]+)" | head -n1 | sed -E 's/(DNS:|IP Address:)//' || true)
if [ -z "$SNI" ]; then
    SNI=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN[ =]*//p' || true)
fi
[ -z "$SNI" ] && SNI="$IP"

PATH_H3="/${UUID}-xu"
PATH_XC="/${UUID}-xc"

echo -e "${GREEN}>>> [XRAY 4/5] 写入生产级 /etc/xray/config.json 配置文件...${PLAIN}"
cat > $CONFIG << JSON
{
  "log": {
    "loglevel": "error"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "2606:4700:4700::1111",
      "2001:4860:4860::8888",
      "localhost"
    ],
    "queryStrategy": "UseIPv6"
  },
  "inbounds": [
    {
      "tag": "xhttp-h3-in",
      "listen": "::",
      "port": ${PORT_H3},
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
        "security": "tls",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${PATH_H3}"
        },
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "${CERT}",
              "keyFile": "${KEY}"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
    {
      "tag": "xhttp-cdn-443-in",
      "listen": "::",
      "port": ${PORT_XC},
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
        "security": "tls",
        "sockopt": {
          "trustedXForwardedFor": [
            "CF-Connecting-IP"
          ]
        },
        "xhttpSettings": {
          "mode": "auto",
          "path": "${PATH_XC}"
        },
        "tlsSettings": {
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "${CERT}",
              "keyFile": "${KEY}"
            }
          ]
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
    {
      "tag": "warp-ipv6-out",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv6",
          "dialerProxy": "socks-warp"
        }
      }
    },
    {
      "tag": "socks-warp",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${SOCKS_PORT}
          }
        ]
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "outboundTag": "warp-ipv6-out",
        "domain": [
          "geosite:openai",
          "geosite:google-gemini",
          "geosite:google-deepmind"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
JSON

echo -e "${GREEN}>>> [XRAY 5/5] 配置 Systemd 服务与开机自启动...${PLAIN}"
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

systemctl daemon-reload
/usr/local/bin/xray -test -config $CONFIG
systemctl enable --now xray
systemctl restart xray

# 放行端口
if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow 8443/udp >/dev/null 2>&1 || true
    ufw allow 8443/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-port=443/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port=8443/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port=8443/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 安装 xm 管理命令并建立全局软链接
REPO_URL="https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "${SCRIPT_DIR}/xm_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/xm_ctl.sh" /usr/local/bin/xm
elif [ -f "${SCRIPT_DIR}/scripts/xm_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/scripts/xm_ctl.sh" /usr/local/bin/xm
else
    curl -sSL "${REPO_URL}/scripts/xm_ctl.sh" -o /usr/local/bin/xm
fi
chmod +x /usr/local/bin/xm
ln -sf /usr/local/bin/xm /usr/bin/xm

# 打印节点信息
if [ -x /usr/local/bin/xm ]; then
    /usr/local/bin/xm info
fi
