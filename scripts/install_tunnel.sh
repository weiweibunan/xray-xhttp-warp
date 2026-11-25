#!/bin/bash
# ==============================================================================
# Xray VLESS-XHTTP 容器/NAT 穿透模式 (Cloudflare 官方 Tunnel 隧道入栈 + WARP AI 分流)
# 专为 Docker / PRoot / NAT VPS / 无公网入站端口容器环境设计
# 仅部署 Cloudflare 优选节点，免证书、免公网端口、防封锁，纯用户态 WireGuard WARP 出口分流
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

WARP_CACHE_FILE="/etc/xray/warp-tunnel.json"

echo -e "${BLUE}====================================================================${PLAIN}"
echo -e "${GREEN}    Xray 容器/NAT 穿透模式安装向导 (Cloudflare Tunnel + WARP 分流)   ${PLAIN}"
echo -e "${BLUE}====================================================================${PLAIN}"
echo -e "${CYAN}说明：此模式利用 Cloudflare 官方隧道从容器内部主动向外建立连接，${PLAIN}"
echo -e "${CYAN}      无需容器开放任何公网端口，本地无需申请 SSL 证书；${PLAIN}"
echo -e "${CYAN}      同时集成纯用户态 WireGuard WARP 出口，强制 IPv6 解锁 OpenAI / Gemini！${PLAIN}"
echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"

# 1-3. 交互式输入 Token、域名与本地监听端口
prompt_tunnel_params 8080

echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"
echo -e "配置确认："
echo -e "  - 隧道域名 : ${CYAN}${CF_DOMAIN}${PLAIN}"
echo -e "  - 本地端口 : ${CYAN}127.0.0.1:${LOCAL_PORT}${PLAIN}"
echo -e "  - AI 分流  : ${GREEN}OpenAI + Gemini -> Cloudflare WARP (WireGuard ForceIPv6)${PLAIN}"
echo -e "  - 运行环境 : $(is_systemd && echo "${GREEN}标准系统 (Systemd)${PLAIN}" || echo "${YELLOW}轻量容器/沙箱 (进程自守护)${PLAIN}")"
echo -e "${BLUE}--------------------------------------------------------------------${PLAIN}"

log_ok "\n>>> [TUNNEL 1/6] 安装必要系统依赖..."
install_pkg curl unzip procps ca-certificates jq

if conflict=$(check_port_conflict tcp "$LOCAL_PORT"); then
    log_warn "⚠️ 检测到本地 TCP ${LOCAL_PORT} 端口已被其他进程占用: ${conflict}"
    read_tty -p "请输入空闲本地监听端口 [回车中止安装]: " ALT_PORT
    if [[ "$ALT_PORT" =~ ^[0-9]+$ ]] && [ "$ALT_PORT" -ge 1 ] && [ "$ALT_PORT" -le 65535 ]; then
        LOCAL_PORT="$ALT_PORT"
    else
        log_err "❌ 已中止安装。"
        exit 1
    fi
fi

log_ok ">>> [TUNNEL 2/6] 下载并校验 Xray 官方内核与规则库..."
install_xray_core
ensure_dat

log_ok ">>> [TUNNEL 3/6] 下载并安装 Cloudflare 官方 cloudflared 客户端..."
install_cloudflared

# ------------------------------------------------------------------------------
# 辅助函数：通过官方 client 套件或纯官方注册接口获取真实 WARP WireGuard 凭据
# ------------------------------------------------------------------------------
WARP_SECRET_KEY=""
WARP_IPV4=""
WARP_IPV6=""
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_EP_V4="162.159.192.1:2408"
WARP_EP_V6="[2606:4700:d0::a29f:c001]:2408"
WARP_RESERVED_JSON=""

decode_client_id_reserved() {
    local b64="$1"
    [ -z "$b64" ] && return 0
    local bytes
    bytes=$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
    set -- $bytes
    if [ "$#" -eq 3 ]; then
        echo "[${1}, ${2}, ${3}]"
    fi
}

