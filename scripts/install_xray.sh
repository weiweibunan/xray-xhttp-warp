#!/bin/bash
# ==============================================================================
# Xray VLESS-XHTTP (H3/TCP/CDN) + IPv6 S5 路由分流安装脚本
# ==============================================================================

set -e

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    . "${SCRIPT_DIR}/common.sh"
elif [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
    . "${SCRIPT_DIR}/scripts/common.sh"
else
    _COMMON_TMP=$(mktemp /tmp/xray-common.XXXXXX.sh)
    if ! curl -fsSL --connect-timeout 15 --retry 3 "${REPO_URL}/scripts/common.sh" -o "$_COMMON_TMP"; then
        rm -f "$_COMMON_TMP"
        echo "❌ 下载公共函数库 scripts/common.sh 失败！"
        exit 1
    fi
    . "$_COMMON_TMP"
    rm -f "$_COMMON_TMP"
fi

require_root
detect_arch

if ! is_systemd; then
    log_err "❌ 原生双节点模式需要 Systemd 环境；容器/无 Systemd 请使用: bash install.sh tunnel"
    exit 1
fi

resolve_or_issue_xray_cert "$SCRIPT_DIR"
CERT="$CERT_PATH"
KEY="$KEY_PATH"
log_ok ">>> [XRAY 1/5] 安装必要系统依赖..."
install_pkg curl unzip openssl jq ca-certificates
ensure_net_tools

SOCKS_PORT=40000
PORT_H3=8443
PORT_XC=443

resolve_free_port tcp "$PORT_XC" "TCP" "如 2053/2083/2096" || exit 1
PORT_XC="$RESOLVED_PORT"
resolve_free_port udp "$PORT_H3" "H3/UDP" "如 2087/8444" || exit 1
PORT_H3="$RESOLVED_PORT"

if ! openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
    log_err "❌ 证书文件格式无效: $CERT"
    exit 1
fi

# 可选：标准原生 VPS 同时启用 Cloudflare Tunnel 隧道入栈节点
OPT_CF_TUNNEL=false
PREV_CF_ENABLED=""
[ -f "$TUNNEL_CONF" ] && PREV_CF_ENABLED=$(grep -E '^CF_TUNNEL_ENABLED=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r" || true)

if [ "${ENABLE_CF_TUNNEL:-}" = "1" ]; then
    OPT_CF_TUNNEL=true
elif [ "${ENABLE_CF_TUNNEL:-}" = "0" ]; then
    OPT_CF_TUNNEL=false
else
    echo -e "\n${BLUE}--------------------------------------------------${PLAIN}"
    if [ "$PREV_CF_ENABLED" = "1" ]; then
        read_tty -p "检测到此前已额外开启 Cloudflare Tunnel 隧道节点，是否继续保留/更新？[Y/n]: " cf_choice || cf_choice="y"
        [[ "$cf_choice" != "n" && "$cf_choice" != "N" ]] && OPT_CF_TUNNEL=true
    else
        read_tty -p "是否在原有节点(CDN优选/TCP/H3)基础上，额外新增 Cloudflare Tunnel 隧道节点？(可选) [y/N]: " cf_choice || cf_choice="n"
        [[ "$cf_choice" == "y" || "$cf_choice" == "Y" ]] && OPT_CF_TUNNEL=true
    fi
fi

if [ "$OPT_CF_TUNNEL" = "true" ]; then
    prompt_tunnel_params 8080
    while true; do
        if [[ ! "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
            log_warn "⚠️ 隧道本地端口无效 (${LOCAL_PORT})，必须是 1-65535 之间的数字！"
        elif [ "$LOCAL_PORT" = "$PORT_XC" ] || [ "$LOCAL_PORT" = "$PORT_H3" ] || check_port_conflict tcp "$LOCAL_PORT" >/dev/null; then
            log_warn "⚠️ 隧道本地端口 ${LOCAL_PORT} 与原生端口冲突或已被占用，请更换端口！"
        else
            break
        fi
        read_tty -p "请输入空闲本地监听端口 [如 8080/18080]: " LOCAL_PORT
        LOCAL_PORT=$(echo "$LOCAL_PORT" | tr -d ' \r\n')
    done
    log_info ">>> 下载并安装 Cloudflare 官方 cloudflared 客户端..."
    install_cloudflared
fi

resolve_install_uuid "$XRAY_CONFIG"
UUID="$RESOLVED_UUID"

log_ok ">>> [XRAY 2/5] 下载并校验官方最新 Xray 内核..."
install_xray_core

log_ok ">>> [XRAY 3/5] 下载并校验 geosite.dat 与 geoip.dat 规则库..."
ensure_dat

[ -z "$UUID" ] && UUID=$(generate_uuid)

PATH_H3="/${UUID}-xu"
PATH_XC="/${UUID}-xc"
PATH_XT="/${UUID}-xt"

TUNNEL_INBOUND_JSON=""
if [ "$OPT_CF_TUNNEL" = "true" ]; then
    TUNNEL_INBOUND_JSON=",{
      \"tag\": \"xhttp-tunnel-in\",
      \"listen\": \"127.0.0.1\",
      \"port\": ${LOCAL_PORT},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${UUID}\",
            \"flow\": \"\"
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"none\",
        \"sockopt\": {
          \"trustedXForwardedFor\": [
            \"CF-Connecting-IP\"
          ]
        },
        \"xhttpSettings\": {
          \"mode\": \"auto\",
          \"path\": \"${PATH_XT}\"
        }
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\", \"quic\"],
        \"metadataOnly\": false
      }
    }"
