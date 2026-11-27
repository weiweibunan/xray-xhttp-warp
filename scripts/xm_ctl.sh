#!/bin/bash
# ==============================================================================
# Xray (XHTTP + 隧道穿透 / IPv6 S5 分流) 统一管理命令 (/usr/local/bin/xm)
# 单文件自包含，自动适配 Systemd 与无 Systemd 容器/沙箱环境
# ==============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
_XM_ARGS=("$@")
_CALLER_NAME=$(basename "$0")

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

XRAY_BIN="/usr/local/bin/xray"
CF_BIN="/usr/local/bin/cloudflared"
XRAY_ASSET_DIR="/usr/local/share/xray"
CONFIG="/etc/xray/config.json"
TUNNEL_CONF="/etc/xray/tunnel.conf"
TUNNEL_ENV="/etc/xray/tunnel.env"
CDN_HOST="www.shopify.com"
GEO_REPO_URL="https://github.com/Loyalsoldier/v2ray-rules-dat"
GEO_TIMER="/etc/systemd/system/xray-geo-update.timer"
GEO_SERVICE="/etc/systemd/system/xray-geo-update.service"
GEO_LOG="/var/log/xray-geo-update.log"
GEO_CRON_TAG="# xray-xhttp-warp-geo-update"

_NEEDS_ROOT=1
if [ "$_CALLER_NAME" = "warp" ]; then
    case "${1:-}" in
        ""|help|-h|--help|status|info|test|logs) _NEEDS_ROOT=0 ;;
    esac
elif [ "${1:-}" = "warp" ]; then
    case "${2:-}" in
        help|-h|--help|status|info|test|logs) _NEEDS_ROOT=0 ;;
    esac
fi

if [ "$_NEEDS_ROOT" -eq 1 ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && [[ "${BASH_SOURCE[0]}" != /dev/fd/* ]] && [[ "${BASH_SOURCE[0]}" != /proc/*/fd/* ]]; then
        echo ">>> 检测到当前为非 root 用户 ($(id -un))，正在通过 sudo 自动提权..." >&2
        _ELEVATE_ENV=()
        for _v in REPO_URL CERT_PATH KEY_PATH CF_TOKEN CF_DOMAIN LOCAL_PORT; do
            [ "${!_v+set}" = "set" ] && _ELEVATE_ENV+=("${_v}=${!_v}")
        done
        _SELF_ABS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
        exec sudo env "${_ELEVATE_ENV[@]}" bash "$_SELF_ABS" "${_XM_ARGS[@]}"
    fi
    echo -e "${RED}❌ 请使用 root 权限执行此命令！（提示：非 root 用户请先执行 'sudo -i' 或使用 sudo 运行）${PLAIN}" >&2
    exit 1
fi

read_tty() {
    if [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then
        read "$@" </dev/tty
    else
        read "$@"
    fi
}

is_systemd() {
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

is_proc_alive() {
    local target="$1"
    if ps -eo stat=,comm= >/dev/null 2>&1; then
        ps -eo stat=,comm= 2>/dev/null | awk -v t="$target" '$1 !~ /^Z/ && $2 == t {found=1} END{exit !found}'
        return $?
    fi
    pgrep -x "$target" >/dev/null 2>&1
}

first_live_pid() {
    local target="$1"
    if ps -eo pid=,stat=,comm= >/dev/null 2>&1; then
        ps -eo pid=,stat=,comm= 2>/dev/null | awk -v t="$target" '$2 !~ /^Z/ && $3 == t {print $1; exit}'
        return 0
    fi
    pgrep -x "$target" 2>/dev/null | head -n1
}

list_live_procs() {
    local target="$1"
    if ps -eo pid=,stat=,comm=,args= >/dev/null 2>&1; then
        ps -eo pid=,stat=,comm=,args= 2>/dev/null | awk -v t="$target" '$2 !~ /^Z/ && $3 == t {pid=$1; $1=$2=$3=""; sub(/^[[:space:]]+/, ""); print pid, $0}'
        return 0
    fi
    pgrep -a -x "$target" 2>/dev/null || true
}

# 安全加载隧道元配置（避免从旧配置遗留问题直接执行任意代码）
load_tunnel_meta() {
    TUNNEL_MODE="0"
    CF_TUNNEL_ENABLED="0"
    CF_TUNNEL_DOMAIN=""
    CF_LOCAL_PORT="8080"
    WARP_ENABLED="1"
    TUNNEL_TOKEN=""

    if [ -f "$TUNNEL_CONF" ]; then
        TUNNEL_MODE=$(grep -E '^TUNNEL_MODE=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        CF_TUNNEL_ENABLED=$(grep -E '^CF_TUNNEL_ENABLED=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        CF_TUNNEL_DOMAIN=$(grep -E '^CF_TUNNEL_DOMAIN=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        CF_LOCAL_PORT=$(grep -E '^CF_LOCAL_PORT=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        WARP_ENABLED=$(grep -E '^WARP_ENABLED=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        local legacy_token
        legacy_token=$(grep -E '^CF_TUNNEL_TOKEN=' "$TUNNEL_CONF" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        [ -n "$legacy_token" ] && TUNNEL_TOKEN="$legacy_token"
    fi
    if [ -f "$TUNNEL_ENV" ]; then
        local env_token
        env_token=$(grep -E '^TUNNEL_TOKEN=' "$TUNNEL_ENV" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d "\"' \r")
        [ -n "$env_token" ] && TUNNEL_TOKEN="$env_token"
    fi
    [ -z "$TUNNEL_MODE" ] && TUNNEL_MODE="0"
    if [ -z "$CF_TUNNEL_ENABLED" ]; then
        [ "$TUNNEL_MODE" = "1" ] && CF_TUNNEL_ENABLED="1" || CF_TUNNEL_ENABLED="0"
    fi
    [ -z "$CF_LOCAL_PORT" ] && CF_LOCAL_PORT="8080"
    [ -z "$WARP_ENABLED" ] && WARP_ENABLED="1"
}

is_tunnel_active() {
    [ "$TUNNEL_MODE" = "1" ] || [ "$CF_TUNNEL_ENABLED" = "1" ]
}

load_tunnel_meta

compute_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print tolower($1)}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
    else
        echo ""
    fi
}

get_inbound_field() {
    local tag="$1"
    local field="$2"
    if command -v jq >/dev/null 2>&1; then
        case "$field" in
            port) jq -r --arg t "$tag" '(.inbounds // [])[] | select(.tag == $t) | .port // empty' "$CONFIG" 2>/dev/null | head -n1 ;;
            path) jq -r --arg t "$tag" '(.inbounds // [])[] | select(.tag == $t) | .streamSettings.xhttpSettings.path // empty' "$CONFIG" 2>/dev/null | head -n1 ;;
            cert) jq -r --arg t "$tag" '(.inbounds // [])[] | select(.tag == $t) | .streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$CONFIG" 2>/dev/null | head -n1 ;;
            uuid) jq -r '(.inbounds // [])[] | (.settings.clients // [])[] | .id // empty' "$CONFIG" 2>/dev/null | grep -E '^[0-9a-fA-F-]{36}$' | head -n1 ;;
        esac
    else
        case "$field" in
            uuid)
                grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' "$CONFIG" 2>/dev/null | head -n1 | grep -oE '[0-9a-fA-F-]{36}'
                ;;
            cert)
                grep -oE '"certificateFile"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG" 2>/dev/null | head -n1 | cut -d'"' -f4
                ;;
            port|path)
                awk -v tag="\"$tag\"" -v key="\"$field\"" '
                    $0 ~ tag { found=1; depth=1; next }
                    found {
                        if ($0 ~ key "[[:space:]]*:") {
                            val=$0
                            sub(/^[^:]*:[[:space:]]*/, "", val)
                            gsub(/[",[:space:]]/, "", val)
                            print val
                            exit
                        }
                        if ($0 ~ /"tag"[[:space:]]*:/) { exit }
                    }
                ' "$CONFIG" 2>/dev/null
                ;;
        esac
    fi
}

fetch_public_ip() {
    local ip
    ip=$(curl -fsS4 --connect-timeout 3 --max-time 5 https://icanhazip.com 2>/dev/null || \
         curl -fsS4 --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(curl -fsS6 --connect-timeout 3 --max-time 5 https://icanhazip.com 2>/dev/null || \
             curl -fsS6 --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
    fi
    ip=$(echo "$ip" | tr -d ' \r\n')
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

format_host_for_url() {
    local host="$1"
    if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
        echo "[${host}]"
    else
        echo "$host"
    fi
}

extract_sni_from_cert() {
    local cert_file="$1"
    [ -f "$cert_file" ] || return 0
    local san_list first_concrete first_any cn
    san_list=$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -oE '(DNS:[^, \r\n]+|IP Address:[^, \r\n]+)' | sed -E 's/^(DNS:|IP Address:)//' || true)
    if [ -z "$san_list" ]; then
        san_list=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | awk '/Subject Alternative Name/{getline; print}' | grep -oE '(DNS:[^, \r\n]+|IP Address:[^, \r\n]+)' | sed -E 's/^(DNS:|IP Address:)//' || true)
    fi
    first_concrete=$(echo "$san_list" | grep -v '^\*\.' | head -n1 || true)
    first_any=$(echo "$san_list" | head -n1 || true)
    if [ -n "$first_concrete" ]; then
        echo "$first_concrete"
        return 0
    fi
    cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | cut -d',' -f1 | tr -d ' \r\n' || true)
    if [ -n "$cn" ] && [[ "$cn" != \*.* ]]; then
        echo "$cn"
        return 0
    fi
    [ -n "$first_any" ] && echo "$first_any"
}

show_info() {
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}❌ 未找到配置文件 $CONFIG，请先安装 Xray！${PLAIN}"
        return 1
    fi
    load_tunnel_meta

    local uuid x_status cf_status
    uuid=$(get_inbound_field "" "uuid")

    if is_systemd; then
        local x_act cf_act
        x_act=$(systemctl is-active xray 2>/dev/null || true)
        cf_act=$(systemctl is-active cloudflared 2>/dev/null || true)
        [ -z "$x_act" ] && x_act="inactive"
        [ -z "$cf_act" ] && cf_act="inactive"
        [ "$x_act" = "active" ] && x_status="${GREEN}运行中 (active)${PLAIN}" || x_status="${RED}未运行 ($x_act)${PLAIN}"
        [ "$cf_act" = "active" ] && cf_status="${GREEN}运行中 (active)${PLAIN}" || cf_status="${RED}未运行 ($cf_act)${PLAIN}"
    else
        is_proc_alive xray && x_status="${GREEN}运行中 (PID: $(first_live_pid xray))${PLAIN}" || x_status="${RED}未运行${PLAIN}"
        is_proc_alive cloudflared && cf_status="${GREEN}运行中 (PID: $(first_live_pid cloudflared))${PLAIN}" || cf_status="${RED}未运行${PLAIN}"
    fi

    # ---------------- 容器/隧道穿透模式 ----------------
    if [ "$TUNNEL_MODE" = "1" ]; then
        local path_xc port_local domain warp_desc
        path_xc=$(get_inbound_field "xhttp-tunnel-in" "path")
        [ -z "$path_xc" ] && path_xc="/${uuid}-xc"
        port_local=$(get_inbound_field "xhttp-tunnel-in" "port")
        [ -z "$port_local" ] && port_local="$CF_LOCAL_PORT"

        if [ -n "$CF_TUNNEL_DOMAIN" ]; then
            domain="$CF_TUNNEL_DOMAIN"
        else
            domain=$(fetch_public_ip)
        fi

        if [ "$WARP_ENABLED" = "1" ]; then
            warp_desc="${YELLOW}OpenAI + Gemini -> Cloudflare WARP (WireGuard ForceIPv6)${PLAIN}"
        else
            warp_desc="${YELLOW}已退化为容器直连 (未检测到有效 WARP 凭据)${PLAIN}"
        fi

        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "  运行模式      : ${CYAN}容器/NAT 穿透模式 (Cloudflare Tunnel 隧道入栈)${PLAIN}"
        echo -e "  Xray 服务状态 : $x_status"
        echo -e "  隧道服务状态  : $cf_status"
        echo -e "  分流出站配置  : $warp_desc"
        echo -e "  隧道绑定域名  : ${CYAN}${domain}${PLAIN}"
        echo -e "  本地监听端口  : ${CYAN}127.0.0.1:${port_local}${PLAIN} (免证书/本地回环)"
        echo -e "  用户 UUID     : ${CYAN}${uuid}${PLAIN}"
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "${GREEN}🌐 节点：【VLESS - XHTTP - Cloudflare 优选节点】${PLAIN}(免公网端口/全CDN加速/抗封锁)"
        echo -e "${YELLOW}vless://${uuid}@${CDN_HOST}:443?encryption=none&security=tls&sni=${domain}&host=${domain}&type=xhttp&path=${path_xc}&mode=auto#XHTTP-CF-Tunnel-优选${PLAIN}"
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "💡 ${CYAN}优选节点使用贴士：${PLAIN}"
        echo -e "  1. 链接地址默认为 ${GREEN}${CDN_HOST}${PLAIN}，导入客户端后可替换为任意 Cloudflare 优选 IP/优选域名。"
        echo -e "  2. 确保 Cloudflare Zero Trust 中已为 ${CYAN}${domain}${PLAIN} 配置 Public Hostname 指向："
        echo -e "     - Service Type : ${GREEN}HTTP${PLAIN}"
        echo -e "     - URL          : ${GREEN}127.0.0.1:${port_local}${PLAIN} (或 localhost:${port_local})"
        echo -e "${BLUE}====================================================================${PLAIN}"
        return 0
    fi

    # ---------------- 标准原生 VPS 模式 ----------------
    local cert_file ip sni node_addr path_h3 path_xc port_h3 port_xc
    cert_file=$(get_inbound_field "xhttp-cdn-443-in" "cert")
    if [ -z "$cert_file" ]; then
        [ -f "/etc/xray/cert/cert.crt" ] && cert_file="/etc/xray/cert/cert.crt"
    fi
    ip=$(fetch_public_ip)
    sni=$(extract_sni_from_cert "$cert_file")

    if [ -z "$sni" ]; then
        sni="$ip"
        node_addr=$(format_host_for_url "$ip")
    elif [[ "$sni" == \*.* ]]; then
        echo -e "${YELLOW}⚠️ 检测到通配符证书 (${sni})，直连地址将使用服务器 IP，请按需在客户端调整 SNI/Host 为真实子域。${PLAIN}"
        node_addr=$(format_host_for_url "$ip")
    else
        node_addr=$(format_host_for_url "$sni")
    fi

    path_h3=$(get_inbound_field "xhttp-h3-in" "path")
    path_xc=$(get_inbound_field "xhttp-cdn-443-in" "path")
    port_h3=$(get_inbound_field "xhttp-h3-in" "port")
    port_xc=$(get_inbound_field "xhttp-cdn-443-in" "port")

    [ -z "$path_h3" ] && path_h3="/${uuid}-xu"
    [ -z "$path_xc" ] && path_xc="/${uuid}-xc"
    [ -z "$port_h3" ] && port_h3=8443
    [ -z "$port_xc" ] && port_xc=443

    local path_xt port_xt
    path_xt=$(get_inbound_field "xhttp-tunnel-in" "path")
    port_xt=$(get_inbound_field "xhttp-tunnel-in" "port")

    echo -e "${BLUE}==================================================${PLAIN}"
    if [ "$CF_TUNNEL_ENABLED" = "1" ] || [ -n "$path_xt" ]; then
        echo -e "  运行模式      : ${CYAN}标准原生 VPS + CF 隧道双模式${PLAIN}"
        echo -e "  Xray 服务状态 : $x_status"
        echo -e "  隧道服务状态  : $cf_status"
    else
        echo -e "  运行模式      : ${CYAN}标准原生 VPS 模式${PLAIN}"
        echo -e "  Xray 服务状态 : $x_status"
    fi
    echo -e "  服务器公网 IP : ${CYAN}${ip}${PLAIN}"
    echo -e "  SNI 证书域名  : ${CYAN}${sni}${PLAIN}"
    echo -e "  用户 UUID     : ${CYAN}${uuid}${PLAIN}"
    echo -e "  分流出站配置  : ${YELLOW}OpenAI + Gemini -> ForceIPv6 -> 127.0.0.1:40000${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}🌐 节点 1：【VLESS - XHTTP - CDN 优选节点】${PLAIN}(防封/CDN加速)"
    echo -e "${YELLOW}vless://${uuid}@${CDN_HOST}:${port_xc}?encryption=none&security=tls&sni=${sni}&host=${sni}&type=xhttp&path=${path_xc}&mode=auto#XHTTP-CDN-Shopify${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}🛡️ 节点 2：【VLESS - XHTTP - TCP ${port_xc} 直连】${PLAIN}(无 CDN 延迟损耗)"
    echo -e "${YELLOW}vless://${uuid}@${node_addr}:${port_xc}?encryption=none&security=tls&sni=${sni}&host=${sni}&type=xhttp&path=${path_xc}&mode=auto#XHTTP-TCP-Direct-${port_xc}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}🚀 节点 3：【VLESS - XHTTP - H3 ${port_h3} 直连】${PLAIN}(QUIC/UDP 抗丢包)"
    echo -e "${YELLOW}vless://${uuid}@${node_addr}:${port_h3}?encryption=none&security=tls&sni=${sni}&host=${sni}&alpn=h3&type=xhttp&path=${path_h3}&mode=auto#XHTTP-H3-Direct-${port_h3}${PLAIN}"
    if [ "$CF_TUNNEL_ENABLED" = "1" ] || [ -n "$path_xt" ]; then
        [ -z "$path_xt" ] && path_xt="/${uuid}-xt"
        [ -z "$port_xt" ] && port_xt="${CF_LOCAL_PORT:-8080}"
        local tun_dom="${CF_TUNNEL_DOMAIN:-${sni}}"
        echo -e "--------------------------------------------------"
        echo -e "${GREEN}☁️  节点 4：【VLESS - XHTTP - Cloudflare Tunnel 优选】${PLAIN}(免端口/内网回源)"
        echo -e "${YELLOW}vless://${uuid}@${CDN_HOST}:443?encryption=none&security=tls&sni=${tun_dom}&host=${tun_dom}&type=xhttp&path=${path_xt}&mode=auto#XHTTP-CF-Tunnel-优选${PLAIN}"
        echo -e "  💡 Zero Trust Public Hostname (${CYAN}${tun_dom}${PLAIN}) 请指向: ${GREEN}HTTP -> 127.0.0.1:${port_xt}${PLAIN}"
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
}