is_valid_wg_key() {
    [[ "${1:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

try_load_cached_warp() {
    [ -f "$WARP_CACHE_FILE" ] || return 1
    WARP_SECRET_KEY=$(jq -r '.secret_key // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    WARP_IPV4=$(jq -r '.v4 // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    WARP_IPV6=$(jq -r '.v6 // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    local pub ep4 ep6 cid
    pub=$(jq -r '.public_key // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    ep4=$(jq -r '.endpoint_v4 // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    ep6=$(jq -r '.endpoint_v6 // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    cid=$(jq -r '.client_id // empty' "$WARP_CACHE_FILE" 2>/dev/null || true)
    [ -n "$pub" ] && WARP_PUBKEY="$pub"
    [ -n "$ep4" ] && WARP_EP_V4="$ep4"
    [ -n "$ep6" ] && WARP_EP_V6="$ep6"
    WARP_RESERVED_JSON=$(decode_client_id_reserved "$cid")
    is_valid_wg_key "$WARP_SECRET_KEY" && is_valid_wg_key "$WARP_PUBKEY" && [[ "$WARP_IPV6" == *:* ]]
}

save_cached_warp() {
    local cid="$1"
    mkdir -p /etc/xray
    jq -n \
        --arg sk "$WARP_SECRET_KEY" \
        --arg v4 "$WARP_IPV4" \
        --arg v6 "$WARP_IPV6" \
        --arg pk "$WARP_PUBKEY" \
        --arg ep4 "$WARP_EP_V4" \
        --arg ep6 "$WARP_EP_V6" \
        --arg cid "$cid" \
        '{secret_key:$sk, v4:$v4, v6:$v6, public_key:$pk, endpoint_v4:$ep4, endpoint_v6:$ep6, client_id:$cid}' \
        > "$WARP_CACHE_FILE"
    chmod 600 "$WARP_CACHE_FILE"
}

try_warp_official_cli() {
    command -v apt-get >/dev/null 2>&1 || return 1
    is_systemd || return 1

    local warp_dir="/var/lib/cloudflare-warp"
    if ! command -v warp-cli >/dev/null 2>&1; then
        log_info "安装官方 Cloudflare WARP 客户端以获取原生 WireGuard 密钥..."
        install_pkg gnupg >/dev/null 2>&1 || return 1
        mkdir -p /usr/share/keyrings
        local tmp_gpg
        tmp_gpg=$(mktemp)
        if ! fetch_to_file "$tmp_gpg" "https://pkg.cloudflareclient.com/pubkey.gpg"; then
            rm -f "$tmp_gpg"
            return 1
        fi
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg < "$tmp_gpg" 2>/dev/null || { rm -f "$tmp_gpg"; return 1; }
        rm -f "$tmp_gpg"
        . /etc/os-release 2>/dev/null || true
        local codename="${VERSION_CODENAME:-bookworm}"
        if ! curl -fsI --connect-timeout 5 "https://pkg.cloudflareclient.com/dists/${codename}/Release" >/dev/null 2>&1; then
            if [ "${ID:-}" = "ubuntu" ] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
                codename="noble"
            else
                codename="bookworm"
            fi
        fi
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" > /etc/apt/sources.list.d/cloudflare-client.list
        install_pkg cloudflare-warp >/dev/null 2>&1 || return 1
    fi

    local was_active=false
    systemctl is-active --quiet warp-svc && was_active=true
    if [ "$was_active" != "true" ]; then
        systemctl start warp-svc 2>/dev/null || return 1
        for _i in $(seq 1 10); do
            warp-cli --accept-tos status >/dev/null 2>&1 && break
            sleep 1
        done
    fi

    warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos tunnel protocol set WireGuard >/dev/null 2>&1 || true

    # 等待 warp-svc 异步切换为 WireGuard (curve25519) 密钥，必要时触发一次连接同步
    local wg_synced=false
    for _i in $(seq 1 10); do
        if [ "$(jq -r '.tunnel_key_data.key_type // empty' "${warp_dir}/conf.json" 2>/dev/null)" = "curve25519" ] && \
           is_valid_wg_key "$(jq -r '.secret_key // empty' "${warp_dir}/reg.json" 2>/dev/null)"; then
            wg_synced=true
            break
        fi
        if [ "$_i" -eq 3 ]; then
            warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
            warp-cli --accept-tos connect >/dev/null 2>&1 || true
            sleep 2
            warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
        fi
        sleep 1
    done

    if [ "$was_active" != "true" ]; then
        systemctl stop warp-svc 2>/dev/null || true
    fi

    [ "$wg_synced" = "true" ] || return 1

    WARP_SECRET_KEY=$(jq -r '.secret_key // empty' "${warp_dir}/reg.json" 2>/dev/null || true)
    WARP_IPV4=$(jq -r '.interface.v4 // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    WARP_IPV6=$(jq -r '.interface.v6 // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    local pub ep4 ep6 cid
    pub=$(jq -r '.public_key // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    ep4=$(jq -r '.endpoints[0].v4 // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    ep6=$(jq -r '.endpoints[0].v6 // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    cid=$(jq -r '.account.client_id // .client_id // empty' "${warp_dir}/conf.json" 2>/dev/null || true)
    if is_valid_wg_key "$pub"; then
        WARP_PUBKEY="$pub"
    fi
    [ -n "$ep4" ] && WARP_EP_V4="$ep4"
    [ -n "$ep6" ] && WARP_EP_V6="$ep6"
    WARP_RESERVED_JSON=$(decode_client_id_reserved "$cid")

    if is_valid_wg_key "$WARP_SECRET_KEY" && is_valid_wg_key "$WARP_PUBKEY" && [[ "$WARP_IPV6" == *:* ]]; then
        [ -z "$WARP_IPV4" ] && WARP_IPV4="172.16.0.2"
        save_cached_warp "$cid"
        return 0
    fi
    return 1
}

try_warp_official_api() {
    log_info "使用 Xray 内置 Curve25519 工具向 Cloudflare 官方接口申请轻量 WARP 凭据..."
    local wg_out priv_key pub_key install_id tos resp
    wg_out=$("$XRAY_BIN" wg 2>/dev/null || true)
    priv_key=$(echo "$wg_out" | awk '/^(Private|PrivateKey)/{print $NF}' | head -n1 | tr -d '\r')
    pub_key=$(echo "$wg_out" | awk '/^(Public|Password)/{print $NF}' | head -n1 | tr -d '\r')
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        return 1
    fi

    install_id=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 22)
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000+00:00)

    local payload
    payload=$(jq -n \
        --arg key "$pub_key" \
        --arg iid "$install_id" \
        --arg fcm "${install_id}:APA91b${install_id}" \
        --arg tos "$tos" \
        '{key:$key, install_id:$iid, fcm_token:$fcm, warp_enabled:true, tos:$tos, type:"Android", locale:"en_US"}')

    resp=$(curl -fsSL --connect-timeout 15 --retry 2 \
        -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -H "User-Agent: okhttp/3.12.1" \
        --data "$payload" 2>/dev/null || true)

    [ -z "$resp" ] && return 1

    WARP_SECRET_KEY="$priv_key"
    WARP_IPV4=$(echo "$resp" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null || true)
    WARP_IPV6=$(echo "$resp" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null || true)
    local srv_pub ep4 ep6 cid
    srv_pub=$(echo "$resp" | jq -r '.config.peers[0].public_key // empty' 2>/dev/null || true)
    ep4=$(echo "$resp" | jq -r '.config.peers[0].endpoint.v4 // empty' 2>/dev/null || true)
    ep6=$(echo "$resp" | jq -r '.config.peers[0].endpoint.v6 // empty' 2>/dev/null || true)
    cid=$(echo "$resp" | jq -r '.config.client_id // empty' 2>/dev/null || true)

    [ -n "$srv_pub" ] && WARP_PUBKEY="$srv_pub"
    if [ -n "$ep4" ]; then
        ep4="${ep4%:0}"
        [[ "$ep4" == *:* ]] || ep4="${ep4}:2408"
        WARP_EP_V4="$ep4"
    fi
    if [ -n "$ep6" ]; then
        ep6="${ep6%:0}"
        if [[ "$ep6" != \[* ]]; then
            ep6="[${ep6}]:2408"
        elif [[ "$ep6" != *]:* ]]; then
            ep6="${ep6}:2408"
        fi
        WARP_EP_V6="$ep6"
    fi
    WARP_RESERVED_JSON=$(decode_client_id_reserved "$cid")

    if [ -n "$WARP_SECRET_KEY" ] && [[ "$WARP_IPV6" == *:* ]]; then
        [ -z "$WARP_IPV4" ] && WARP_IPV4="172.16.0.2"
        save_cached_warp "$cid"
        return 0
    fi
    return 1
}

log_ok ">>> [TUNNEL 4/6] 配置 Cloudflare WARP 原生 WireGuard 出口分流..."
WARP_READY=false
if try_load_cached_warp; then
    WARP_READY=true
    log_ok "✅ 已复用本地缓存的 Cloudflare WARP 凭据。"
elif try_warp_official_cli; then
    WARP_READY=true
    log_ok "✅ 已通过官方 cloudflare-warp 客户端获取专属 WARP 凭据。"
elif try_warp_official_api; then
    WARP_READY=true
    log_ok "✅ 已通过 Cloudflare 官方注册接口获取轻量 WARP 凭据。"
fi

if [ "$WARP_READY" = "true" ]; then
    WARP_ENDPOINT="$WARP_EP_V4"
    if ! has_ipv4 && has_ipv6; then
        WARP_ENDPOINT="$WARP_EP_V6"
    fi
    RESERVED_LINE=""
    [ -n "$WARP_RESERVED_JSON" ] && RESERVED_LINE="\"reserved\": ${WARP_RESERVED_JSON},"

    WARP_OUTBOUND_JSON="{
      \"tag\": \"warp-out\",
      \"protocol\": \"wireguard\",
      \"settings\": {
        \"noKernelTun\": true,
        \"secretKey\": \"${WARP_SECRET_KEY}\",
        \"address\": [
          \"${WARP_IPV4}/32\",
          \"${WARP_IPV6}/128\"
        ],
        ${RESERVED_LINE}
        \"peers\": [
          {
            \"publicKey\": \"${WARP_PUBKEY}\",
            \"endpoint\": \"${WARP_ENDPOINT}\"
          }
        ],
        \"mtu\": 1280
      },
      \"streamSettings\": {
        \"sockopt\": {
          \"domainStrategy\": \"ForceIPv6\"
        }
      }
    },"
    WARP_ROUTING_RULE='{
        "type": "field",
        "outboundTag": "warp-out",
        "domain": [
          "geosite:openai",
          "geosite:google-deepmind"
        ]
      },'
    WARP_ENABLED_FLAG="1"
    log_ok "✅ Cloudflare WARP WireGuard 凭据就绪 (Endpoint: ${WARP_ENDPOINT}, IPv6: ${WARP_IPV6})！"