fi

log_ok ">>> [XRAY 4/5] 生成并校验 /etc/xray/config.json 配置文件..."
TMP_CFG_DIR=$(mktemp -d)
TMP_CFG="${TMP_CFG_DIR}/config.json"
trap 'rm -rf "$TMP_CFG_DIR"' EXIT

cat > "$TMP_CFG" << JSON
{
  "log": {
    "loglevel": "error"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "https+local://[2606:4700:4700::1111]/dns-query",
      "https+local://[2001:4860:4860::8888]/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIP"
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
    }${TUNNEL_INBOUND_JSON}
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
          "domainStrategy": "ForceIPv6",
          "dialerProxy": "socks-warp"
        }
      }
    },
    {
      "tag": "warp-ipv4-out",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "ForceIPv4",
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
        "outboundTag": "block",
        "ip": [
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "warp-ipv6-out",
        "domain": [
          "geosite:openai",
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

atomic_write_xray_config "$TMP_CFG" "$XRAY_CONFIG"

if [ "$OPT_CF_TUNNEL" = "true" ]; then
    cat > "$TUNNEL_CONF" << EOF
CF_TUNNEL_DOMAIN="${CF_DOMAIN}"
CF_LOCAL_PORT="${LOCAL_PORT}"
TUNNEL_MODE="0"
CF_TUNNEL_ENABLED="1"
WARP_ENABLED="1"
EOF
    chmod 600 "$TUNNEL_CONF"

    cat > "$TUNNEL_ENV" << EOF
TUNNEL_TOKEN=${CF_TOKEN}
EOF
    chmod 600 "$TUNNEL_ENV"

    write_cloudflared_systemd_unit
else
    # 未启用可选隧道时清理残留隧道配置，避免 xm 状态误判
    systemctl stop cloudflared 2>/dev/null || true
    systemctl disable cloudflared 2>/dev/null || true
    rm -f "$TUNNEL_CONF" "$TUNNEL_ENV" /etc/systemd/system/cloudflared.service
fi

log_ok ">>> [XRAY 5/5] 配置 Systemd 服务与开机自启动..."
cat > /etc/systemd/system/xray.service << SERVICE
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target warp-svc.service
Wants=warp-svc.service

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment="XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}"
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
if [ "$OPT_CF_TUNNEL" = "true" ]; then
    systemctl enable cloudflared
    systemctl restart cloudflared
fi
sleep 1
if ! systemctl is-active --quiet xray; then
    log_err "❌ Xray 服务启动失败，最近日志如下："
    journalctl -u xray -n 15 --no-pager || true
    exit 1
fi

# 放行端口 (兼容 ufw / firewalld / iptables)
open_firewall_port tcp "$PORT_XC"
open_firewall_port udp "$PORT_H3"

# 安装 xm 统一管理命令并建立全局软链接（含 warp 兼容入口）
install_unified_xm_ctl "$SCRIPT_DIR"

# 打印节点信息
if [ -x /usr/local/bin/xm ]; then
    /usr/local/bin/xm info
fi
