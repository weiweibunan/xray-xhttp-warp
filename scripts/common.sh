#!/bin/bash
# ==============================================================================
# xray-xhttp-warp 公共安装函数库 (供安装向导与各子安装脚本复用)
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_CONFIG="/etc/xray/config.json"
TUNNEL_CONF="/etc/xray/tunnel.conf"
TUNNEL_ENV="/etc/xray/tunnel.env"

log_info() { echo -e "${CYAN}$*${PLAIN}"; }
log_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
log_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
log_err()  { echo -e "${RED}$*${PLAIN}" >&2; }

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_err "❌ 请使用 root 权限执行此脚本！（提示：非 root 用户请先执行 'sudo -i'，或通过 install.sh 自动 sudo 提权运行）"
        exit 1
    fi
}

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

has_ipv4() {
    curl -fsS4 --connect-timeout 3 --max-time 5 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1
}

has_ipv6() {
    curl -fsS6 --connect-timeout 3 --max-time 5 https://[2606:4700:4700::1111]/cdn-cgi/trace >/dev/null 2>&1
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCH_NAME="amd64"
            XRAY_PKG_FILE="Xray-linux-64.zip"
            CF_ARCH_NAME="amd64"
            ;;
        aarch64|arm64)
            ARCH_NAME="arm64"
            XRAY_PKG_FILE="Xray-linux-arm64-v8a.zip"
            CF_ARCH_NAME="arm64"
            ;;
        *)
            log_err "❌ 不支持的 CPU 架构: $arch"
            return 1
            ;;
    esac
}

install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
    else
        log_err "❌ 未检测到支持的包管理器 (apt-get/dnf/yum/apk)，请手动安装依赖: $*"
        return 1
    fi
}

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

fetch_to_file() {
    local dest="$1"
    shift
    local url
    for url in "$@"; do
        [ -z "$url" ] && continue
        if curl -fsSL --connect-timeout 15 --retry 3 "$url" -o "$dest"; then
            return 0
        fi
    done
    return 1
}

install_xray_core() {
    detect_arch || return 1
    local tmp_dir zip_file dgst_file expected actual
    tmp_dir=$(mktemp -d)
    zip_file="${tmp_dir}/${XRAY_PKG_FILE}"
    dgst_file="${zip_file}.dgst"

    local base_url="https://github.com/XTLS/Xray-core/releases/latest/download"
    if ! fetch_to_file "$zip_file" "${base_url}/${XRAY_PKG_FILE}"; then
        rm -rf "$tmp_dir"
        log_err "❌ 下载 Xray 内核失败！"
        return 1
    fi

    if fetch_to_file "$dgst_file" "${base_url}/${XRAY_PKG_FILE}.dgst"; then
        expected=$(awk -F'= *' '/^SHA2-256=/{print tolower($2)}' "$dgst_file" | tr -d ' \r\n')
        actual=$(compute_sha256 "$zip_file")
        if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
            rm -rf "$tmp_dir"
            log_err "❌ Xray 安装包 SHA256 校验失败 (期望: $expected, 实际: $actual)！"
            return 1
        fi
    fi

    if ! unzip -qo "$zip_file" xray -d "$tmp_dir"; then
        rm -rf "$tmp_dir"
        log_err "❌ 解压 Xray 安装包失败！"
        return 1
    fi

    mkdir -p /usr/local/bin /etc/xray "$XRAY_ASSET_DIR"
    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"
}