else
    log_warn "⚠️ 未能获取到有效的 Cloudflare WARP 凭据，AI 流量将暂退化为直连出站。"
    WARP_OUTBOUND_JSON=""
    WARP_ROUTING_RULE=""
    WARP_ENABLED_FLAG="0"
fi

log_ok ">>> [TUNNEL 5/6] 生成并校验隧道入栈 Xray 配置..."
UUID=$(extract_uuid_from_config "$XRAY_CONFIG")
[ -z "$UUID" ] && UUID=$(generate_uuid)
PATH_XC="/${UUID}-xc"

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
      "localhost"
    ],
    "queryStrategy": "UseIP"
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
        "sockopt": {
          "trustedXForwardedFor": [
            "CF-Connecting-IP"
          ]
        },
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
      {
        "type": "field",
        "outboundTag": "block",
        "ip": [
          "geoip:private"
        ]
      },
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

atomic_write_xray_config "$TMP_CFG" "$XRAY_CONFIG"

# 保存隧道元数据与环境变量密钥文件（600 权限，避免命令行明文泄漏 Token）
cat > "$TUNNEL_CONF" << EOF
CF_TUNNEL_DOMAIN="${CF_DOMAIN}"
CF_LOCAL_PORT="${LOCAL_PORT}"
TUNNEL_MODE="1"
CF_TUNNEL_ENABLED="1"
WARP_ENABLED="${WARP_ENABLED_FLAG}"
EOF
chmod 600 "$TUNNEL_CONF"