ensure_tunnel_env_file() {
    if [ -n "$TUNNEL_TOKEN" ] && [ ! -f "$TUNNEL_ENV" ]; then
        mkdir -p "$(dirname "$TUNNEL_ENV")"
        printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > "$TUNNEL_ENV"
        chmod 600 "$TUNNEL_ENV"
    fi
}

start_cloudflared_container() {
    ensure_tunnel_env_file
    if [ -f "$TUNNEL_ENV" ]; then
        ( set -a; . "$TUNNEL_ENV"; exec nohup "$CF_BIN" tunnel --no-autoupdate --loglevel warn run ) >/var/log/cloudflared.log 2>&1 &
    fi
}

stop_proc_graceful() {
    local proc_name="$1" i
    pkill -x "$proc_name" 2>/dev/null || true
    for i in $(seq 1 25); do
        is_proc_alive "$proc_name" || return 0
        sleep 0.2
    done
    pkill -9 -x "$proc_name" 2>/dev/null || true
    sleep 0.2
}

start_xray() {
    load_tunnel_meta
    if is_systemd; then
        systemctl start xray
        if is_tunnel_active; then
            ensure_tunnel_env_file
            systemctl start cloudflared
        fi
    else
        if ! is_proc_alive xray; then
            XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" nohup "$XRAY_BIN" run -c "$CONFIG" >/var/log/xray.log 2>&1 &
        fi
        if is_tunnel_active && ! is_proc_alive cloudflared; then
            start_cloudflared_container
        fi
    fi
    echo -e "${GREEN}✅ 服务已启动！${PLAIN}"
}

stop_xray() {
    load_tunnel_meta
    if is_systemd; then
        systemctl stop xray 2>/dev/null || true
        is_tunnel_active && systemctl stop cloudflared 2>/dev/null || true
    else
        stop_proc_graceful xray
        stop_proc_graceful cloudflared
    fi
    echo -e "${YELLOW}⏸️ 服务已停止！${PLAIN}"
}

restart_xray() {
    if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$CONFIG" >/dev/null 2>&1; then
        echo -e "${RED}❌ 配置语法测试失败，请勿重启，请先检查配置！${PLAIN}"
        XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$CONFIG"
        return 1
    fi
    load_tunnel_meta
    if is_systemd; then
        systemctl restart xray
        if is_tunnel_active; then
            ensure_tunnel_env_file
            systemctl restart cloudflared 2>/dev/null || true
        fi
    else
        stop_proc_graceful xray
        stop_proc_graceful cloudflared
        XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" nohup "$XRAY_BIN" run -c "$CONFIG" >/var/log/xray.log 2>&1 &
        is_tunnel_active && start_cloudflared_container
    fi
    echo -e "${GREEN}✅ 服务已成功重启！${PLAIN}"
}

status_xray() {
    load_tunnel_meta
    if is_systemd; then
        echo -e "${CYAN}>>> Xray 服务状态 (Systemd):${PLAIN}"
        systemctl status xray --no-pager
        if is_tunnel_active; then
            echo -e "\n${CYAN}>>> Cloudflare Tunnel 状态 (Systemd):${PLAIN}"
            systemctl status cloudflared --no-pager
        fi
    else
        echo -e "${CYAN}>>> 进程运行状态 (容器环境):${PLAIN}"
        local live_x live_cf
        live_x=$(list_live_procs xray)
        [ -n "$live_x" ] && echo "$live_x" || echo "xray 未运行"
        if is_tunnel_active; then
            live_cf=$(list_live_procs cloudflared)
            [ -n "$live_cf" ] && echo "$live_cf" || echo "cloudflared 未运行"
        fi
        echo -e "\n${CYAN}>>> 本地监听端口:${PLAIN}"
        if command -v ss >/dev/null 2>&1; then
            ss -tulnp 2>/dev/null | grep -E 'xray|cloudflared' || true
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tulnp 2>/dev/null | grep -E 'xray|cloudflared' || true
        else
            echo "未检测到 ss / netstat 工具（跳过端口展示）"
        fi
    fi
}

show_log() {
    load_tunnel_meta
    local cur_level="error"
    if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
        cur_level=$(jq -r '.log.loglevel // "error"' "$CONFIG" 2>/dev/null || echo "error")
    fi
    [ "$cur_level" = "error" ] && echo -e "${YELLOW}💡 当前 Xray 日志级别为 error（仅记录报错）；如需看连接记录，可先运行 xm loglevel info。${PLAIN}"

    if is_tunnel_active; then
        echo -e "请选择要查看的日志："
        echo -e " 1) Xray 运行日志"
        echo -e " 2) Cloudflare 隧道日志"
        read_tty -p "请输入选项 [1-2, 默认 1]: " log_choice
        if [ "$log_choice" = "2" ]; then
            echo -e "${CYAN}>>> 查看 Cloudflare 隧道日志 (Ctrl+C 退出)...${PLAIN}"
            if is_systemd; then
                journalctl -u cloudflared -f -n 50
            else
                tail -n 50 -f /var/log/cloudflared.log 2>/dev/null || echo "未找到日志文件 /var/log/cloudflared.log"
            fi
            return
        fi
    fi

    echo -e "${CYAN}>>> 查看 Xray 运行日志 (Ctrl+C 退出)...${PLAIN}"
    if is_systemd; then
        journalctl -u xray -f -n 50
    else
        tail -n 50 -f /var/log/xray.log 2>/dev/null || echo "未找到日志文件 /var/log/xray.log"
    fi
}

set_loglevel() {
    [ -f "$CONFIG" ] || { echo -e "${RED}❌ 未找到配置文件 $CONFIG${PLAIN}"; return 1; }
    local target="${1:-}"
    if [ -z "$target" ]; then
        read_tty -p "请输入目标日志级别 (error / warning / info / debug): " target
    fi
    case "$target" in
        error|warning|info|debug|none) ;;
        *) echo -e "${RED}❌ 无效日志级别: ${target}${PLAIN}"; return 1 ;;
    esac

    local tmp_dir tmp_cfg
    tmp_dir=$(mktemp -d)
    tmp_cfg="${tmp_dir}/config.json"
    if command -v jq >/dev/null 2>&1; then
        jq --arg lvl "$target" '.log.loglevel = $lvl' "$CONFIG" > "$tmp_cfg"
    else
        sed -E "s/\"loglevel\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"loglevel\": \"${target}\"/" "$CONFIG" > "$tmp_cfg"
    fi
    if XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
        chmod 644 "$tmp_cfg"
        mv -f "$tmp_cfg" "$CONFIG"
        rm -rf "$tmp_dir"
        restart_xray
        echo -e "${GREEN}✅ 日志级别已切换为: ${target}${PLAIN}"
    else
        rm -rf "$tmp_dir"
        echo -e "${RED}❌ 切换日志级别失败！${PLAIN}"
        return 1
    fi
}

reset_uuid() {
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}❌ 未找到配置文件 $CONFIG！${PLAIN}"
        return 1
    fi
    local old_uuid new_uuid
    old_uuid=$(get_inbound_field "" "uuid")
    if [ -z "$old_uuid" ]; then
        echo -e "${RED}❌ 未能从 $CONFIG 解析到现有 UUID，已取消操作以防破坏配置！${PLAIN}"
        return 1
    fi
    new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')

    echo -e "当前 UUID : ${YELLOW}$old_uuid${PLAIN}"
    echo -e "新 UUID   : ${GREEN}$new_uuid${PLAIN}"
    read_tty -p "确认更换 UUID 并自动更新配置与路径？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        local tmp_dir tmp_cfg
        tmp_dir=$(mktemp -d)
        tmp_cfg="${tmp_dir}/config.json"
        sed "s/${old_uuid}/${new_uuid}/g" "$CONFIG" > "$tmp_cfg"
        if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
            rm -rf "$tmp_dir"
            echo -e "${RED}❌ 新配置校验失败，已回滚！${PLAIN}"
            return 1
        fi
        chmod 644 "$tmp_cfg"
        mv -f "$tmp_cfg" "$CONFIG"
        rm -rf "$tmp_dir"
        restart_xray
        echo -e "${GREEN}✅ UUID 更换成功！新节点信息如下：${PLAIN}"
        show_info
    else
        echo -e "${YELLOW}操作已取消。${PLAIN}"
    fi
}

write_cloudflared_unit_local() {
    cat > /etc/systemd/system/cloudflared.service << 'SERVICE'
[Unit]
Description=Cloudflare Tunnel Agent
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/xray/tunnel.env
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE
}

install_cloudflared_local() {
    local arch cf_arch cf_url tmp_cf
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) cf_arch="amd64" ;;
        aarch64|arm64) cf_arch="arm64" ;;
        armv7l|armv7) cf_arch="arm" ;;
        i386|i686) cf_arch="386" ;;
        *)
            echo -e "${RED}❌ 不支持的系统架构 (${arch})，无法自动安装 cloudflared！${PLAIN}"
            return 1
            ;;
    esac
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    echo -e "${CYAN}>>> 正在下载官方 cloudflared (${cf_arch})...${PLAIN}"
    tmp_cf=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 --retry 3 "$cf_url" -o "$tmp_cf"; then
        rm -f "$tmp_cf"
        echo -e "${RED}❌ 下载 cloudflared 失败！${PLAIN}"
        return 1
    fi
    install -m 755 "$tmp_cf" "$CF_BIN"
    rm -f "$tmp_cf"
}