ensure_dat() {
    local force="${1:-}"
    mkdir -p "$XRAY_ASSET_DIR"
    log_info ">>> 规则库来源: https://github.com/Loyalsoldier/v2ray-rules-dat"
    local file target tmp_dir tmp_file sum_file expected actual size
    for file in geosite.dat geoip.dat; do
        target="${XRAY_ASSET_DIR}/${file}"
        tmp_dir=$(mktemp -d)
        tmp_file="${tmp_dir}/${file}"
        sum_file="${tmp_dir}/${file}.sha256sum"
        expected=""

        local gh_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${file}"
        local cdn_url="https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/${file}"

        if fetch_to_file "$sum_file" "${gh_url}.sha256sum" "${cdn_url}.sha256sum"; then
            expected=$(awk '{print tolower($1)}' "$sum_file" | tr -d ' \r\n')
        fi

        if [ "$force" != "force" ] && [ -s "$target" ] && [ -n "$expected" ]; then
            actual=$(compute_sha256 "$target")
            if [ "$actual" = "$expected" ]; then
                rm -rf "$tmp_dir"
                log_ok "✅ ${file} 已是最新版本，跳过下载。"
                continue
            fi
        elif [ "$force" != "force" ] && [ -s "$target" ] && [ -z "$expected" ]; then
            size=$(wc -c < "$target" 2>/dev/null || echo 0)
            if [ "$size" -ge 1000000 ]; then
                rm -rf "$tmp_dir"
                continue
            fi
        fi

        if ! fetch_to_file "$tmp_file" "$gh_url" "$cdn_url"; then
            rm -rf "$tmp_dir"
            if [ -s "$target" ]; then
                log_warn "⚠️ 更新 ${file} 失败，保留现有规则库。"
                continue
            fi
            log_err "❌ 下载 ${file} 失败！"
            return 1
        fi

        if [ -n "$expected" ]; then
            actual=$(compute_sha256 "$tmp_file")
            if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
                rm -rf "$tmp_dir"
                log_err "❌ ${file} SHA256 校验失败，已放弃覆盖！"
                return 1
            fi
        else
            size=$(wc -c < "$tmp_file" 2>/dev/null || echo 0)
            if [ "$size" -lt 500000 ]; then
                rm -rf "$tmp_dir"
                log_err "❌ ${file} 文件异常过小 (${size} bytes)，已放弃覆盖！"
                return 1
            fi
        fi

        mv -f "$tmp_file" "$target"
        chmod 644 "$target"
        rm -f "/usr/local/bin/${file}" "/etc/xray/${file}"
        rm -rf "$tmp_dir"
    done
}

install_cloudflared() {
    detect_arch || return 1
    local cf_bin="/usr/local/bin/cloudflared"
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH_NAME}"
    local tmp_cf
    tmp_cf=$(mktemp)
    if ! fetch_to_file "$tmp_cf" "$cf_url"; then
        rm -f "$tmp_cf"
        log_err "❌ 下载 cloudflared 失败！"
        return 1
    fi
    install -m 755 "$tmp_cf" "$cf_bin"
    rm -f "$tmp_cf"
}