cat > "$TUNNEL_ENV" << EOF
TUNNEL_TOKEN=${CF_TOKEN}
EOF
chmod 600 "$TUNNEL_ENV"

log_ok ">>> [TUNNEL 6/6] 启动并守护服务 (自动适配环境)..."
if is_systemd; then
    log_info "检测到 Systemd，正在配置安全守护服务..."
    cat > /etc/systemd/system/xray.service << SERVICE
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

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

    write_cloudflared_systemd_unit

    systemctl daemon-reload
    systemctl enable xray cloudflared
    systemctl restart xray cloudflared
else
    log_warn "检测到非 Systemd 环境（Docker/PRoot 容器），采用后台自守护模式..."
    pkill -x xray 2>/dev/null || true
    pkill -x cloudflared 2>/dev/null || true
    sleep 1

    XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" nohup /usr/local/bin/xray run -c /etc/xray/config.json > /var/log/xray.log 2>&1 &
    ( set -a; . "$TUNNEL_ENV"; exec /usr/local/bin/cloudflared tunnel --no-autoupdate --loglevel warn run ) > /var/log/cloudflared.log 2>&1 &

    cleanup_autostart_hooks

    AUTORUN_CODE='
# BEGIN [xray-xhttp-warp]
if [ "$(id -u)" -eq 0 ] && [ -f /etc/xray/tunnel.conf ] && [ -r /etc/xray/tunnel.env ]; then
    if ! pgrep -x xray >/dev/null 2>&1; then
        XRAY_LOCATION_ASSET=/usr/local/share/xray nohup /usr/local/bin/xray run -c /etc/xray/config.json >/var/log/xray.log 2>&1 &
    fi
    if ! pgrep -x cloudflared >/dev/null 2>&1; then
        ( set -a; . /etc/xray/tunnel.env; exec /usr/local/bin/cloudflared tunnel --no-autoupdate --loglevel warn run ) >/var/log/cloudflared.log 2>&1 &
    fi
fi
# END [xray-xhttp-warp]'

    echo "$AUTORUN_CODE" >> /root/.bashrc
    [ -f /etc/profile ] && echo "$AUTORUN_CODE" >> /etc/profile
fi

# 安装 xm 管理命令并展示节点信息
install_ctl_script "xm_ctl.sh" "/usr/local/bin/xm" "/usr/bin/xm" "$SCRIPT_DIR"
sleep 2
if [ -x /usr/local/bin/xm ]; then
    /usr/local/bin/xm info
fi