is_tcp_port_occupied_by_other() {
    local port="$1" line=""
    if command -v ss >/dev/null 2>&1; then
        line=$(ss -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    elif command -v netstat >/dev/null 2>&1; then
        line=$(netstat -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    fi
    [ -z "$line" ] && return 1
    echo "$line" | grep -qE '"xray"|[0-9]+/xray' && return 1
    echo "$line"
    return 0
}

prompt_tunnel_fields() {
    local ask_port="${1:-0}"
    local default_port="${2:-${CF_LOCAL_PORT:-8080}}"
    local port_xc="${3:-}"
    local port_h3="${4:-}"
    local input_token input_domain input_port conflict

    while true; do
        if [ -n "$TUNNEL_TOKEN" ]; then
            read_tty -p "请输入 Cloudflare Tunnel Token [回车保持现有]: " input_token || return 1
            [ -z "$input_token" ] && input_token="$TUNNEL_TOKEN"
        else
            read_tty -p "请输入 Cloudflare Tunnel Token (隧道密钥): " input_token || return 1
        fi
        _INPUT_CF_TOKEN=$(echo "$input_token" | sed -E 's/.*(--token|service install)[ =]+//; s/^[ \t]*//; s/[ \t]*$//' | tr -d '\r\n"'\'' ')
        if [ -z "$_INPUT_CF_TOKEN" ]; then
            echo -e "${RED}❌ Token 不能为空，请从 Cloudflare Zero Trust 控制台复制！${PLAIN}"
        elif [[ ! "$_INPUT_CF_TOKEN" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
            echo -e "${RED}❌ Token 格式非法（包含空白或特殊符号），请重新检查！${PLAIN}"
        else
            break
        fi
    done

    while true; do
        if [ -n "$CF_TUNNEL_DOMAIN" ]; then
            read_tty -p "请输入绑定的隧道域名 (如 node.example.com) [回车保持现有: ${CF_TUNNEL_DOMAIN}]: " input_domain || return 1
            [ -z "$input_domain" ] && input_domain="$CF_TUNNEL_DOMAIN"
        else
            read_tty -p "请输入 Cloudflare 绑定的隧道域名 (如 node.example.com): " input_domain || return 1
        fi
        _INPUT_CF_DOMAIN=$(echo "$input_domain" | sed -E 's#^https?://##; s#/.*$##; s/:[0-9]+$//' | tr -d ' \r\n"'\''' | tr '[:upper:]' '[:lower:]')
        if [ -z "$_INPUT_CF_DOMAIN" ]; then
            echo -e "${RED}❌ 隧道域名不能为空！${PLAIN}"
        elif [[ ! "$_INPUT_CF_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            echo -e "${RED}❌ 隧道域名格式无效 (${_INPUT_CF_DOMAIN})，请重新输入！${PLAIN}"
        else
            break
        fi
    done

    _INPUT_CF_PORT="$default_port"
    if [ "$ask_port" = "1" ]; then
        while true; do
            read_tty -p "请输入本地 Xray 隧道监听端口 [默认 ${default_port}]: " input_port || return 1
            [ -z "$input_port" ] && input_port="$default_port"
            if [[ ! "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
                echo -e "${RED}❌ 端口必须是 1-65535 之间的数字！${PLAIN}"
                continue
            fi
            if [ "$input_port" = "$port_xc" ] || [ "$input_port" = "$port_h3" ]; then
                echo -e "${RED}❌ 本地隧道端口 (${input_port}) 不能与原生入站端口 (${port_xc}/${port_h3}) 冲突！${PLAIN}"
                continue
            fi
            conflict=$(is_tcp_port_occupied_by_other "$input_port" || true)
            if [ -n "$conflict" ]; then
                echo -e "${RED}❌ TCP 端口 ${input_port} 已被其他进程占用: ${conflict}${PLAIN}"
                continue
            fi
            _INPUT_CF_PORT="$input_port"
            break
        done
    fi
}

save_tunnel_meta_and_env() {
    local token="$1" domain="$2" port="$3" mode="${4:-0}" enabled="${5:-1}" warp="${6:-1}"
    mkdir -p "$(dirname "$TUNNEL_CONF")"
    cat > "$TUNNEL_CONF" << EOF
CF_TUNNEL_DOMAIN="${domain}"
CF_LOCAL_PORT="${port}"
TUNNEL_MODE="${mode}"
CF_TUNNEL_ENABLED="${enabled}"
WARP_ENABLED="${warp}"
EOF
    chmod 600 "$TUNNEL_CONF"

    cat > "$TUNNEL_ENV" << EOF
TUNNEL_TOKEN=${token}
EOF
    chmod 600 "$TUNNEL_ENV"
}

update_tunnel_token() {
    load_tunnel_meta
    if ! is_tunnel_active; then
        echo -e "${YELLOW}⚠️ 当前尚未启用 Cloudflare Tunnel。若要在标准 VPS 模式开启附加隧道，请运行 xm tunnel enable。${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}     更新 Cloudflare Tunnel 隧道密钥与域名        ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    prompt_tunnel_fields 0 "${CF_LOCAL_PORT:-8080}" || return 1

    TUNNEL_TOKEN="$_INPUT_CF_TOKEN"
    CF_TUNNEL_DOMAIN="$_INPUT_CF_DOMAIN"
    CF_TUNNEL_ENABLED="1"
    save_tunnel_meta_and_env "$TUNNEL_TOKEN" "$CF_TUNNEL_DOMAIN" "${CF_LOCAL_PORT:-8080}" "${TUNNEL_MODE:-0}" "1" "${WARP_ENABLED:-1}"

    if is_systemd; then
        write_cloudflared_unit_local
        systemctl daemon-reload
        systemctl enable cloudflared 2>/dev/null || true
        systemctl restart cloudflared
    else
        stop_proc_graceful cloudflared
        start_cloudflared_container
    fi

    echo -e "${GREEN}✅ Cloudflare 隧道配置已更新并重启！${PLAIN}"
    show_info
}

manage_native_tunnel() {
    local sub="${1:-}"
    local flag="${2:-}"
    load_tunnel_meta

    if [ "$TUNNEL_MODE" = "1" ]; then
        if [ "$sub" = "status" ]; then
            status_xray
            return $?
        fi
        echo -e "${YELLOW}💡 当前处于纯容器/NAT 穿透模式，隧道为基础入栈不可关闭；如需更新 Token/域名请使用 xm token。${PLAIN}"
        if [ "$sub" = "enable" ] || [ "$sub" = "update" ]; then
            update_tunnel_token
        fi
        return $?
    fi

    [ -f "$CONFIG" ] || { echo -e "${RED}❌ 未找到配置文件 $CONFIG，请先安装 Xray！${PLAIN}"; return 1; }

    local has_xt="0" cur_port cur_path
    cur_port=$(get_inbound_field "xhttp-tunnel-in" "port")
    cur_path=$(get_inbound_field "xhttp-tunnel-in" "path")
    [ -n "$cur_path" ] && has_xt="1"

    if [ -z "$sub" ]; then
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}     标准 VPS Cloudflare Tunnel 附加隧道管理      ${PLAIN}"
        if [ "$CF_TUNNEL_ENABLED" = "1" ] || [ "$has_xt" = "1" ]; then
            echo -e "     当前状态: ${GREEN}已开启${PLAIN} (${CYAN}${CF_TUNNEL_DOMAIN:-未知} -> 127.0.0.1:${cur_port:-$CF_LOCAL_PORT}${PLAIN})"
        else
            echo -e "     当前状态: ${YELLOW}未开启 (仅原生 443/8443 双栈)${PLAIN}"
        fi
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 开启 / 更新 Cloudflare Tunnel 附加隧道 (enable)"
        echo -e " ${GREEN}2.${PLAIN} 查看附加隧道状态与配置 (status)"
        echo -e " ${RED}3.${PLAIN} 关闭并移除 Cloudflare Tunnel 附加隧道 (disable)"
        echo -e " ${YELLOW}0.${PLAIN} 返回"
        echo -e "${BLUE}==================================================${PLAIN}"
        local c
        read_tty -p "请输入选项 [0-3]: " c || return 1
        case "$c" in
            1) sub="enable" ;;
            2) sub="status" ;;
            3) sub="disable" ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效！${PLAIN}"; return 1 ;;
        esac
    fi

    case "$sub" in
        status)
            echo -e "${BLUE}==================================================${PLAIN}"
            echo -e "${GREEN}       标准 VPS Cloudflare Tunnel 状态            ${PLAIN}"
            echo -e "${BLUE}==================================================${PLAIN}"
            if [ "$CF_TUNNEL_ENABLED" = "1" ] || [ "$has_xt" = "1" ]; then
                echo -e "  附加隧道状态  : ${GREEN}已启用${PLAIN}"
                echo -e "  隧道绑定域名  : ${CYAN}${CF_TUNNEL_DOMAIN:-未设置}${PLAIN}"
                echo -e "  本地回源监听  : ${CYAN}127.0.0.1:${cur_port:-$CF_LOCAL_PORT}${PLAIN}"
                echo -e "  隧道入站路径  : ${CYAN}${cur_path:-未知}${PLAIN}"
                echo -e "  Zero Trust配置: ${GREEN}HTTP -> 127.0.0.1:${cur_port:-$CF_LOCAL_PORT}${PLAIN}"
                if is_systemd; then
                    echo -e "\n${CYAN}>>> cloudflared 服务状态:${PLAIN}"
                    systemctl status cloudflared --no-pager || true
                else
                    echo -e "\n${CYAN}>>> cloudflared 进程状态:${PLAIN}"
                    local live_cf_st
                    live_cf_st=$(list_live_procs cloudflared)
                    [ -n "$live_cf_st" ] && echo "$live_cf_st" || echo "cloudflared 未运行"
                fi
            else
                echo -e "  附加隧道状态  : ${YELLOW}未启用${PLAIN}"
                echo -e "  提示          : 运行 ${GREEN}xm tunnel enable${PLAIN} 可随时开启第 4 个隧道优选节点。"
            fi
            echo -e "${BLUE}==================================================${PLAIN}"
            ;;
        enable|update|on)
            if ! command -v jq >/dev/null 2>&1; then
                echo -e "${RED}❌ 未检测到 jq，请先安装 jq (apt/yum install -y jq) 后重试！${PLAIN}"
                return 1
            fi
            local uuid port_xc port_h3 default_port xt_path tmp_dir tmp_cfg
            uuid=$(get_inbound_field "" "uuid")
            if [ -z "$uuid" ]; then
                echo -e "${RED}❌ 未能从 $CONFIG 解析到现有 UUID！${PLAIN}"
                return 1
            fi
            port_xc=$(get_inbound_field "xhttp-cdn-443-in" "port")
            port_h3=$(get_inbound_field "xhttp-h3-in" "port")
            default_port="${cur_port:-${CF_LOCAL_PORT:-8080}}"

            echo -e "${BLUE}==================================================${PLAIN}"
            echo -e "${GREEN}     开启 / 更新 Cloudflare Tunnel 附加隧道       ${PLAIN}"
            echo -e "${BLUE}==================================================${PLAIN}"
            prompt_tunnel_fields 1 "$default_port" "$port_xc" "$port_h3" || return 1

            [ ! -x "$CF_BIN" ] && { install_cloudflared_local || return 1; }

            xt_path="${cur_path:-/${uuid}-xt}"
            tmp_dir=$(mktemp -d)
            tmp_cfg="${tmp_dir}/config.json"
            jq --arg uuid "$uuid" --arg path "$xt_path" --argjson port "$_INPUT_CF_PORT" '
                .inbounds = ((.inbounds // []) |
                    if any(.tag == "xhttp-tunnel-in") then
                        map(if .tag == "xhttp-tunnel-in" then
                            .listen = "127.0.0.1" |
                            .port = $port |
                            .streamSettings.security = "none" |
                            .streamSettings.xhttpSettings.path = $path
                        else . end)
                    else
                        . + [{
                            "tag": "xhttp-tunnel-in",
                            "listen": "127.0.0.1",
                            "port": $port,
                            "protocol": "vless",
                            "settings": {
                                "clients": [{"id": $uuid, "flow": ""}],
                                "decryption": "none"
                            },
                            "streamSettings": {
                                "network": "xhttp",
                                "security": "none",
                                "sockopt": {"trustedXForwardedFor": ["CF-Connecting-IP"]},
                                "xhttpSettings": {"mode": "auto", "path": $path}
                            },
                            "sniffing": {
                                "enabled": true,
                                "destOverride": ["http", "tls", "quic"],
                                "metadataOnly": false
                            }
                        }]
                    end)
            ' "$CONFIG" > "$tmp_cfg"

            if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
                rm -rf "$tmp_dir"
                echo -e "${RED}❌ 新配置语法测试失败，已取消更改！${PLAIN}"
                return 1
            fi
            chmod 644 "$tmp_cfg"
            mv -f "$tmp_cfg" "$CONFIG"
            rm -rf "$tmp_dir"

            save_tunnel_meta_and_env "$_INPUT_CF_TOKEN" "$_INPUT_CF_DOMAIN" "$_INPUT_CF_PORT" "0" "1" "${WARP_ENABLED:-1}"
            if is_systemd; then
                write_cloudflared_unit_local
                systemctl daemon-reload
                systemctl enable cloudflared 2>/dev/null || true
            fi
            restart_xray
            echo -e "${GREEN}✅ 标准 VPS 的 Cloudflare Tunnel 附加隧道已开启/更新！${PLAIN}"
            show_info
            ;;
        disable|off|remove)
            if [ "$CF_TUNNEL_ENABLED" != "1" ] && [ "$has_xt" != "1" ] && [ ! -f "$TUNNEL_ENV" ]; then
                echo -e "${YELLOW}💡 当前标准 VPS 未开启 Cloudflare Tunnel 附加隧道，无需关闭。${PLAIN}"
                return 0
            fi
            if [ "$flag" != "--yes" ]; then
                local confirm=""
                read_tty -p "⚠️ 确认关闭并移除标准 VPS 的 Cloudflare Tunnel 附加隧道吗？(y/n): " confirm || return 0
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    echo -e "${YELLOW}已取消操作。${PLAIN}"
                    return 0
                fi
            fi

            if is_systemd; then
                systemctl stop cloudflared 2>/dev/null || true
                systemctl disable cloudflared 2>/dev/null || true
                rm -f /etc/systemd/system/cloudflared.service
                systemctl daemon-reload
            else
                stop_proc_graceful cloudflared
            fi

            if command -v jq >/dev/null 2>&1; then
                local tmp_dir tmp_cfg
                tmp_dir=$(mktemp -d)
                tmp_cfg="${tmp_dir}/config.json"
                jq '.inbounds = ((.inbounds // []) | map(select(.tag != "xhttp-tunnel-in")))' "$CONFIG" > "$tmp_cfg"
                if XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
                    chmod 644 "$tmp_cfg"
                    mv -f "$tmp_cfg" "$CONFIG"
                else
                    echo -e "${RED}❌ 移除隧道入站后配置校验失败，已保留原配置！${PLAIN}"
                    rm -rf "$tmp_dir"
                    return 1
                fi
                rm -rf "$tmp_dir"
            fi

            rm -f "$TUNNEL_CONF" "$TUNNEL_ENV" /var/log/cloudflared.log
            restart_xray
            echo -e "${GREEN}✅ 已关闭并移除 Cloudflare Tunnel 附加隧道，恢复纯标准原生 VPS 模式！${PLAIN}"
            show_info
            ;;
        *)
            echo "用法: xm tunnel [enable|status|disable]"
            return 1
            ;;
    esac
}

upgrade_core() {
    echo -e "${CYAN}>>> 正在检查官方最新 Xray 内核版本...${PLAIN}"
    local arch file cur_ver latest_tag
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) file="Xray-linux-64.zip" ;;
        aarch64|arm64) file="Xray-linux-arm64-v8a.zip" ;;
        *) echo -e "${RED}不支持的 CPU 架构: $arch${PLAIN}"; return 1 ;;
    esac

    cur_ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo "")
    latest_tag=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4 || echo "")
    if [ -n "$cur_ver" ] && [ -n "$latest_tag" ] && [ "v${cur_ver#v}" = "v${latest_tag#v}" ]; then
        echo -e "${GREEN}✅ 当前已是最新版 Xray (${cur_ver})，无需重复升级！${PLAIN}"
        return 0
    fi

    local tmp_dir zip_file dgst_file expected actual
    tmp_dir=$(mktemp -d)
    zip_file="${tmp_dir}/${file}"
    dgst_file="${zip_file}.dgst"
    local base_url="https://github.com/XTLS/Xray-core/releases/latest/download"

    if ! curl -fsSL --connect-timeout 15 --retry 3 "${base_url}/${file}" -o "$zip_file"; then
        rm -rf "$tmp_dir"
        echo -e "${RED}❌ 下载 Xray 内核失败！${PLAIN}"
        return 1
    fi
    if curl -fsSL --connect-timeout 10 "${base_url}/${file}.dgst" -o "$dgst_file" 2>/dev/null; then
        expected=$(awk -F'= *' '/^SHA2-256=/{print tolower($2)}' "$dgst_file" | tr -d ' \r\n')
        actual=$(compute_sha256 "$zip_file")
        if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
            rm -rf "$tmp_dir"
            echo -e "${RED}❌ Xray 安装包 SHA256 校验失败，已放弃升级！${PLAIN}"
            return 1
        fi
    fi

    if ! unzip -qo "$zip_file" xray -d "$tmp_dir"; then
        rm -rf "$tmp_dir"
        echo -e "${RED}❌ 解压 Xray 安装包失败！${PLAIN}"
        return 1
    fi

    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"
    restart_xray
    echo -e "${GREEN}✅ Xray 内核升级完成！当前版本：${PLAIN}"
    "$XRAY_BIN" version | head -n1
}

upgrade_geo() {
    echo -e "${CYAN}>>> 正在安全检查并升级 geosite.dat 与 geoip.dat 规则库...${PLAIN}"
    echo -e "  规则来源 : ${CYAN}${GEO_REPO_URL}${PLAIN}"
    mkdir -p "$XRAY_ASSET_DIR"
    local file tmp_dir tmp_file sum_file expected cur_sha actual size
    local updated=0
    for file in geosite.dat geoip.dat; do
        tmp_dir=$(mktemp -d)
        tmp_file="${tmp_dir}/${file}"
        sum_file="${tmp_dir}/${file}.sha256sum"
        expected=""
        local gh_url="${GEO_REPO_URL}/releases/latest/download/${file}"
        local cdn_url="https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/${file}"

        if curl -fsSL --connect-timeout 10 "${gh_url}.sha256sum" -o "$sum_file" 2>/dev/null || \
           curl -fsSL --connect-timeout 10 "${cdn_url}.sha256sum" -o "$sum_file" 2>/dev/null; then
            expected=$(awk '{print tolower($1)}' "$sum_file" | tr -d ' \r\n')
        fi

        if [ -s "${XRAY_ASSET_DIR}/${file}" ] && [ -n "$expected" ]; then
            cur_sha=$(compute_sha256 "${XRAY_ASSET_DIR}/${file}")
            if [ -n "$cur_sha" ] && [ "$cur_sha" = "$expected" ]; then
                rm -rf "$tmp_dir"
                echo -e "${GREEN}✅ ${file} 已是最新版本 (SHA256 一致)，跳过下载。${PLAIN}"
                continue
            fi
        fi

        if ! curl -fsSL --connect-timeout 15 --retry 3 "$gh_url" -o "$tmp_file" && \
           ! curl -fsSL --connect-timeout 15 --retry 3 "$cdn_url" -o "$tmp_file"; then
            rm -rf "$tmp_dir"
            echo -e "${RED}❌ 下载 ${file} 失败，已保留原有规则库！${PLAIN}"
            return 1
        fi

        if [ -n "$expected" ]; then
            actual=$(compute_sha256 "$tmp_file")
            if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
                rm -rf "$tmp_dir"
                echo -e "${RED}❌ ${file} SHA256 校验失败，已放弃覆盖！${PLAIN}"
                return 1
            fi
        else
            size=$(wc -c < "$tmp_file" 2>/dev/null || echo 0)
            if [ "$size" -lt 500000 ]; then
                rm -rf "$tmp_dir"
                echo -e "${RED}❌ ${file} 文件过小 (${size} bytes)，已放弃覆盖！${PLAIN}"
                return 1
            fi
        fi

        mv -f "$tmp_file" "${XRAY_ASSET_DIR}/${file}"
        chmod 644 "${XRAY_ASSET_DIR}/${file}"
        rm -f "/usr/local/bin/${file}" "/etc/xray/${file}"
        rm -rf "$tmp_dir"
        updated=1
    done

    if [ "$updated" -eq 1 ]; then
        [ -f "$CONFIG" ] && restart_xray
        echo -e "${GREEN}✅ 规则库更新成功！geosite: $(ls -lh "${XRAY_ASSET_DIR}/geosite.dat" 2>/dev/null | awk '{print $5}') | geoip: $(ls -lh "${XRAY_ASSET_DIR}/geoip.dat" 2>/dev/null | awk '{print $5}')${PLAIN}"
    else
        echo -e "${GREEN}✅ geosite.dat 与 geoip.dat 均已是最新版本，无需重启 Xray！${PLAIN}"
    fi
}

geo_cron_status_str() {
    if is_systemd; then
        if [ -f "$GEO_TIMER" ] && systemctl is-enabled --quiet xray-geo-update.timer 2>/dev/null; then
            local cal
            cal=$(grep -E '^OnCalendar=' "$GEO_TIMER" 2>/dev/null | head -n1 | cut -d'=' -f2-)
            echo "已开启 (Systemd Timer: ${cal:-默认})"
            return 0
        fi
    else
        if command -v crontab >/dev/null 2>&1; then
            local line
            line=$(crontab -l 2>/dev/null | grep -F "$GEO_CRON_TAG" | head -n1 || true)
            if [ -n "$line" ]; then
                local sched
                sched=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
                echo "已开启 (Cron: ${sched})"
                return 0
            fi
        fi
    fi
    echo "未开启"
}

convert_cron_to_oncalendar() {
    local expr="$1" m h dom mon dow mm hh day
    read -r m h dom mon dow <<< "$expr"
    [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ] || return 1
    [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ] || return 1
    [ "$mon" = "*" ] || return 1
    mm=$(printf '%02d' "$((10#$m))")
    hh=$(printf '%02d' "$((10#$h))")
    if [ "$dom" = "*" ] && [ "$dow" = "*" ]; then
        echo "*-*-* ${hh}:${mm}:00"
        return 0
    elif [[ "$dom" =~ ^\*/([0-9]+)$ ]] && [ "$dow" = "*" ]; then
        echo "*-*-1/${BASH_REMATCH[1]} ${hh}:${mm}:00"
        return 0
    elif [ "$dom" = "*" ] && [[ "$dow" =~ ^[0-7]$ ]]; then
        case "$dow" in
            0|7) day="Sun" ;; 1) day="Mon" ;; 2) day="Tue" ;; 3) day="Wed" ;;
            4) day="Thu" ;; 5) day="Fri" ;; 6) day="Sat" ;;
        esac
        echo "${day} *-*-* ${hh}:${mm}:00"
        return 0
    fi
    return 1
}

apply_geo_schedule() {
    local on_cal="$1"
    local cron_expr="$2"
    local desc="${3:-$on_cal}"

    if is_systemd; then
        if command -v systemd-analyze >/dev/null 2>&1; then
            if ! systemd-analyze calendar "$on_cal" >/dev/null 2>&1; then
                echo -e "${RED}❌ 无效的 Systemd OnCalendar 时间表达式: ${on_cal}${PLAIN}"
                echo -e "${YELLOW}💡 示例: '*-*-* 04:00:00' (每天04:00) 或 'Mon *-*-* 04:00:00' (每周一04:00)${PLAIN}"
                return 1
            fi
        fi
        cat > "$GEO_SERVICE" << SERVICE
[Unit]
Description=Xray Geosite & GeoIP Auto-Update (Loyalsoldier/v2ray-rules-dat)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xm update-geo
SERVICE
        cat > "$GEO_TIMER" << TIMER
[Unit]
Description=Scheduled Xray Geosite & GeoIP Auto-Update Timer

[Timer]
OnCalendar=${on_cal}
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
TIMER
        systemctl daemon-reload
        systemctl enable --now xray-geo-update.timer
        echo -e "${GREEN}✅ 已开启规则库定时自动更新: ${desc} (OnCalendar: ${on_cal})${PLAIN}"
        systemctl list-timers xray-geo-update.timer --no-pager 2>/dev/null || true
    else
        if [ -z "$cron_expr" ]; then
            echo -e "${RED}❌ 容器环境仅支持标准 5 段 Cron 表达式 (如 '0 4 * * *' 或 '0 4 * * 1')！${PLAIN}"
            return 1
        fi
        if ! command -v crontab >/dev/null 2>&1; then
            echo -e "${CYAN}>>> 正在安装 cron 以支持容器内定时更新...${PLAIN}"
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cron >/dev/null 2>&1 || true
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache dcron >/dev/null 2>&1 || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y cronie >/dev/null 2>&1 || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y cronie >/dev/null 2>&1 || true
            fi
        fi
        if ! command -v crontab >/dev/null 2>&1; then
            echo -e "${RED}❌ 当前环境缺少 crontab，无法配置定时任务！${PLAIN}"
            return 1
        fi
        local existing
        existing=$(crontab -l 2>/dev/null | grep -vF "$GEO_CRON_TAG" || true)
        {
            [ -n "$existing" ] && printf '%s\n' "$existing"
            echo "${cron_expr} /usr/local/bin/xm update-geo >> ${GEO_LOG} 2>&1 ${GEO_CRON_TAG}"
        } | crontab -
        pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || cron >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ 已设置规则库 Crontab 定时更新: ${desc} (${cron_expr})${PLAIN}"
        echo -e "  💡 请注意无 Systemd 容器内需确保 cron/crond 后台运行。"
    fi
}

disable_geo_schedule() {
    local quiet="${1:-0}"
    if is_systemd; then
        systemctl stop xray-geo-update.timer 2>/dev/null || true
        systemctl disable xray-geo-update.timer 2>/dev/null || true
        if [ -f "$GEO_TIMER" ] || [ -f "$GEO_SERVICE" ]; then
            rm -f "$GEO_TIMER" "$GEO_SERVICE"
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi
    if command -v crontab >/dev/null 2>&1; then
        local existing
        existing=$(crontab -l 2>/dev/null || true)
        if echo "$existing" | grep -qF "$GEO_CRON_TAG"; then
            local filtered
            filtered=$(echo "$existing" | grep -vF "$GEO_CRON_TAG" || true)
            if [ -n "$filtered" ]; then
                printf '%s\n' "$filtered" | crontab -
            else
                crontab -r 2>/dev/null || true
            fi
        fi
    fi
    [ "$quiet" != "1" ] && echo -e "${YELLOW}⏸️ 已关闭 geosite/geoip 规则库定时自动更新！${PLAIN}"
    return 0
}

geo_status_view() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}        geosite / geoip 规则库状态信息            ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "  规则来源     : ${CYAN}${GEO_REPO_URL}${PLAIN}"
    echo -e "  定时更新状态 : ${CYAN}$(geo_cron_status_str)${PLAIN}"
    local f
    for f in geosite.dat geoip.dat; do
        if [ -f "${XRAY_ASSET_DIR}/${f}" ]; then
            local sz dt sha
            sz=$(ls -lh "${XRAY_ASSET_DIR}/${f}" | awk '{print $5}')
            dt=$(date -r "${XRAY_ASSET_DIR}/${f}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c '%y' "${XRAY_ASSET_DIR}/${f}" 2>/dev/null | cut -d'.' -f1)
            sha=$(compute_sha256 "${XRAY_ASSET_DIR}/${f}" | cut -c1-12)
            echo -e "  ${f}  : ${GREEN}${sz}${PLAIN} (更新于 ${dt}, sha256:${sha}...)"
        else
            echo -e "  ${f}  : ${RED}未安装${PLAIN}"
        fi
    done
    if is_systemd && [ -f "$GEO_TIMER" ]; then
        echo -e "\n${CYAN}>>> Systemd 定时器详情:${PLAIN}"
        systemctl list-timers xray-geo-update.timer --no-pager 2>/dev/null || true
        echo -e "\n${CYAN}>>> 最近一次自动更新日志:${PLAIN}"
        journalctl -u xray-geo-update -n 10 --no-pager 2>/dev/null || true
    elif [ -f "$GEO_LOG" ]; then
        echo -e "\n${CYAN}>>> 最近自动更新日志 (${GEO_LOG}):${PLAIN}"
        tail -n 10 "$GEO_LOG" 2>/dev/null || true
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
}

set_geo_schedule_cli() {
    local mode="${1:-}"
    local arg2="${2:-}"
    local arg3="${3:-}"

    if [ -z "$mode" ]; then
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}      设置 geosite/geoip 规则库定时自动更新       ${PLAIN}"
        echo -e "      当前状态: ${CYAN}$(geo_cron_status_str)${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 每天自动更新 (默认 04:00)"
        echo -e " ${GREEN}2.${PLAIN} 每周自动更新 (默认每周一 04:00) [推荐]"
        echo -e " ${GREEN}3.${PLAIN} 每 N 天自动更新 (自定义天数 1-30 与小时)"
        echo -e " ${GREEN}4.${PLAIN} 自定义 Cron / OnCalendar 表达式"
        echo -e " ${RED}5.${PLAIN} 关闭定时自动更新"
        echo -e " ${YELLOW}0.${PLAIN} 返回"
        echo -e "${BLUE}==================================================${PLAIN}"
        local c h d expr
        read_tty -p "请输入选项 [0-5]: " c || return 1
        case "$c" in
            1)
                read_tty -p "请输入每日执行小时 [0-23, 默认 4]: " h || return 1
                set_geo_schedule_cli daily "${h:-4}"
                ;;
            2)
                read_tty -p "请输入每周一执行小时 [0-23, 默认 4]: " h || return 1
                set_geo_schedule_cli weekly "${h:-4}"
                ;;
            3)
                read_tty -p "请输入更新间隔天数 [1-30, 默认 3]: " d || return 1
                read_tty -p "请输入执行小时 [0-23, 默认 4]: " h || return 1
                set_geo_schedule_cli days "${d:-3}" "${h:-4}"
                ;;
            4)
                echo -e "${YELLOW}示例: 5段Cron '0 4 * * *' / '30 3 * * 1'，或 Systemd OnCalendar '*-*-* 04:00:00'${PLAIN}"
                read_tty -p "请输入表达式: " expr || return 1
                set_geo_schedule_cli custom "$expr"
                ;;
            5) disable_geo_schedule ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效！${PLAIN}"; return 1 ;;
        esac
        return $?
    fi

    local hh
    case "$mode" in
        status)
            geo_status_view
            ;;
        off|disable|stop)
            disable_geo_schedule
            ;;
        daily)
            local hour="${arg2:-4}"
            if [[ ! "$hour" =~ ^[0-9]+$ ]] || [ "$hour" -lt 0 ] || [ "$hour" -gt 23 ]; then
                echo -e "${RED}❌ 小时必须是 0-23 之间的整数！${PLAIN}"; return 1
            fi
            hh=$(printf '%02d' "$((10#$hour))")
            apply_geo_schedule "*-*-* ${hh}:00:00" "0 ${hour} * * *" "每天 ${hh}:00"
            ;;
        weekly)
            local hour="${arg2:-4}"
            if [[ ! "$hour" =~ ^[0-9]+$ ]] || [ "$hour" -lt 0 ] || [ "$hour" -gt 23 ]; then
                echo -e "${RED}❌ 小时必须是 0-23 之间的整数！${PLAIN}"; return 1
            fi
            hh=$(printf '%02d' "$((10#$hour))")
            apply_geo_schedule "Mon *-*-* ${hh}:00:00" "0 ${hour} * * 1" "每周一 ${hh}:00"
            ;;
        days)
            local days="${arg2:-3}"
            local hour="${arg3:-4}"
            if [[ ! "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ] || [ "$days" -gt 30 ]; then
                echo -e "${RED}❌ 天数必须是 1-30 之间的整数！${PLAIN}"; return 1
            fi
            if [[ ! "$hour" =~ ^[0-9]+$ ]] || [ "$hour" -lt 0 ] || [ "$hour" -gt 23 ]; then
                echo -e "${RED}❌ 小时必须是 0-23 之间的整数！${PLAIN}"; return 1
            fi
            hh=$(printf '%02d' "$((10#$hour))")
            if [ "$days" -eq 1 ]; then
                apply_geo_schedule "*-*-* ${hh}:00:00" "0 ${hour} * * *" "每天 ${hh}:00"
            else
                apply_geo_schedule "*-*-1/${days} ${hh}:00:00" "0 ${hour} */${days} * *" "每 ${days} 天 ${hh}:00"
            fi
            ;;
        custom)
            local expr="${arg2:-}"
            [ -z "$expr" ] && { echo -e "${RED}❌ 表达式不能为空！${PLAIN}"; return 1; }
            local nf
            nf=$(echo "$expr" | awk '{print NF}')
            if [ "$nf" -eq 5 ] && [[ "$expr" =~ ^[0-9*/,-]+[[:space:]] ]]; then
                if is_systemd; then
                    local converted
                    if converted=$(convert_cron_to_oncalendar "$expr"); then
                        apply_geo_schedule "$converted" "$expr" "自定义 (${expr})"
                    else
                        echo -e "${RED}❌ Systemd 仅支持简单 5 段 Cron 自动转换，复杂周期请直接传 OnCalendar 表达式 (如 'Mon,Thu *-*-* 04:30:00')！${PLAIN}"
                        return 1
                    fi
                else
                    apply_geo_schedule "" "$expr" "自定义 (${expr})"
                fi
            else
                if is_systemd; then
                    apply_geo_schedule "$expr" "" "自定义 (${expr})"
                else
                    echo -e "${RED}❌ 容器环境不支持 Systemd OnCalendar 格式，请输入 5 段 Cron (如 '0 4 * * *')！${PLAIN}"
                    return 1
                fi
            fi
            ;;
        *)
            echo "用法: xm geo-cron [daily [小时]|weekly [小时]|days <1-30> [小时]|custom <表达式>|status|off]"
            return 1
            ;;
    esac
}

manage_geo() {
    local sub="${1:-}"
    if [ -z "$sub" ]; then
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}      geosite / geoip 规则库更新与定时管理        ${PLAIN}"
        echo -e "      规则来源: ${CYAN}${GEO_REPO_URL}${PLAIN}"
        echo -e "      定时状态: ${CYAN}$(geo_cron_status_str)${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 立即检查并更新规则库 (update-geo)"
        echo -e " ${GREEN}2.${PLAIN} 设置 / 修改定时自动更新 (geo-cron)"
        echo -e " ${GREEN}3.${PLAIN} 查看规则库版本与定时器日志 (status)"
        echo -e " ${RED}4.${PLAIN} 关闭定时自动更新 (off)"
        echo -e " ${YELLOW}0.${PLAIN} 返回"
        echo -e "${BLUE}==================================================${PLAIN}"
        local c
        read_tty -p "请输入选项 [0-4]: " c || return 1
        case "$c" in
            1) upgrade_geo ;;
            2) set_geo_schedule_cli ;;
            3) geo_status_view ;;
            4) disable_geo_schedule ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效！${PLAIN}"; return 1 ;;
        esac
        return $?
    fi
    case "$sub" in
        update|now) upgrade_geo ;;
        cron|schedule|timer) set_geo_schedule_cli "${2:-}" "${3:-}" "${4:-}" ;;
        status) geo_status_view ;;
        off|disable) disable_geo_schedule ;;
        *) echo "用法: xm geo [update|cron|status|off]"; return 1 ;;
    esac
}

test_config() {
    echo -e "${CYAN}>>> 正在测试配置文件语法合法性...${PLAIN}"
    XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$CONFIG"
}

enable_bbr() {
    echo -e "${CYAN}>>> 正在检查并开启系统 TCP BBR 加速...${PLAIN}"
    local current_cc new_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$current_cc" = "bbr" ]; then
        echo -e "${GREEN}✅ 系统已启用 BBR 加速！当前算法：${current_cc}${PLAIN}"
        return 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'BBRCONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBRCONF

    if [ -f /etc/sysctl.conf ]; then
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    fi
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true

    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$new_cc" = "bbr" ]; then
        echo -e "${GREEN}🎉 成功开启 TCP BBR 加速！当前算法：${new_cc}${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ 已写入配置，如容器受宿主机限制，BBR 需宿主机开启。${PLAIN}"
    fi
}

cleanup_autostart_hooks() {
    local rc tmp_rc
    for rc in /root/.bashrc /etc/profile; do
        [ -f "$rc" ] || continue
        tmp_rc=$(mktemp)
        awk '
            /# BEGIN \[xray-xhttp-warp\]/ { in_new=1; next }
            /# END \[xray-xhttp-warp\]/ { in_new=0; next }
            /# \[xray-xhttp-warp\] Container Autostart Hook/ { in_old=1; next }
            in_new { next }
            in_old {
                if ($0 ~ /^fi[[:space:]]*$/) { in_old=0 }
                next
            }
            { print }
        ' "$rc" > "$tmp_rc" && cat "$tmp_rc" > "$rc"
        rm -f "$tmp_rc"
    done
}

uninstall_xray() {
    local auto_yes=0 purge_cert=0 _arg confirm=""
    for _arg in "$@"; do
        case "$_arg" in
            --yes|-y) auto_yes=1 ;;
            --purge-cert) purge_cert=1 ;;
        esac
    done

    if [ "$auto_yes" -ne 1 ]; then
        read_tty -p "⚠️ 确认要彻底卸载 Xray 及隧道服务与配置吗？(y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}已取消卸载。${PLAIN}"
            return 0
        fi
    fi

    stop_xray
    disable_geo_schedule 1
    pkill -x xray 2>/dev/null || true
    pkill -x cloudflared 2>/dev/null || true
    if is_systemd; then
        systemctl disable xray 2>/dev/null || true
        systemctl disable cloudflared 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
    fi
    cleanup_autostart_hooks
    if [ -d /etc/xray ]; then
        find /etc/xray -mindepth 1 -maxdepth 1 ! -name cert -exec rm -rf {} + 2>/dev/null || true
        rmdir /etc/xray 2>/dev/null || true
    fi
    rm -rf /usr/local/share/xray
    rm -f /usr/local/bin/xray /usr/local/bin/cloudflared \
          /usr/local/bin/xm /usr/bin/xm /usr/local/bin/xinfo \
          /var/log/xray.log /var/log/cloudflared.log "$GEO_LOG"
    [ -L /usr/local/bin/warp ] && [ ! -e /usr/local/bin/warp ] && rm -f /usr/local/bin/warp
    [ -L /usr/bin/warp ] && [ ! -e /usr/bin/warp ] && rm -f /usr/bin/warp

    if [ -d /etc/xray/cert ] || [ -x /root/.acme.sh/acme.sh ] || [ -d /root/.acme.sh ]; then
        if [ "$auto_yes" -ne 1 ]; then
            local rm_cert=""
            read_tty -p "检测到 SSL 证书 (/etc/xray/cert) 或 acme.sh，是否一并卸载清理？[y/N] (默认回车保留，防重装限频): " rm_cert || rm_cert="n"
            [[ "$rm_cert" == "y" || "$rm_cert" == "Y" ]] && purge_cert=1
        fi
        if [ "$purge_cert" -eq 1 ]; then
            rm -rf /etc/xray/cert
            rmdir /etc/xray 2>/dev/null || true
            [ -x /root/.acme.sh/acme.sh ] && /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
            rm -rf /root/.acme.sh
            echo -e "${YELLOW}🗑️ 已一并卸载清理 SSL 证书与 acme.sh。${PLAIN}"
        elif [ "$auto_yes" -ne 1 ]; then
            echo -e "${CYAN}ℹ️ 已保留 SSL 证书 (/etc/xray/cert) 与 acme.sh 续期配置（下次安装可直接复用）。${PLAIN}"
        fi
    fi

    echo -e "${GREEN}✅ 服务及管理组件已彻底清理卸载干净！${PLAIN}"
    [ "$auto_yes" -eq 1 ] || exit 0
}

warp_print_help() {
    echo "=================================================="
    echo "       Cloudflare WARP 管理 (已集成至 xm warp)    "
    echo "=================================================="
    echo "xm warp               打开交互式 WARP 管理菜单"
    echo "xm warp status        查看当前连接状态 (兼容 warp status)"
    echo "xm warp test [端口]   测试 IPv4 & IPv6 出口 (兼容 warp test)"
    echo "xm warp info          查看注册信息与设备 ID"
    echo "xm warp start         启动连接 (connect)"
    echo "xm warp stop          断开连接 (disconnect)"
    echo "xm warp restart       重启连接"
    echo "xm warp port 40000    修改 SOCKS5 端口并同步 Xray 配置"
    echo "xm warp register      注册 WARP 客户端"
    echo "xm warp unregister    注销当前注册设备"
    echo "xm warp autostart on|off  开关开机自动连接服务"
    echo "xm warp logs [行数]   查看 warp-svc 后台日志"
    echo "xm warp update        无 GUI 精简升级官方 cloudflare-warp"
    echo "=================================================="
}

warp_detect_socks_port() {
    local custom="${1:-}" cli="${2:-}"
    if [ -n "$custom" ]; then
        echo "$custom"
        return 0
    fi
    local port=""
    if [ -n "$cli" ]; then
        port=$("$cli" --accept-tos settings 2>/dev/null | grep -iE 'proxy port|local proxy port' | grep -oE '[0-9]+' | tail -n1 || true)
    fi
    if [ -z "$port" ] && [ -f "$CONFIG" ]; then
        port=$(grep -A6 '"socks-warp"' "$CONFIG" 2>/dev/null | grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)
    fi
    echo "${port:-40000}"
}

warp_sync_xray_socks_port() {
    local new_port="$1"
    [ -f "$CONFIG" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -e '.outbounds[]? | select(.tag == "socks-warp")' "$CONFIG" >/dev/null 2>&1 || return 0

    local tmp_dir tmp_cfg
    tmp_dir=$(mktemp -d)
    tmp_cfg="${tmp_dir}/config.json"
    jq --argjson p "$new_port" '
        .outbounds |= map(if .tag == "socks-warp" and (.settings.servers | length) > 0 then .settings.servers[0].port = $p else . end)
    ' "$CONFIG" > "$tmp_cfg"
    if XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
        chmod 644 "$tmp_cfg"
        mv -f "$tmp_cfg" "$CONFIG"
        rm -rf "$tmp_dir"
        restart_xray
        echo -e "${GREEN}✅ 已同步更新 Xray socks-warp 出站端口为 ${new_port} 并重载服务。${PLAIN}"
    else
        rm -rf "$tmp_dir"
        echo -e "${YELLOW}⚠️ 同步更新 $CONFIG 失败，请手动检查端口配置。${PLAIN}"
    fi
}

warp_upgrade_pkg() {
    local cli="$1"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}❌ 当前系统不支持 apt-get 更新！${PLAIN}"
        return 1
    fi
    local repo_url="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
    local script_dir tmp_common="" rc=0
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "${script_dir}/common.sh" ]; then
        . "${script_dir}/common.sh"
    elif [ -f "${script_dir}/scripts/common.sh" ]; then
        . "${script_dir}/scripts/common.sh"
    else
        tmp_common=$(mktemp /tmp/xm-warp-common.XXXXXX.sh)
        if ! curl -fsSL --connect-timeout 15 --retry 3 "${repo_url}/scripts/common.sh" -o "$tmp_common"; then
            rm -f "$tmp_common"
            echo -e "${RED}❌ 下载公共函数库 scripts/common.sh 失败！${PLAIN}"
            return 1
        fi
        . "$tmp_common"
    fi
    setup_cloudflare_warp_repo && install_cloudflare_warp_headless || rc=$?
    [ -n "$tmp_common" ] && rm -f "$tmp_common"
    [ "$rc" -eq 0 ] || return "$rc"

    systemctl restart warp-svc 2>/dev/null || true
    for _i in $(seq 1 15); do
        "$cli" --accept-tos status >/dev/null 2>&1 && break
        sleep 1
    done
    "$cli" --accept-tos connect 2>/dev/null || true
}

warp_show_container_wireguard() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}    WARP 内置 WireGuard 出站状态 (容器/穿透模式)  ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "  运行方式 : ${CYAN}Xray 内置 WireGuard (ForceIPv6)${PLAIN} — 未依赖 warp-svc"
    if [ -f /etc/xray/warp-tunnel.json ] && command -v jq >/dev/null 2>&1; then
        echo -e "  WARP IPv6: ${CYAN}$(jq -r '.v6 // "未知"' /etc/xray/warp-tunnel.json 2>/dev/null)${PLAIN}"
        echo -e "  Endpoint : ${CYAN}$(jq -r '.endpoint_v4 // .endpoint_v6 // "未知"' /etc/xray/warp-tunnel.json 2>/dev/null)${PLAIN}"
    elif [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
        echo -e "  Endpoint : ${CYAN}$(jq -r '.outbounds[]? | select(.tag=="warp-ipv6-out") | .settings.peers[0].endpoint // "未知"' "$CONFIG" 2>/dev/null)${PLAIN}"
    fi
    echo -e "  分流规则 : ${GREEN}geosite:openai, geosite:google-deepmind -> warp-ipv6-out${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
}

warp_menu() {
    local cli="$1"
    while true; do
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}        Cloudflare 官方 WARP SOCKS5 管理          ${PLAIN}"
        echo -e "        当前状态: ${CYAN}$("$cli" --accept-tos status 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' || echo '未知')${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 查看连接状态 (status)"
        echo -e " ${GREEN}2.${PLAIN} 测试 IPv4 & IPv6 双栈出口 (test)"
        echo -e " ${GREEN}3.${PLAIN} 启动 / 连接 WARP (start)"
        echo -e " ${GREEN}4.${PLAIN} 断开 WARP 连接 (stop)"
        echo -e " ${GREEN}5.${PLAIN} 重启 WARP 连接 (restart)"
        echo -e " ${GREEN}6.${PLAIN} 查看注册信息与设备 ID (info)"
        echo -e " ${GREEN}7.${PLAIN} 修改 SOCKS5 监听端口并同步 Xray (port)"
        echo -e " ${GREEN}8.${PLAIN} 开关开机自动连接服务 (autostart)"
        echo -e " ${GREEN}9.${PLAIN} 查看 warp-svc 实时/最近日志 (logs)"
        echo -e " ${GREEN}10.${PLAIN} 无 GUI 精简升级官方 cloudflare-warp (update)"
        echo -e " ${YELLOW}11.${PLAIN} 重新注册 WARP 客户端 (register)"
        echo -e " ${YELLOW}0.${PLAIN} 返回"
        echo -e "${BLUE}==================================================${PLAIN}"
        local wc
        read_tty -p "请输入选项 [0-11]: " wc || return 0
        case "$wc" in
            1) manage_warp status ;;
            2) manage_warp test ;;
            3) manage_warp start ;;
            4) manage_warp stop ;;
            5) manage_warp restart ;;
            6) manage_warp info ;;
            7)
                local np
                read_tty -p "请输入新 SOCKS5 监听端口 [1-65535，默认 40000]: " np || continue
                [ -z "$np" ] && np="40000"
                manage_warp port "$np"
                ;;
            8)
                local as
                read_tty -p "开启还是关闭开机自启？(on/off): " as || continue
                manage_warp autostart "$as"
                ;;
            9) manage_warp logs 50 ;;
            10) manage_warp update ;;
            11) manage_warp register ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效！${PLAIN}" ;;
        esac
        echo ""
        read_tty -p "按回车键继续..." _wpause || break
    done
}

manage_warp() {
    local sub="${1:-}"
    local cli
    cli=$(command -v warp-cli || true)

    if [ -z "$cli" ]; then
        load_tunnel_meta
        if [ "$TUNNEL_MODE" = "1" ] || [ -f /etc/xray/warp-tunnel.json ]; then
            warp_show_container_wireguard
            return 0
        fi
        echo -e "${RED}❌ 未检测到 warp-cli 客户端，请先安装 WARP (bash install.sh warp)！${PLAIN}"
        return 1
    fi

    if [ -z "$sub" ]; then
        warp_menu "$cli"
        return $?
    fi

    case "$sub" in
        help|-h|--help) warp_print_help ;;
        register)
            local cur_port
            cur_port=$(warp_detect_socks_port "" "$cli")
            if "$cli" --accept-tos registration show >/dev/null 2>&1; then
                echo -e "${CYAN}>>> 检测到已有 WARP 注册信息，正在注销旧设备并重新注册...${PLAIN}"
                "$cli" --accept-tos disconnect >/dev/null 2>&1 || true
                if ! "$cli" --accept-tos registration delete; then
                    echo -e "${RED}❌ 注销旧 WARP 注册信息失败！${PLAIN}"
                    return 1
                fi
            fi
            if ! "$cli" --accept-tos registration new; then
                echo -e "${RED}❌ 注册新 WARP 设备失败！${PLAIN}"
                return 1
            fi
            "$cli" --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true
            "$cli" --accept-tos mode proxy >/dev/null 2>&1 || true
            "$cli" --accept-tos proxy port "$cur_port" >/dev/null 2>&1 || true
            "$cli" --accept-tos connect >/dev/null 2>&1 || true
            for _i in $(seq 1 8); do
                if "$cli" --accept-tos status 2>/dev/null | grep -qi "Connected"; then
                    break
                fi
                sleep 1
            done
            echo -e "${GREEN}✅ WARP 已重新注册并恢复 SOCKS5 代理 (127.0.0.1:${cur_port})！${PLAIN}"
            "$cli" --accept-tos status || true
            ;;
        unregister)
            "$cli" --accept-tos disconnect >/dev/null 2>&1 || true
            "$cli" --accept-tos registration delete
            ;;
        start|connect) "$cli" --accept-tos connect ;;
        stop|disconnect) "$cli" --accept-tos disconnect ;;
        restart)
            "$cli" --accept-tos disconnect || true
            sleep 1
            "$cli" --accept-tos connect
            ;;
        status) "$cli" --accept-tos status ;;
        info) "$cli" --accept-tos registration show ;;
        port)
            local target_port="${2:-}"
            if [ -z "$target_port" ] || [[ ! "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
                echo "用法: xm warp port <1-65535> (例如: xm warp port 40000)"
                return 1
            fi
            "$cli" --accept-tos proxy port "$target_port"
            warp_sync_xray_socks_port "$target_port"
            ;;
        test)
            local port
            port=$(warp_detect_socks_port "${2:-}" "$cli")
            echo -e "${CYAN}>>> 正在通过 SOCKS5 代理 (127.0.0.1:${port}) 测试 Cloudflare 双栈连通性与 WARP 出口...${PLAIN}"
            echo "--- IPv4 检测 ---"
            curl -fsS --connect-timeout 5 --max-time 10 -x "socks5h://127.0.0.1:${port}" https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || echo "IPv4 检测超时或未通"
            echo "--- IPv6 检测 (AI 分流核心通道) ---"
            curl -fsS --connect-timeout 5 --max-time 10 -x "socks5h://127.0.0.1:${port}" "https://[2606:4700:4700::1111]/cdn-cgi/trace" | grep -E '^(ip|loc|warp)=' || echo "IPv6 检测超时或未通"
            ;;
        autostart)
            case "${2:-}" in
                on)
                    systemctl enable --now warp-proxy-autoconnect.service
                    echo -e "${GREEN}✅ WARP 开机自启动已开启！${PLAIN}"
                    ;;
                off)
                    systemctl disable --now warp-proxy-autoconnect.service
                    echo -e "${YELLOW}⏸️ WARP 开机自启动已关闭！${PLAIN}"
                    ;;
                *)
                    echo "用法: xm warp autostart on|off"
                    return 1
                    ;;
            esac
            ;;
        logs)
            if command -v journalctl >/dev/null 2>&1 && is_systemd; then
                journalctl -u warp-svc -n "${2:-100}" --no-pager
            else
                echo -e "${RED}❌ 当前环境未运行 Systemd，无法查看 journalctl 日志。${PLAIN}"
                return 1
            fi
            ;;
        update)
            warp_upgrade_pkg "$cli"
            ;;
        *)
            warp_print_help
            return 1
            ;;
    esac
}

update_xm_script() {
    local from_menu="${1:-0}"
    local repo_url="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
    local tmp_xm
    tmp_xm=$(mktemp /tmp/xm-update.XXXXXX.sh)

    echo -e "${CYAN}>>> 正在从 GitHub 拉取最新版管理脚本 (${repo_url}/scripts/xm_ctl.sh)...${PLAIN}"
    if ! curl -fsSL --connect-timeout 15 --retry 3 "${repo_url}/scripts/xm_ctl.sh" -o "$tmp_xm"; then
        rm -f "$tmp_xm"
        echo -e "${RED}❌ 下载最新版脚本失败，请检查网络连接！${PLAIN}"
        return 1
    fi
    if ! bash -n "$tmp_xm" 2>/dev/null || ! grep -q "Xray 统一综合管理控制台" "$tmp_xm"; then
        rm -f "$tmp_xm"
        echo -e "${RED}❌ 下载的文件校验无效，已放弃覆盖！${PLAIN}"
        return 1
    fi

    chmod 755 "$tmp_xm"
    mkdir -p /usr/local/bin
    mv -f "$tmp_xm" /usr/local/bin/xm
    ln -sf /usr/local/bin/xm /usr/bin/xm 2>/dev/null || true
    ln -sf /usr/local/bin/xm /usr/local/bin/warp 2>/dev/null || true
    ln -sf /usr/local/bin/xm /usr/bin/warp 2>/dev/null || true

    echo -e "${GREEN}✅ xm 管理脚本已更新到最新版！（已同步整合 warp 命令入口，节点与运行配置保持不变）${PLAIN}"
    if [ "$from_menu" = "1" ]; then
        sleep 1
        exec /usr/local/bin/xm
    fi
}

cert_show_status() {
    local active_cert=""
    [ -f "$CONFIG" ] && active_cert=$(get_inbound_field "xhttp-cdn-443-in" "cert")
    [ -z "$active_cert" ] && [ -f "/etc/xray/cert/cert.crt" ] && active_cert="/etc/xray/cert/cert.crt"

    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}              SSL 证书状态检查                    ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    if [ -n "$active_cert" ] && [ -f "$active_cert" ]; then
        echo -e "  当前证书路径 : ${CYAN}${active_cert}${PLAIN}"
        echo -e "  证书主题     : $(openssl x509 -in "$active_cert" -noout -subject 2>/dev/null || echo '未知')"
        echo -e "  SAN 扩展域名 : $(openssl x509 -in "$active_cert" -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ' | sed 's/X509v3 Subject Alternative Name://')"
        echo -e "  过期时间     : ${GREEN}$(openssl x509 -in "$active_cert" -noout -enddate 2>/dev/null | cut -d= -f2)${PLAIN}"
    else
        echo -e "  ${YELLOW}⚠️ 当前未检测到已安装证书。${PLAIN}"
    fi
    if [ -x /root/.acme.sh/acme.sh ]; then
        echo -e "\n${CYAN}>>> acme.sh 托管列表：${PLAIN}"
        /root/.acme.sh/acme.sh --list
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
}

cert_apply_to_config() {
    local new_cert="/etc/xray/cert/cert.crt"
    local new_key="/etc/xray/cert/private.key"
    load_tunnel_meta
    [ "$TUNNEL_MODE" = "1" ] && return 0
    [ -f "$CONFIG" ] && [ -f "$new_cert" ] && [ -f "$new_key" ] || return 0

    local tmp_dir tmp_cfg
    tmp_dir=$(mktemp -d)
    tmp_cfg="${tmp_dir}/config.json"
    if command -v jq >/dev/null 2>&1; then
        jq --arg c "$new_cert" --arg k "$new_key" '
            .inbounds |= map(
                if (.streamSettings.tlsSettings.certificates? | length) > 0 then
                    .streamSettings.tlsSettings.certificates[0].certificateFile = $c |
                    .streamSettings.tlsSettings.certificates[0].keyFile = $k
                else . end
            )
        ' "$CONFIG" > "$tmp_cfg"
        if XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
            chmod 644 "$tmp_cfg"
            mv -f "$tmp_cfg" "$CONFIG"
            rm -rf "$tmp_dir"
            restart_xray
            show_info
            return 0
        fi
    fi
    rm -rf "$tmp_dir"
}

manage_cert() {
    local sub="${1:-}"
    local repo_url="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
    if [ -z "$sub" ]; then
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}           SSL 证书管理 (官方 acme.sh)            ${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 查看当前证书状态与到期时间 (status)"
        echo -e " ${GREEN}2.${PLAIN} 申请 / 更换 SSL 证书并自动应用 (issue)"
        echo -e " ${GREEN}3.${PLAIN} 立即检查/强制续期托管证书 (renew)"
        echo -e " ${YELLOW}0.${PLAIN} 返回"
        echo -e "${BLUE}==================================================${PLAIN}"
        local c
        read_tty -p "请输入选项 [0-3]: " c
        case "$c" in
            1) sub="status" ;;
            2) sub="issue" ;;
            3) sub="renew" ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效！${PLAIN}"; return 1 ;;
        esac
    fi

    case "$sub" in
        status)
            cert_show_status
            ;;
        renew)
            if [ ! -x /root/.acme.sh/acme.sh ]; then
                echo -e "${RED}❌ 未检测到 acme.sh，请先使用 xm cert issue 申请证书！${PLAIN}"
                return 1
            fi
            /root/.acme.sh/acme.sh --cron --force
            is_systemd && systemctl is-active --quiet xray && restart_xray
            ;;
        issue|standalone|dns|ip)
            local tmp_dir
            tmp_dir=$(mktemp -d)
            if ! curl -fsSL --connect-timeout 15 --retry 3 "${repo_url}/scripts/common.sh" -o "${tmp_dir}/common.sh" || \
               ! curl -fsSL --connect-timeout 15 --retry 3 "${repo_url}/scripts/install_cert.sh" -o "${tmp_dir}/install_cert.sh"; then
                rm -rf "$tmp_dir"
                echo -e "${RED}❌ 下载证书申请模块失败！${PLAIN}"
                return 1
            fi
            chmod +x "${tmp_dir}/install_cert.sh"
            bash "${tmp_dir}/install_cert.sh" "$sub"
            local rc=$?
            rm -rf "$tmp_dir"
            [ "$rc" -eq 0 ] && cert_apply_to_config
            return "$rc"
            ;;
        *)
            echo "用法: xm cert [status|issue|renew]"
            return 1
            ;;
    esac
}

open_firewall_port_xm() {
    local proto="$1"
    local port="$2"
    local opened=()

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw allow "${port}/${proto}" >/dev/null 2>&1; then
            opened+=("ufw")
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --add-port="${port}/${proto}" --permanent >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            opened+=("firewalld")
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        if iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT .*-j (REJECT|DROP)'; then
            if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                local line_num
                line_num=$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '$2=="REJECT" || $2=="DROP" {print $1; exit}')
                if [ -n "$line_num" ]; then
                    iptables -I INPUT "$line_num" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
                else
                    iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
                fi
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1 || true
                elif [ -d /etc/iptables ] && command -v iptables-save >/dev/null 2>&1; then
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
            fi
            opened+=("iptables")
        fi
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT .*-j (REJECT|DROP)'; then
            if ! ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                local line6_num
                line6_num=$(ip6tables -L INPUT --line-numbers -n 2>/dev/null | awk '$2=="REJECT" || $2=="DROP" {print $1; exit}')
                if [ -n "$line6_num" ]; then
                    ip6tables -I INPUT "$line6_num" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
                else
                    ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
                fi
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1 || true
                elif [ -d /etc/iptables ] && command -v ip6tables-save >/dev/null 2>&1; then
                    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
                fi
            fi
            opened+=("ip6tables")
        fi
    fi
    if [ "${#opened[@]}" -gt 0 ]; then
        echo -e "${GREEN}✅ 已在本机防火墙 (${opened[*]}) 放行 ${port}/${proto}！${PLAIN}"
    else
        echo -e "${CYAN}ℹ️ 本机未启用拦截型防火墙规则（无需额外放行 ${port}/${proto}）。${PLAIN}"
    fi
}

ssh_find_sshd_bin() {
    local b
    for b in /usr/sbin/sshd /sbin/sshd; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    command -v sshd 2>/dev/null || true
}

ssh_detect_service_name() {
    if is_systemd; then
        if systemctl cat ssh.service >/dev/null 2>&1; then
            echo "ssh"; return 0
        fi
        if systemctl cat sshd.service >/dev/null 2>&1; then
            echo "sshd"; return 0
        fi
    fi
    if [ -x /etc/init.d/ssh ]; then
        echo "ssh"
    elif [ -x /etc/init.d/sshd ]; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

ssh_is_socket_activated() {
    is_systemd || return 1
    systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null
}

ssh_collect_authorized_keys() {
    local auth_file home_dir user cnt
    for auth_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [ -f "$auth_file" ] || continue
        home_dir=$(dirname "$(dirname "$auth_file")")
        if [ "$home_dir" = "/root" ]; then
            user="root"
        else
            user=$(basename "$home_dir")
        fi
        cnt=$(awk '
            /^[[:space:]]*(#|$)/ { next }
            /(^|[[:space:]])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+\/=]+/ { c++ }
            END { print c + 0 }
        ' "$auth_file" 2>/dev/null || echo 0)
        if [ "${cnt:-0}" -gt 0 ]; then
            echo "${user}:${cnt}:${auth_file}"
        fi
    done
}

ssh_check_port_conflict() {
    local port="$1"
    local line
    if command -v ss >/dev/null 2>&1; then
        line=$(ss -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    elif command -v netstat >/dev/null 2>&1; then
        line=$(netstat -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    else
        return 1
    fi
    [ -z "$line" ] && return 1
    # 排除 sshd 进程及当前 ssh.socket 监听的端口
    if echo "$line" | grep -qE '"sshd"|"sshd-session"|[0-9]+/sshd'; then
        return 1
    fi
    if echo "$line" | grep -q '"systemd"' && ssh_is_socket_activated; then
        local sock_ports
        sock_ports=$(systemctl show ssh.socket -p Listen --value 2>/dev/null || true)
        if echo "$sock_ports" | grep -qE ":${port}([[:space:]]|$)" || [ "$port" = "22" ]; then
            return 1
        fi
    fi
    echo "$line"
    return 0
}

ssh_live_listen_ports() {
    local ports="" sock_ports="" all_listen="" p
    if command -v ss >/dev/null 2>&1; then
        all_listen=$(ss -tlnp 2>/dev/null || true)
        ports=$(printf '%s\n' "$all_listen" | awk '/"sshd"|"sshd-session"/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' || true)
        if ssh_is_socket_activated; then
            sock_ports=$(systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' || true)
            for p in $sock_ports; do
                if printf '%s\n' "$all_listen" | grep -qE ":${p}[[:space:]]"; then
                    ports="${ports}"$'\n'"${p}"
                fi
            done
        fi
        ports=$(printf '%s\n' "$ports" | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//')
    fi
    echo "$ports"
}

ssh_show_status() {
    local sshd_bin svc
    sshd_bin=$(ssh_find_sshd_bin)
    svc=$(ssh_detect_service_name)
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}           SSH 端口与安全策略状态                 ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    if [ -n "$sshd_bin" ]; then
        local eff ports pw kbd pub root_login auth_methods
        eff=$("$sshd_bin" -T 2>/dev/null || true)
        ports=$(printf '%s\n' "$eff" | awk '$1=="port"{print $2}' | tr '\n' ' ' | sed 's/ $//')
        pw=$(printf '%s\n' "$eff" | awk '$1=="passwordauthentication"{print $2; exit}')
        kbd=$(printf '%s\n' "$eff" | awk '$1=="kbdinteractiveauthentication" || $1=="challengeresponseauthentication"{print $2; exit}')
        pub=$(printf '%s\n' "$eff" | awk '$1=="pubkeyauthentication"{print $2; exit}')
        root_login=$(printf '%s\n' "$eff" | awk '$1=="permitrootlogin"{print $2; exit}')
        auth_methods=$(printf '%s\n' "$eff" | awk '$1=="authenticationmethods"{print $2; exit}')
        echo -e "  配置生效端口 : ${CYAN}${ports:-未知}${PLAIN}"
        echo -e "  实际监听端口 : ${CYAN}$(ssh_live_listen_ports | sed 's/^$/未知/')${PLAIN}"
        echo -e "  激活方式     : ${CYAN}$(ssh_is_socket_activated && echo "systemd socket (ssh.socket)" || echo "${svc} service")${PLAIN}"
        echo -e "  密码登录     : $([ "$pw" = "no" ] && echo "${GREEN}已关闭 (no)${PLAIN}" || echo "${RED}开启 (${pw:-yes})${PLAIN}")"
        echo -e "  交互认证     : $([ "$kbd" = "no" ] && echo "${GREEN}已关闭 (no)${PLAIN}" || echo "${YELLOW}${kbd:-未知}${PLAIN}")"
        echo -e "  密钥认证     : $([ "$pub" = "yes" ] && echo "${GREEN}已开启 (yes)${PLAIN}" || echo "${RED}${pub:-未知}${PLAIN}")"
        echo -e "  认证方法限制 : ${CYAN}${auth_methods:-any}${PLAIN}"
        echo -e "  Root 登录    : ${CYAN}${root_login:-未知}${PLAIN}"
    else
        echo -e "  ${YELLOW}⚠️ 未检测到服务端 sshd 二进制文件 (${svc})。${PLAIN}"
    fi
    local key_rows
    key_rows=$(ssh_collect_authorized_keys || true)
    if [ -n "$key_rows" ]; then
        echo -e "  已配置公钥   :"
        while IFS=: read -r u cnt p; do
            [ -z "$u" ] && continue
            echo -e "    - ${GREEN}${u}${PLAIN} (${cnt} 把公钥: ${p})"
        done <<< "$key_rows"
    else
        echo -e "  已配置公钥   : ${RED}无（请先添加公钥后再禁用密码登录！）${PLAIN}"
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
}

ssh_prompt_install_pubkey() {
    local target_user="" target_home=""
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -d "/home/${SUDO_USER}" ]; then
        target_user="$SUDO_USER"
        target_home="/home/${SUDO_USER}"
    else
        local cand
        for cand in ubuntu debian admin opc centos alpine; do
            if id "$cand" >/dev/null 2>&1 && [ -d "/home/${cand}" ]; then
                target_user="$cand"
                target_home="/home/${cand}"
                break
            fi
        done
    fi
    [ -z "$target_user" ] && { target_user="root"; target_home="/root"; }

    echo -e "${YELLOW}⚠️ 未在 /root/.ssh/authorized_keys 或 /home/*/.ssh/authorized_keys 检测到任何有效 SSH 公钥！${PLAIN}"
    echo -e "${RED}若此时直接关闭密码登录，你将彻底无法登录服务器！${PLAIN}"
    local paste_ans pubkey=""
    read_tty -p "是否现在为账户 '${target_user}' 粘贴添加一把 SSH 公钥？[y/N]: " paste_ans || return 1
    if [[ "$paste_ans" != "y" && "$paste_ans" != "Y" ]]; then
        echo -e "${YELLOW}已取消修改，请先配置 SSH 公钥后再执行 xm ssh。${PLAIN}"
        return 1
    fi
    read_tty -p "请粘贴 SSH 公钥整行内容 (如 ssh-ed25519 AAAA...): " pubkey || return 1
    pubkey=$(echo "$pubkey" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ ! "$pubkey" =~ (ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        echo -e "${RED}❌ 公钥格式无效，已中止修改！${PLAIN}"
        return 1
    fi
    if command -v ssh-keygen >/dev/null 2>&1; then
        if ! printf '%s\n' "$pubkey" | ssh-keygen -l -f - >/dev/null 2>&1; then
            echo -e "${RED}❌ ssh-keygen 校验证书公钥失败，已中止修改！${PLAIN}"
            return 1
        fi
    fi
    local target_group
    target_group=$(id -gn "$target_user" 2>/dev/null || echo "$target_user")
    mkdir -p "${target_home}/.ssh"
    chmod 700 "${target_home}/.ssh"
    touch "${target_home}/.ssh/authorized_keys"
    printf '%s\n' "$pubkey" >> "${target_home}/.ssh/authorized_keys"
    chmod 600 "${target_home}/.ssh/authorized_keys"
    chown -R "${target_user}:${target_group}" "${target_home}/.ssh" 2>/dev/null || true
    echo -e "${GREEN}✅ 已写入公钥至 ${target_home}/.ssh/authorized_keys！${PLAIN}"
}

ssh_print_help() {
    echo "用法: xm ssh [选项|端口号]"
    echo "  xm ssh              交互式修改 SSH 端口（默认 38291）、放行防火墙并关闭密码仅允许密钥登录"
    echo "  xm ssh <1-65535>    直接指定目标 SSH 端口并执行端口与仅密钥加固"
    echo "  xm ssh 38291 --yes  无确认直接修改（仍强制校验存在 SSH 公钥，防止锁死）"
    echo "  xm ssh status       查看当前 SSH 端口、认证策略与已配置公钥"
}

apply_ssh_hardening() {
    local new_port="$1"
    local sshd_bin svc
    sshd_bin=$(ssh_find_sshd_bin)
    svc=$(ssh_detect_service_name)

    if [ -z "$sshd_bin" ] || [ ! -f /etc/ssh/sshd_config ]; then
        echo -e "${RED}❌ 未检测到 OpenSSH 服务端 (${sshd_bin:-sshd}) 或 /etc/ssh/sshd_config，无法配置！${PLAIN}"
        return 1
    fi

    local key_rows
    key_rows=$(ssh_collect_authorized_keys || true)
    if [ -z "$key_rows" ]; then
        echo -e "${RED}❌ 未检测到任何账户的 authorized_keys 公钥，已拒绝关闭密码登录！${PLAIN}"
        return 1
    fi

    local has_nonroot_key=0 cur_eff supports_kbd=0 cur_root_login="" target_root_login="prohibit-password"
    while IFS=: read -r u _ _; do
        [ -n "$u" ] && [ "$u" != "root" ] && has_nonroot_key=1
    done <<< "$key_rows"
    cur_eff=$("$sshd_bin" -T 2>/dev/null || true)
    printf '%s\n' "$cur_eff" | grep -qi '^kbdinteractiveauthentication ' && supports_kbd=1
    cur_root_login=$(printf '%s\n' "$cur_eff" | awk '$1=="permitrootlogin"{print $2; exit}')
    if [ "$cur_root_login" = "no" ] && [ "$has_nonroot_key" -eq 1 ]; then
        target_root_login="no"
    fi

    local conflict
    if conflict=$(ssh_check_port_conflict "$new_port"); then
        echo -e "${RED}❌ 端口 ${new_port}/tcp 已被其他进程占用: ${conflict}${PLAIN}"
        return 1
    fi

    # 1. 在修改并重启 SSH 前先开放防火墙端口
    open_firewall_port_xm tcp "$new_port"
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ] && command -v semanage >/dev/null 2>&1; then
        semanage port -a -t ssh_port_t -p tcp "$new_port" >/dev/null 2>&1 || semanage port -m -t ssh_port_t -p tcp "$new_port" >/dev/null 2>&1 || true
    fi

    # 2. 完整备份现有 SSH 与 ssh.socket 配置以便异常时自动回滚
    local backup_dir had_socket_dir=0 was_socket_active=0
    backup_dir=$(mktemp -d /tmp/xm-ssh-bak.XXXXXX)
    cp -a /etc/ssh/sshd_config "${backup_dir}/sshd_config"
    if [ -d /etc/ssh/sshd_config.d ]; then
        mkdir -p "${backup_dir}/sshd_config.d"
        cp -a /etc/ssh/sshd_config.d/. "${backup_dir}/sshd_config.d/" 2>/dev/null || true
    fi
    if [ -d /etc/systemd/system/ssh.socket.d ]; then
        had_socket_dir=1
        mkdir -p "${backup_dir}/ssh.socket.d"
        cp -a /etc/systemd/system/ssh.socket.d/. "${backup_dir}/ssh.socket.d/" 2>/dev/null || true
    fi
    ssh_is_socket_activated && was_socket_active=1

    ssh_rollback() {
        cp -af "${backup_dir}/sshd_config" /etc/ssh/sshd_config
        rm -f /etc/ssh/sshd_config.d/00-xm-ssh.conf
        if [ -d "${backup_dir}/sshd_config.d" ]; then
            rm -rf /etc/ssh/sshd_config.d
            mkdir -p /etc/ssh/sshd_config.d
            cp -a "${backup_dir}/sshd_config.d/." /etc/ssh/sshd_config.d/ 2>/dev/null || true
        fi
        rm -f /etc/systemd/system/ssh.socket.d/zz-xm-ssh.conf
        if [ "$had_socket_dir" -eq 1 ]; then
            rm -rf /etc/systemd/system/ssh.socket.d
            mkdir -p /etc/systemd/system/ssh.socket.d
            cp -a "${backup_dir}/ssh.socket.d/." /etc/systemd/system/ssh.socket.d/ 2>/dev/null || true
        else
            rmdir /etc/systemd/system/ssh.socket.d 2>/dev/null || true
        fi
        if is_systemd; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            if [ "$was_socket_active" -eq 1 ]; then
                systemctl stop "${svc}.service" >/dev/null 2>&1 || true
                systemctl restart ssh.socket >/dev/null 2>&1 || true
                systemctl start "${svc}.service" >/dev/null 2>&1 || true
            else
                systemctl restart "${svc}.service" >/dev/null 2>&1 || true
            fi
        fi
        rm -rf "$backup_dir"
    }

    # 3. 构建规则块并清理旧冲突指令（避免 Port 22 叠加或 PasswordAuthentication yes 先命中生效）
    local rule_block tmp_file f kbd_line="ChallengeResponseAuthentication no"
    [ "$supports_kbd" -eq 1 ] && kbd_line="KbdInteractiveAuthentication no"
    rule_block=$(cat << EOF
# BEGIN [xm-ssh] Managed by xm ssh
Port ${new_port}
PubkeyAuthentication yes
PasswordAuthentication no
${kbd_line}
AuthenticationMethods publickey
PermitRootLogin ${target_root_login}
# END [xm-ssh]
EOF
)

    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "00-xm-ssh.conf" ] && continue
        tmp_file=$(mktemp)
        awk '
            /# BEGIN \[xm-ssh\]/ { in_blk=1; next }
            /# END \[xm-ssh\]/ { in_blk=0; next }
            in_blk { next }
            /^[[:space:]]*#/{ print; next }
            tolower($1) ~ /^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|authenticationmethods|permitrootlogin)$/ {
                print "# [xm-ssh replaced] " $0
                next
            }
            { print }
        ' "$f" > "$tmp_file"
        chmod --reference="$f" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file"
        mv -f "$tmp_file" "$f"
    done

    if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        mkdir -p /etc/ssh/sshd_config.d
        printf '%s\n' "$rule_block" > /etc/ssh/sshd_config.d/00-xm-ssh.conf
        chmod 644 /etc/ssh/sshd_config.d/00-xm-ssh.conf
    else
        tmp_file=$(mktemp)
        {
            printf '%s\n\n' "$rule_block"
            cat /etc/ssh/sshd_config
        } > "$tmp_file"
        chmod 644 "$tmp_file"
        mv -f "$tmp_file" /etc/ssh/sshd_config
    fi

    # 4. 语法与生效参数校验
    if ! "$sshd_bin" -t 2>&1; then
        echo -e "${RED}❌ sshd_config 语法校验失败，已自动回滚全部配置！${PLAIN}"
        ssh_rollback
        return 1
    fi

    local new_eff eff_ports eff_pw eff_pub eff_kbd eff_auth
    new_eff=$("$sshd_bin" -T 2>/dev/null || true)
    eff_ports=$(printf '%s\n' "$new_eff" | awk '$1=="port"{print $2}' | tr '\n' ' ' | sed 's/ $//')
    eff_pw=$(printf '%s\n' "$new_eff" | awk '$1=="passwordauthentication"{print $2; exit}')
    eff_pub=$(printf '%s\n' "$new_eff" | awk '$1=="pubkeyauthentication"{print $2; exit}')
    eff_kbd=$(printf '%s\n' "$new_eff" | awk '$1=="kbdinteractiveauthentication" || $1=="challengeresponseauthentication"{print $2; exit}')
    eff_auth=$(printf '%s\n' "$new_eff" | awk '$1=="authenticationmethods"{print $2; exit}')
    if [ "$eff_ports" != "$new_port" ] || [ "$eff_pw" != "no" ] || [ "$eff_pub" != "yes" ] || [ "${eff_kbd:-no}" != "no" ] || [ "$eff_auth" != "publickey" ]; then
        echo -e "${RED}❌ 生效 SSH 配置校验未达预期 (ports='${eff_ports}', pw='${eff_pw}', kbd='${eff_kbd}', pub='${eff_pub}', auth='${eff_auth}')，已自动回滚！${PLAIN}"
        ssh_rollback
        return 1
    fi

    # 5. 应用到 systemd (兼容 Ubuntu 24/26 ssh.socket 激活与传统 ssh/sshd 服务) 或 init
    if is_systemd; then
        if [ "$was_socket_active" -eq 1 ]; then
            mkdir -p /etc/systemd/system/ssh.socket.d
            {
                echo "[Socket]"
                echo "ListenStream="
                echo "ListenStream=0.0.0.0:${new_port}"
                [ -f /proc/net/if_inet6 ] && echo "ListenStream=[::]:${new_port}"
            } > /etc/systemd/system/ssh.socket.d/zz-xm-ssh.conf
            chmod 644 /etc/systemd/system/ssh.socket.d/zz-xm-ssh.conf
            systemctl daemon-reload
            systemctl stop "${svc}.service" 2>/dev/null || true
            if ! systemctl restart ssh.socket; then
                echo -e "${RED}❌ 重启 ssh.socket 失败，正在自动回滚！${PLAIN}"
                ssh_rollback
                return 1
            fi
            systemctl start "${svc}.service" 2>/dev/null || true
        else
            systemctl daemon-reload 2>/dev/null || true
            if ! systemctl restart "${svc}.service"; then
                echo -e "${RED}❌ 重启 ${svc}.service 失败，正在自动回滚！${PLAIN}"
                ssh_rollback
                return 1
            fi
        fi

        # 6. 校验新端口已真实处于 LISTEN 状态，否则立即回滚
        local port_ready=0 _i
        for _i in 1 2 3 4 5; do
            if ss -tln 2>/dev/null | grep -qE ":${new_port}[[:space:]]"; then
                port_ready=1
                break
            fi
            sleep 1
        done
        if [ "$port_ready" -ne 1 ]; then
            echo -e "${RED}❌ 重启后未检测到新端口 ${new_port} 正在监听，已自动回滚以免失联！${PLAIN}"
            ssh_rollback
            return 1
        fi
    else
        if command -v service >/dev/null 2>&1; then
            service "$svc" restart 2>/dev/null || true
        elif [ -x "/etc/init.d/${svc}" ]; then
            "/etc/init.d/${svc}" restart 2>/dev/null || true
        elif pidof sshd >/dev/null 2>&1; then
            kill -HUP "$(pidof sshd | awk '{print $1}')" 2>/dev/null || true
        else
            echo -e "${YELLOW}⚠️ 非 Systemd/受限容器环境，已更新 /etc/ssh 配置，请确认容器管理面板的 SSH 守护方式。${PLAIN}"
        fi
    fi

    rm -rf "$backup_dir"
    local login_user
    login_user=$(printf '%s\n' "$key_rows" | head -n1 | cut -d: -f1)
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 SSH 端口修改与仅密钥登录加固完成！${PLAIN}"
    echo -e "  - 新 SSH 端口   : ${CYAN}${new_port}/tcp${PLAIN}"
    echo -e "  - 密码/交互登录 : ${GREEN}已全部关闭${PLAIN}"
    echo -e "  - 认证方式      : ${GREEN}仅允许 SSH 公钥登录 (AuthenticationMethods publickey)${PLAIN}"
    echo -e "  - Root 登录策略 : ${CYAN}${target_root_login}${PLAIN}"
    echo -e "  - 当前可用用户  : ${CYAN}$(printf '%s\n' "$key_rows" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')${PLAIN}"
    echo -e "${YELLOW}--------------------------------------------------${PLAIN}"
    echo -e "${YELLOW}⚠️ 重要提示（防失联必看）：${PLAIN}"
    echo -e "  1. 如使用 Oracle / 阿里云 / 腾讯云 / AWS，请先在**云控制台安全组**放行 TCP ${new_port}！"
    echo -e "  2. 请**不要关闭当前 SSH 窗口**，先新开终端测试以下命令确认能正常登录："
    echo -e "     ${CYAN}ssh -p ${new_port} ${login_user}@<服务器IP>${PLAIN}"
    echo -e "${GREEN}==================================================${PLAIN}"
}

manage_ssh() {
    local arg1="${1:-}" arg2="${2:-}"
    case "$arg1" in
        help|-h|--help)
            ssh_print_help
            return 0
            ;;
        status)
            ssh_show_status
            return 0
            ;;
    esac

    local target_port="" auto_yes=0 _a
    for _a in "$@"; do
        case "$_a" in
            --yes|-y) auto_yes=1 ;;
            *)
                if [[ "$_a" =~ ^[0-9]+$ ]] && [ "$_a" -ge 1 ] && [ "$_a" -le 65535 ]; then
                    target_port="$_a"
                elif [ -n "$_a" ]; then
                    echo -e "${RED}❌ 无效参数或端口: ${_a}${PLAIN}"
                    ssh_print_help
                    return 1
                fi
                ;;
        esac
    done

    ssh_show_status

    if [ -z "$target_port" ]; then
        if [ "$auto_yes" -eq 1 ]; then
            target_port="38291"
        else
            while true; do
                local input_port=""
                read_tty -p "请输入新的 SSH 端口 [1-65535，默认 38291，输入 0 取消]: " input_port || return 1
                input_port=$(echo "$input_port" | tr -d ' \r\n')
                [ "$input_port" = "0" ] && { echo -e "${YELLOW}已取消修改。${PLAIN}"; return 0; }
                [ -z "$input_port" ] && input_port="38291"
                if [[ ! "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
                    echo -e "${RED}❌ 端口必须是 1-65535 之间的整数！${PLAIN}"
                    continue
                fi
                local conflict=""
                if conflict=$(ssh_check_port_conflict "$input_port"); then
                    echo -e "${RED}❌ 端口 ${input_port}/tcp 已被其他服务占用: ${conflict}${PLAIN}"
                    continue
                fi
                target_port="$input_port"
                break
            done
        fi
    fi

    local key_rows
    key_rows=$(ssh_collect_authorized_keys || true)
    if [ -z "$key_rows" ]; then
        if [ "$auto_yes" -eq 1 ]; then
            echo -e "${RED}❌ 未在任何账户检测到 SSH 公钥，禁止 --yes 盲目关闭密码登录！${PLAIN}"
            return 1
        fi
        ssh_prompt_install_pubkey || return 1
    fi

    if [ "$auto_yes" -ne 1 ]; then
        echo -e "\n${CYAN}即将执行以下 SSH 安全修改：${PLAIN}"
        echo -e "  - 更改 SSH 监听端口为 : ${GREEN}${target_port}/tcp${PLAIN} (自动放行本机防火墙)"
        echo -e "  - 关闭密码登录        : ${GREEN}是（仅允许 SSH 公钥登录）${PLAIN}"
        echo -e "${YELLOW}  (若使用云服务器，请确认云面板安全组已放行 ${target_port}/tcp)${PLAIN}"
        local confirm=""
        read_tty -p "确认立即应用？[Y/n]: " confirm || return 1
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo -e "${YELLOW}已取消修改。${PLAIN}"
            return 0
        fi
    fi

    apply_ssh_hardening "$target_port"
}

menu() {
    while true; do
        load_tunnel_meta
        clear 2>/dev/null || true
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}       Xray 统一综合管理控制台 (/usr/local/bin/xm)${PLAIN}"
        if [ ! -f "$CONFIG" ] && command -v warp-cli >/dev/null 2>&1; then
            echo -e "       当前模式: ${CYAN}仅 Cloudflare WARP 客户端${PLAIN}"
        elif [ "$TUNNEL_MODE" = "1" ]; then
            echo -e "       当前模式: ${CYAN}容器/NAT 穿透模式 (Cloudflare Tunnel)${PLAIN}"
        elif [ "$CF_TUNNEL_ENABLED" = "1" ]; then
            echo -e "       当前模式: ${CYAN}标准原生 VPS + CF 隧道双模式${PLAIN}"
        else
            echo -e "       当前模式: ${CYAN}标准原生 VPS 模式${PLAIN}"
        fi
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 查看节点链接与详细信息 (info)"
        echo -e " ${GREEN}2.${PLAIN} 启动服务 (start)"
        echo -e " ${GREEN}3.${PLAIN} 停止服务 (stop)"
        echo -e " ${GREEN}4.${PLAIN} 重启服务 (restart)"
        echo -e " ${GREEN}5.${PLAIN} 查看详细运行状态 (status)"
        echo -e " ${GREEN}6.${PLAIN} 查看实时日志 (log)"
        echo -e "--------------------------------------------------"
        echo -e " ${GREEN}7.${PLAIN} 重置/更换 用户 UUID (uuid)"
        if [ "$TUNNEL_MODE" = "1" ]; then
            echo -e " ${GREEN}8.${PLAIN} 修改/更新 Cloudflare Tunnel Token (token)"
        elif [ "$CF_TUNNEL_ENABLED" = "1" ]; then
            echo -e " ${GREEN}8.${PLAIN} 管理 Cloudflare Tunnel 附加隧道 (tunnel) ${GREEN}[已开启]${PLAIN}"
        else
            echo -e " ${GREEN}8.${PLAIN} 管理 Cloudflare Tunnel 附加隧道 (tunnel) ${YELLOW}[未开启]${PLAIN}"
        fi
        echo -e " ${GREEN}9.${PLAIN} 升级 Xray 官方最新内核 (update-core)"
        echo -e " ${GREEN}10.${PLAIN} 管理与定时更新 geosite/geoip 规则库 (geo / geo-cron)"
        echo -e " ${GREEN}11.${PLAIN} 校验配置文件语法 (test)"
        echo -e " ${GREEN}12.${PLAIN} 开启/检查系统 BBR 加速 (bbr)"
        echo -e " ${GREEN}13.${PLAIN} 切换 Xray 日志级别 (loglevel)"
        echo -e " ${GREEN}14.${PLAIN} SSL 证书申请/查看/续期 (cert)"
        if command -v warp-cli >/dev/null 2>&1; then
            echo -e " ${GREEN}15.${PLAIN} 管理 Cloudflare WARP 客户端 (warp)"
        elif [ "$TUNNEL_MODE" = "1" ] || [ -f /etc/xray/warp-tunnel.json ]; then
            echo -e " ${GREEN}15.${PLAIN} 查看 WARP 内置 WireGuard 状态 (warp)"
        else
            echo -e " ${GREEN}15.${PLAIN} 管理 Cloudflare WARP 客户端 (warp) ${YELLOW}[未安装]${PLAIN}"
        fi
        echo -e " ${GREEN}16.${PLAIN} 更新 xm 管理脚本到最新版 (update-script)"
        echo -e " ${GREEN}17.${PLAIN} SSH 端口修改与仅密钥登录加固 (ssh)"
        echo -e "--------------------------------------------------"
        echo -e " ${RED}18.${PLAIN} 彻底卸载清理组件 (uninstall)"
        echo -e " ${YELLOW}0.${PLAIN} 退出菜单"
        echo -e "${BLUE}==================================================${PLAIN}"
        read_tty -p "请输入选项 [0-18]: " choice
        case "$choice" in
            1) show_info ;;
            2) start_xray ;;
            3) stop_xray ;;
            4) restart_xray ;;
            5) status_xray ;;
            6) show_log ;;
            7) reset_uuid ;;
            8)
                if [ "$TUNNEL_MODE" = "1" ]; then
                    update_tunnel_token
                else
                    manage_native_tunnel
                fi
                ;;
            9) upgrade_core ;;
            10) manage_geo ;;
            11) test_config ;;
            12) enable_bbr ;;
            13) set_loglevel ;;
            14) manage_cert ;;
            15) manage_warp ;;
            16) update_xm_script 1 ;;
            17) manage_ssh ;;
            18) uninstall_xray ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入无效，请重新输入！${PLAIN}" ;;
        esac
        echo ""
        read_tty -p "按回车键返回主菜单..." _pause || break
    done
}

if [ "$_CALLER_NAME" = "warp" ]; then
    if [ "$#" -eq 0 ]; then
        warp_print_help
    else
        manage_warp "$@"
    fi
    exit $?
fi

case "${1:-}" in
    info) show_info ;;
    start) start_xray ;;
    stop) stop_xray ;;
    restart|res) restart_xray ;;
    status) status_xray ;;
    log) show_log ;;
    loglevel) set_loglevel "${2:-}" ;;
    uuid) reset_uuid ;;
    token) update_tunnel_token ;;
    tunnel) manage_native_tunnel "${2:-}" "${3:-}" ;;
    cert) manage_cert "${2:-}" ;;
    warp) shift; manage_warp "$@" ;;
    update-core) upgrade_core ;;
    update-geo) upgrade_geo ;;
    update-script|self-update|upgrade-script) update_xm_script 0 ;;
    geo) manage_geo "${2:-}" "${3:-}" "${4:-}" ;;
    geo-cron) set_geo_schedule_cli "${2:-}" "${3:-}" "${4:-}" ;;
    test) test_config ;;
    bbr) enable_bbr ;;
    ssh|ssh-port) shift; manage_ssh "$@" ;;
    uninstall|del) shift; uninstall_xray "$@" ;;
    *) menu ;;
esac