prompt_tunnel_params() {
    local default_port="${1:-8080}"
    local def_token="" def_domain="" def_port=""
    if [ -f "$TUNNEL_ENV" ]; then
        def_token=$(grep -E '^TUNNEL_TOKEN=' "$TUNNEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d "\"' \r" || true)
    elif [ -f "$TUNNEL_CONF" ]; then
        def_token=$(grep -E '^CF_TUNNEL_TOKEN=' "$TUNNEL_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d "\"' \r" || true)
    fi
    if [ -f "$TUNNEL_CONF" ]; then
        def_domain=$(grep -E '^CF_TUNNEL_DOMAIN=' "$TUNNEL_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d "\"' \r" || true)
        def_port=$(grep -E '^CF_LOCAL_PORT=' "$TUNNEL_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d "\"' \r" || true)
    fi
    [ -n "$def_port" ] && default_port="$def_port"

    local input_token input_domain input_port
    while true; do
        if [ -n "$def_token" ]; then
            read_tty -p "请输入 Cloudflare Tunnel Token [回车保持现有]: " input_token || return 1
            [ -z "$input_token" ] && input_token="$def_token"
        else
            read_tty -p "请输入 Cloudflare Tunnel Token (隧道密钥): " input_token || return 1
        fi
        CF_TOKEN=$(echo "$input_token" | sed -E 's/.*(--token|service install)[ =]+//; s/^[ \t]*//; s/[ \t]*$//' | tr -d '\r\n"'\'' ')
        if [ -z "$CF_TOKEN" ]; then
            log_err "❌ Token 不能为空，请从 Cloudflare Zero Trust 控制台复制！"
        elif [[ ! "$CF_TOKEN" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
            log_err "❌ Token 格式非法（包含空白或特殊符号），请重新检查！"
        else
            break
        fi
    done

    while true; do
        if [ -n "$def_domain" ]; then
            read_tty -p "请输入 Cloudflare 绑定的隧道域名 (如 node.example.com) [回车保持现有]: " input_domain || return 1
            [ -z "$input_domain" ] && input_domain="$def_domain"
        else
            read_tty -p "请输入 Cloudflare 绑定的隧道域名 (如 node.example.com): " input_domain || return 1
        fi
        CF_DOMAIN=$(echo "$input_domain" | sed -E 's#^https?://##; s#/.*$##; s/:[0-9]+$//' | tr -d ' \r\n"'\''' | tr '[:upper:]' '[:lower:]')
        if [ -z "$CF_DOMAIN" ]; then
            log_err "❌ 域名不能为空！"
        elif [[ ! "$CF_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            log_err "❌ 域名格式无效 (${CF_DOMAIN})，请仅输入合法域名！"
        else
            break
        fi
    done

    while true; do
        read_tty -p "请输入本地 Xray 隧道监听端口 [默认 ${default_port}]: " input_port || return 1
        if [ -z "$input_port" ]; then
            LOCAL_PORT="$default_port"
            break
        fi
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            LOCAL_PORT="$input_port"
            break
        fi
        log_err "❌ 端口必须是 1-65535 之间的数字！"
    done
}

write_cloudflared_systemd_unit() {
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

enable_bbr() {
    log_info "\n>>> 检查并开启系统 TCP BBR 加速..."
    local current_cc new_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$current_cc" = "bbr" ]; then
        log_ok "✅ 系统已启用 BBR 加速！当前算法：${current_cc}"
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
        log_ok "🎉 成功开启 TCP BBR 加速！当前算法：${new_cc}"
    else
        log_warn "⚠️ 已写入 /etc/sysctl.d/99-bbr.conf；若为受限容器环境，BBR 需在宿主机开启。"
    fi
}

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

extract_uuid_from_config() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.inbounds // [])[] | (.settings.clients // [])[] | .id // empty' "$cfg" 2>/dev/null | grep -E '^[0-9a-fA-F-]{36}$' | head -n1
    else
        grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' "$cfg" 2>/dev/null | head -n1 | grep -oE '[0-9a-fA-F-]{36}'
    fi
}

ensure_net_tools() {
    if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; then
        install_pkg iproute2 || true
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        install_pkg iproute || true
    fi
}

check_port_conflict() {
    local proto="$1"
    local port="$2"
    local flag line
    [ "$proto" = "udp" ] && flag="-ulnp" || flag="-tlnp"
    if command -v ss >/dev/null 2>&1; then
        line=$(ss "$flag" 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    elif command -v netstat >/dev/null 2>&1; then
        line=$(netstat "$flag" 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    else
        return 1
    fi
    [ -z "$line" ] && return 1
    if echo "$line" | grep -qE '"xray"|[0-9]+/xray'; then
        return 1
    fi
    echo "$line"
    return 0
}

resolve_free_port() {
    local proto="$1"
    local port="$2"
    local label="${3:-$proto}"
    local hint="${4:-}"
    local conflict input
    while conflict=$(check_port_conflict "$proto" "$port"); do
        log_warn "⚠️ 检测到 ${label} ${port} 端口已被其他进程占用: ${conflict}"
        while true; do
            read_tty -p "请输入自定义 ${label} 监听端口 (${hint}，直接回车中止安装): " input || return 1
            [ -z "$input" ] && { log_err "❌ 已中止安装，请先释放 ${port} 端口或指定有效端口。"; return 1; }
            input=$(echo "$input" | tr -d ' \r\n')
            if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
                port="$input"
                break
            fi
            log_err "❌ 端口必须是 1-65535 之间的数字！"
        done
    done
    RESOLVED_PORT="$port"
}

open_firewall_port() {
    local proto="$1"
    local port="$2"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="${port}/${proto}" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
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
        fi
    fi
}

atomic_write_xray_config() {
    local tmp_cfg="$1"
    local target_cfg="$2"
    if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp_cfg"; then
        log_err "❌ Xray 配置语法校验失败，已保留原配置不受影响！"
        rm -f "$tmp_cfg"
        return 1
    fi
    mkdir -p "$(dirname "$target_cfg")"
    chmod 644 "$tmp_cfg"
    mv -f "$tmp_cfg" "$target_cfg"
}

install_ctl_script() {
    local script_name="$1"
    local dest_path="$2"
    local symlink_path="$3"
    local caller_dir="${4:-}"
    local tmp_file
    tmp_file=$(mktemp)

    if [ -n "$caller_dir" ] && [ -f "${caller_dir}/${script_name}" ]; then
        cp -f "${caller_dir}/${script_name}" "$tmp_file"
    elif [ -n "$caller_dir" ] && [ -f "${caller_dir}/scripts/${script_name}" ]; then
        cp -f "${caller_dir}/scripts/${script_name}" "$tmp_file"
    else
        if ! fetch_to_file "$tmp_file" "${REPO_URL}/scripts/${script_name}"; then
            rm -f "$tmp_file"
            log_warn "⚠️ 下载 ${script_name} 失败。"
            return 1
        fi
    fi

    install -m 755 "$tmp_file" "$dest_path"
    rm -f "$tmp_file"
    if [ -n "$symlink_path" ]; then
        ln -sf "$dest_path" "$symlink_path" 2>/dev/null || true
    fi
}

install_unified_xm_ctl() {
    local caller_dir="${1:-}"
    install_ctl_script "xm_ctl.sh" "/usr/local/bin/xm" "/usr/bin/xm" "$caller_dir" || return 1
    ln -sf "/usr/local/bin/xm" "/usr/local/bin/warp" 2>/dev/null || true
    ln -sf "/usr/local/bin/xm" "/usr/bin/warp" 2>/dev/null || true
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

resolve_or_issue_xray_cert() {
    local caller_dir="${1:-}"
    local cert="${CERT_PATH:-}"
    local key="${KEY_PATH:-}"

    if [ -n "$cert" ] && [ -n "$key" ] && [ -f "$cert" ] && [ -f "$key" ]; then
        export CERT_PATH="$cert" KEY_PATH="$key"
        return 0
    fi

    if [ -f "/etc/xray/cert/cert.crt" ] && [ -f "/etc/xray/cert/private.key" ]; then
        export CERT_PATH="/etc/xray/cert/cert.crt" KEY_PATH="/etc/xray/cert/private.key"
        log_ok "✅ 已自动检测到证书: ${CERT_PATH}"
        return 0
    fi

    log_warn "⚠️ 未在默认路径 /etc/xray/cert 检测到 TLS 证书，原生模式必须配置域名证书。"
    while true; do
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 一键申请免费 SSL 证书 (集成官方 acme.sh) [推荐]"
        echo -e " ${GREEN}2.${PLAIN} 手动输入服务器上已有的证书与私钥路径"
        echo -e " ${YELLOW}0.${PLAIN} 退出安装"
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
        local choice input_cert input_key
        read_tty -p "请选择证书来源 [0-2]: " choice || return 1
        case "$choice" in
            1)
                local cert_script="" tmp_dir=""
                if [ -n "$caller_dir" ] && [ -f "${caller_dir}/install_cert.sh" ]; then
                    cert_script="${caller_dir}/install_cert.sh"
                elif [ -n "$caller_dir" ] && [ -f "${caller_dir}/scripts/install_cert.sh" ]; then
                    cert_script="${caller_dir}/scripts/install_cert.sh"
                else
                    tmp_dir=$(mktemp -d)
                    if ! fetch_to_file "${tmp_dir}/common.sh" "${REPO_URL}/scripts/common.sh" || \
                       ! fetch_to_file "${tmp_dir}/install_cert.sh" "${REPO_URL}/scripts/install_cert.sh"; then
                        rm -rf "$tmp_dir"
                        log_err "❌ 下载证书申请模块失败！"
                        return 1
                    fi
                    chmod +x "${tmp_dir}/install_cert.sh"
                    cert_script="${tmp_dir}/install_cert.sh"
                fi
                if bash "$cert_script" issue && [ -f "/etc/xray/cert/cert.crt" ] && [ -f "/etc/xray/cert/private.key" ]; then
                    [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
                    export CERT_PATH="/etc/xray/cert/cert.crt" KEY_PATH="/etc/xray/cert/private.key"
                    return 0
                fi
                [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
                log_warn "⚠️ 证书尚未就绪，请重试或选择其他方式。"
                ;;
            2)
                read_tty -p "请输入证书公钥路径 (cert.crt / fullchain.pem): " input_cert
                read_tty -p "请输入证书私钥路径 (private.key / privkey.pem): " input_key
                if [ -f "$input_cert" ] && [ -f "$input_key" ]; then
                    export CERT_PATH="$input_cert" KEY_PATH="$input_key"
                    return 0
                fi
                log_err "❌ 指定的文件不存在，请重新输入！"
                ;;
            0)
                log_warn "已取消安装。"
                return 1
                ;;
            *)
                log_err "输入无效！"
                ;;
        esac
    done
}

# 配置 Cloudflare 官方 WARP APT 软件源与 GPG 密钥
setup_cloudflare_warp_repo() {
    command -v apt-get >/dev/null 2>&1 || return 1
    if ! command -v gpg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        install_pkg curl gnupg ca-certificates || return 1
    fi

    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    local tmp_gpg codename=""
    tmp_gpg=$(mktemp)
    if ! fetch_to_file "$tmp_gpg" "https://pkg.cloudflareclient.com/pubkey.gpg"; then
        rm -f "$tmp_gpg"
        log_err "❌ 下载 Cloudflare 官方 APT 公钥失败！"
        return 1
    fi
    if ! gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg < "$tmp_gpg"; then
        rm -f "$tmp_gpg"
        log_err "❌ 导入 Cloudflare 官方 APT 公钥失败！"
        return 1
    fi
    rm -f "$tmp_gpg"

    . /etc/os-release 2>/dev/null || true
    codename="${VERSION_CODENAME:-}"
    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs 2>/dev/null || true)
    fi
    [ -z "$codename" ] && codename="bookworm"
    if ! curl -fsI --connect-timeout 5 "https://pkg.cloudflareclient.com/dists/${codename}/Release" >/dev/null 2>&1; then
        if [ "${ID:-}" = "ubuntu" ] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
            codename="noble"
        else
            codename="bookworm"
        fi
        log_warn "⚠️ Cloudflare 官方源暂未提供当前代号仓库，已自动回退使用 ${codename}。"
    fi
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
}

# 按白名单拆分 cloudflare-warp 的 Depends 字段，输出两行: KEPT|... 和 DROPPED|...
_filter_warp_depends() {
    awk -v raw="$1" '
        function is_allowed_dep(item, pkg) {
            pkg = item
            sub(/[[:space:]]*\([^)]*\)/, "", pkg)
            sub(/:[A-Za-z0-9_-]+$/, "", pkg)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", pkg)
            return (pkg ~ /^(libc6|libc-bin|libgcc(-s1|1)|libstdc\+\+6|zlib1g|libzstd1|libdbus-1-3|dbus|libsystemd0|systemd|iproute2|nftables|iptables|libcap2(-bin)?|libpcap[0-9.]*(t64)?|libnl-[0-9-]+|libmnl0|gnupg2?|ca-certificates|libnss3(-tools)?|libnspr4|libssl[0-9.]*(t64)?|openssl|libtss2-[a-z0-9.-]+|libsqlite3-[0-9.]+(t64)?|libcurl[0-9][a-z0-9.-]*|curl)$/)
        }
        BEGIN {
            n = split(raw, deps, /,[[:space:]]*/)
            kept_out = ""; drop_out = ""
            for (i = 1; i <= n; i++) {
                d = deps[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", d)
                if (d == "") continue
                m = split(d, alts, /[[:space:]]*\|[[:space:]]*/)
                kept_alt = ""
                for (j = 1; j <= m; j++) {
                    a = alts[j]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", a)
                    if (is_allowed_dep(a)) {
                        kept_alt = (kept_alt == "" ? a : kept_alt " | " a)
                    }
                }
                if (kept_alt != "") {
                    kept_out = (kept_out == "" ? kept_alt : kept_out ", " kept_alt)
                } else {
                    drop_out = (drop_out == "" ? d : drop_out ", " d)
                }
            }
            print "KEPT|" kept_out
            print "DROPPED|" drop_out
        }
    '
}

# 从官方 signed APT 仓库下载 cloudflare-warp .deb 并剥离桌面 GUI 组件及图形硬依赖，
# 采用白名单保留无头运行必需依赖，避免无头服务器拉取 150+ 个 GTK/WebKitGTK/Mesa/X11/Wayland 包。
install_cloudflare_warp_headless() {
    command -v apt-get >/dev/null 2>&1 || return 1
    command -v dpkg-deb >/dev/null 2>&1 || return 1

    DEBIAN_FRONTEND=noninteractive apt-get update -y || return 1

    local cur_status="" cur_ver="" cur_deps="" cur_dropped="" cand_ver="" had_gui_deps="0"
    cur_status=$(dpkg-query -W -f='${db:Status-Status}' cloudflare-warp 2>/dev/null || true)
    if [ "$cur_status" = "installed" ]; then
        cur_ver=$(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null || true)
        cur_deps=$(dpkg-query -W -f='${Depends}' cloudflare-warp 2>/dev/null || true)
        cur_dropped=$(_filter_warp_depends "$cur_deps" | awk -F'|' '/^DROPPED\|/{print substr($0, 9)}')
        [ -n "$cur_dropped" ] && had_gui_deps="1"
    fi

    cand_ver=$(LC_ALL=C apt-cache policy cloudflare-warp 2>/dev/null | awk '/Candidate:/{print $2; exit}')
    if [ "$cur_status" = "installed" ] && [ -n "$cur_ver" ] && [ -n "$cand_ver" ] && [ "$cand_ver" != "(none)" ] && [ "$cur_ver" = "$cand_ver" ] && [ "$had_gui_deps" = "0" ]; then
        apt-mark hold cloudflare-warp >/dev/null 2>&1 || true
        log_ok "✅ cloudflare-warp (${cur_ver}，无 GUI 精简版) 已是最新版本！"
        return 0
    fi

    local base_tmp="/tmp"
    [ -d /var/tmp ] && [ -w /var/tmp ] && base_tmp="/var/tmp"
    local work_dir
    work_dir=$(mktemp -d "${base_tmp}/warp-headless.XXXXXX")
    chmod 755 "$work_dir"

    log_info ">>> 正在从 Cloudflare 官方源下载并按白名单构建无 GUI 精简版 cloudflare-warp..."
    if ! (cd "$work_dir" && DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root download cloudflare-warp); then
        rm -rf "$work_dir"
        log_err "❌ 下载官方 cloudflare-warp 软件包失败！"
        return 1
    fi

    local raw_deb pkg_dir headless_deb inst_kb s
    raw_deb=$(find "$work_dir" -maxdepth 1 -name 'cloudflare-warp_*.deb' | head -n1)
    if [ -z "$raw_deb" ] || [ ! -f "$raw_deb" ]; then
        rm -rf "$work_dir"
        log_err "❌ 未找到下载的 cloudflare-warp .deb 包！"
        return 1
    fi

    pkg_dir="${work_dir}/pkg"
    if ! dpkg-deb -R "$raw_deb" "$pkg_dir"; then
        rm -rf "$work_dir"
        log_err "❌ 解包 cloudflare-warp .deb 失败！"
        return 1
    fi
    rm -f "$raw_deb"

    # 移除桌面托盘程序、Flutter/GTK 运行时与桌面入口文件（不影响 warp-svc / warp-cli）
    rm -rf \
        "${pkg_dir}/bin/warp-taskbar" \
        "${pkg_dir}/usr/bin/warp-taskbar" \
        "${pkg_dir}/usr/lib/warp" \
        "${pkg_dir}/usr/lib/systemd/user" \
        "${pkg_dir}/etc/xdg/autostart" \
        "${pkg_dir}/usr/share/applications" \
        "${pkg_dir}/usr/share/icons" \
        "${pkg_dir}/usr/share/dbus-1/services/com.cloudflare.WarpTaskbar.service"

    local raw_ctrl_deps="" dep_filter_out="" kept_deps="" dropped_deps=""
    raw_ctrl_deps=$(awk '
        /^Depends:/ { in_dep=1; sub(/^Depends:[[:space:]]*/, ""); printf "%s", $0; next }
        in_dep && /^[[:space:]]+/ { sub(/^[[:space:]]+/, ""); printf " %s", $0; next }
        in_dep { exit }
    ' "${pkg_dir}/DEBIAN/control")
    dep_filter_out=$(_filter_warp_depends "$raw_ctrl_deps")
    kept_deps=$(printf '%s\n' "$dep_filter_out" | awk '/^KEPT\|/{print substr($0, 6); exit}')
    dropped_deps=$(printf '%s\n' "$dep_filter_out" | awk '/^DROPPED\|/{print substr($0, 9); exit}')

    awk -v kept="$kept_deps" '
        BEGIN { replaced=0; in_dep=0 }
        /^Depends:/ {
            in_dep=1
            if (kept != "" && !replaced) { print "Depends: " kept; replaced=1 }
            next
        }
        in_dep && /^[[:space:]]+/ { next }
        { in_dep=0 }
        /^Installed-Size:/ { next }
        { print }
    ' "${pkg_dir}/DEBIAN/control" > "${work_dir}/control.new"
    inst_kb=$(du -sk --exclude="${pkg_dir}/DEBIAN" "$pkg_dir" 2>/dev/null | awk '{print $1}')
    [ -n "$inst_kb" ] && echo "Installed-Size: ${inst_kb}" >> "${work_dir}/control.new"
    mv -f "${work_dir}/control.new" "${pkg_dir}/DEBIAN/control"

    [ -n "$kept_deps" ] && log_info ">>> 白名单保留核心依赖: ${kept_deps}"
    [ -n "$dropped_deps" ] && log_info ">>> 已过滤非白名单依赖: ${dropped_deps}"

    if [ -f "${pkg_dir}/DEBIAN/md5sums" ]; then
        grep -vE ' ((usr/)?bin/warp-taskbar|usr/lib/warp/|usr/lib/systemd/user/|etc/xdg/autostart/|usr/share/applications/|usr/share/icons/|usr/share/dbus-1/services/com\.cloudflare\.WarpTaskbar\.service)' \
            "${pkg_dir}/DEBIAN/md5sums" > "${work_dir}/md5sums.new" || true
        mv -f "${work_dir}/md5sums.new" "${pkg_dir}/DEBIAN/md5sums"
    fi

    for s in preinst postinst prerm postrm; do
        if [ -f "${pkg_dir}/DEBIAN/${s}" ]; then
            sed -E -i 's/^([[:space:]]*)(for_each_regular_user (cleanup_legacy_desktop_entries|migrate_flutter_data|enable_or_restart_warp_taskbar_service|enable_warp_taskbar_service|disable_warp_taskbar_service|remove_gui_user_data)|update_desktop_database)[[:space:]]*$/\1:/' "${pkg_dir}/DEBIAN/${s}"
            chmod 755 "${pkg_dir}/DEBIAN/${s}"
        fi
    done

    headless_deb="${work_dir}/cloudflare-warp-headless.deb"
    # 使用 -Znone 跳过耗时的 xz 二次压缩，避免低内存小鸡 tmpfs 爆满或长时间卡死
    if ! dpkg-deb -b -Znone --root-owner-group "$pkg_dir" "$headless_deb"; then
        rm -rf "$work_dir"
        log_err "❌ 重新打包无 GUI 版 cloudflare-warp 失败！"
        return 1
    fi
    rm -rf "$pkg_dir"

    apt-mark unhold cloudflare-warp >/dev/null 2>&1 || true
    local install_ok=1
    if [ "$cur_status" = "installed" ] && [ "$cur_ver" = "$cand_ver" ]; then
        # 同版本替换（例如将旧版带 GUI 依赖的官方包原位替换为无 GUI 精简版）
        if dpkg -i --force-confdef --force-confold "$headless_deb" && DEBIAN_FRONTEND=noninteractive apt-get install -y -f --no-install-recommends; then
            install_ok=0
        fi
    else
        if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$headless_deb"; then
            install_ok=0
        fi
    fi
    rm -rf "$work_dir"

    if [ "$install_ok" -ne 0 ]; then
        log_err "❌ 安装无 GUI 精简版 cloudflare-warp 失败！"
        return 1
    fi

    # 锁定包版本，防止 apt upgrade 重新拉取带 GUI 依赖的上游包；升级请使用 'xm warp update'
    apt-mark hold cloudflare-warp >/dev/null 2>&1 || true

    # 安装后校验保留二进制的动态链接库完整性，防止未来新版新增核心库时漏判
    local bin_name bin_path missing_libs
    for bin_name in warp-svc warp-cli warp-diag warp-dex; do
        bin_path=""
        if [ -x "/bin/${bin_name}" ]; then
            bin_path="/bin/${bin_name}"
        elif [ -x "/usr/bin/${bin_name}" ]; then
            bin_path="/usr/bin/${bin_name}"
        fi
        [ -n "$bin_path" ] || continue
        missing_libs=$(ldd "$bin_path" 2>/dev/null | grep "not found" || true)
        if [ -n "$missing_libs" ]; then
            log_err "❌ ${bin_path} 缺少动态依赖库，可能与上游新版新增依赖不兼容："
            log_err "$missing_libs"
            [ -n "$dropped_deps" ] && log_warn "👉 本次被白名单过滤的上游依赖: ${dropped_deps}"
            return 1
        fi
    done

    if [ "$had_gui_deps" = "1" ]; then
        log_info "💡 已将 cloudflare-warp 替换为无 GUI 精简版；如需清理此前遗留的图形包可执行: apt-get autoremove -y"
    fi
    return 0
}
