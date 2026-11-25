#!/bin/bash
# ==============================================================================
# 官方 acme.sh 证书申请与续期管理脚本
# 支持模式：
#   1. HTTP-01 独立 80 端口申请域名证书 (Let's Encrypt EC-256)
#   2. DNS API 申请域名/泛域名证书 (Cloudflare / 腾讯云 DNSPod / 阿里云)
#   3. HTTP-01 独立 80 端口申请 IP 短期证书 (Let's Encrypt shortlived)
# 默认输出路径：/etc/xray/cert/cert.crt 与 /etc/xray/cert/private.key
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

ACME_SH="/root/.acme.sh/acme.sh"
CERT_OUT_DIR="${CERT_OUT_DIR:-/etc/xray/cert}"
CERT_FILE="${CERT_OUT_DIR}/cert.crt"
KEY_FILE="${CERT_OUT_DIR}/private.key"

ensure_acme_deps() {
    log_info ">>> 安装证书申请必要依赖 (curl, socat, openssl, cron)..."
    if command -v apt-get >/dev/null 2>&1; then
        install_pkg curl socat openssl cron ca-certificates jq
        is_systemd && systemctl enable --now cron >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        install_pkg curl socat openssl cronie ca-certificates jq
        is_systemd && systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        install_pkg curl socat openssl cronie ca-certificates jq
        is_systemd && systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        install_pkg curl socat openssl ca-certificates jq
    fi
}

ensure_acme_installed() {
    if [ -x "$ACME_SH" ]; then
        return 0
    fi

    ensure_acme_deps

    local email
    read_tty -p "请输入证书通知邮箱 (可选，直接回车跳过不设置邮箱): " email || return 1
    email=$(echo "$email" | tr -d ' \r\n')
    if [[ "$email" == *@example.* || "$email" == *@localhost* || "$email" == *@invalid* ]]; then
        log_warn "⚠️ Let's Encrypt 拒绝保留域名邮箱 (${email})，将改为无邮箱模式安装。"
        email=""
    fi
    if [ -n "$email" ]; then
        log_info ">>> 正在安装官方 acme.sh (注册邮箱: ${email})..."
    else
        log_info ">>> 正在安装官方 acme.sh (无邮箱模式)..."
    fi

    local tmp_script
    tmp_script=$(mktemp)
    if ! fetch_to_file "$tmp_script" "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"; then
        rm -f "$tmp_script"
        log_err "❌ 下载官方 acme.sh 失败，请检查网络连接！"
        return 1
    fi

    local install_args=(--install-online)
    [ -n "$email" ] && install_args+=(-m "$email")
    command -v crontab >/dev/null 2>&1 || install_args+=(--force)
    sh "$tmp_script" "${install_args[@]}"
    rm -f "$tmp_script"

    if [ ! -x "$ACME_SH" ]; then
        log_err "❌ 官方 acme.sh 安装失败！"
        return 1
    fi
    "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_ok "✅ 官方 acme.sh 安装完成（默认 CA: Let's Encrypt）。"
}

get_vps_ips() {
    VPS_V4=$(curl -fsS4 --connect-timeout 4 --max-time 6 https://icanhazip.com 2>/dev/null || curl -fsS4 --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true)
    VPS_V6=$(curl -fsS6 --connect-timeout 4 --max-time 6 https://icanhazip.com 2>/dev/null || curl -fsS6 --connect-timeout 4 --max-time 6 https://api64.ipify.org 2>/dev/null || true)
    VPS_V4=$(echo "$VPS_V4" | tr -d ' \r\n')
    VPS_V6=$(echo "$VPS_V6" | tr -d ' \r\n')
}

resolve_domain_ips() {
    local domain="$1"
    DOM_V4=""
    DOM_V6=""
    if command -v dig >/dev/null 2>&1; then
        DOM_V4=$(dig @1.1.1.1 +time=3 +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
        DOM_V6=$(dig @2606:4700:4700::1111 +time=3 +short AAAA "$domain" 2>/dev/null | grep ':' | head -n1 || true)
    fi
    if [ -z "$DOM_V4" ] && command -v jq >/dev/null 2>&1; then
        DOM_V4=$( (curl -fsS --connect-timeout 4 --max-time 6 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${domain}&type=A" 2>/dev/null || \
                   curl -fsS --connect-timeout 4 --max-time 6 -H 'accept: application/dns-json' "https://[2606:4700:4700::1111]/dns-query?name=${domain}&type=A" 2>/dev/null) | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
    fi
    if [ -z "$DOM_V6" ] && command -v jq >/dev/null 2>&1; then
        DOM_V6=$( (curl -fsS --connect-timeout 4 --max-time 6 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${domain}&type=AAAA" 2>/dev/null || \
                   curl -fsS --connect-timeout 4 --max-time 6 -H 'accept: application/dns-json' "https://[2606:4700:4700::1111]/dns-query?name=${domain}&type=AAAA" 2>/dev/null) | jq -r '.Answer[]? | select(.type==28) | .data' 2>/dev/null | head -n1 || true)
    fi
}

prepare_port_80() {
    local conflict
    if conflict=$(check_port_conflict tcp 80); then
        log_warn "⚠️ 检测到 80/tcp 端口当前被占用："
        echo "$conflict"
        local ans
        read_tty -p "是否临时停止占用 80 端口的服务 (常见如 nginx/caddy/apache2) 并释放 80 端口？(y/n): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            log_err "❌ 80 端口被占用，无法继续 HTTP-01 验证。建议改用模式 2（DNS API 申请）。"
            return 1
        fi
        local svc
        for svc in nginx caddy apache2 httpd lighttpd; do
            if is_systemd && systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc" 2>/dev/null || true
            fi
        done
        if conflict=$(check_port_conflict tcp 80); then
            if command -v fuser >/dev/null 2>&1; then
                fuser -k 80/tcp 2>/dev/null || true
            elif command -v lsof >/dev/null 2>&1; then
                lsof -ti :80 | xargs -r kill 2>/dev/null || true
            fi
            sleep 1
            if conflict=$(check_port_conflict tcp 80); then
                log_err "❌ 仍无法释放 80 端口，请手动停止相关进程后再试。"
                return 1
            fi
        fi
        log_ok "✅ 80 端口已释放。"
    fi

    open_firewall_port tcp 80
}

install_issued_cert() {
    local main_domain="$1"
    mkdir -p "$CERT_OUT_DIR"
    "$ACME_SH" --install-cert -d "$main_domain" --ecc \
        --fullchain-file "$CERT_FILE" \
        --key-file "$KEY_FILE" \
        --reloadcmd "systemctl restart xray >/dev/null 2>&1 || true"

    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"

    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        log_err "❌ 证书文件安装失败！"
        return 1
    fi

    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 SSL 证书申请与安装成功！${PLAIN}"
    echo -e "  - 证书域名 : ${CYAN}${main_domain}${PLAIN}"
    echo -e "  - 公钥路径 : ${CYAN}${CERT_FILE}${PLAIN}"
    echo -e "  - 私钥路径 : ${CYAN}${KEY_FILE}${PLAIN}"
    echo -e "  - 有效期限 : $(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)"
    echo -e "  - 自动续期 : 已配置 acme.sh 定时任务，续期后自动重启 Xray"
    echo -e "${GREEN}==================================================${PLAIN}"
}

issue_standalone_domain() {
    ensure_acme_installed
    get_vps_ips

    local domain
    while true; do
        read_tty -p "请输入已解析到本机 IP 的域名 (如 node.example.com): " domain || return 1
        domain=$(echo "$domain" | sed -E 's#^https?://##; s#/.*$##; s/:[0-9]+$//' | tr -d ' \r\n"'\''' | tr '[:upper:]' '[:lower:]')
        if [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            break
        fi
        log_err "❌ 域名格式无效（80 端口模式不支持通配符 *，请使用模式 2 申请泛域名）！"
    done

    resolve_domain_ips "$domain"
    log_info ">>> 本机公网 IPv4: ${VPS_V4:-无} | IPv6: ${VPS_V6:-无}"
    log_info ">>> 域名解析 IPv4: ${DOM_V4:-无} | IPv6: ${DOM_V6:-无}"

    local listen_v6=false
    if [ -n "$VPS_V4" ] && [ "$DOM_V4" = "$VPS_V4" ]; then
        log_ok "✅ 域名 IPv4 解析与本机一致。"
    elif [ -n "$VPS_V6" ] && [ "$DOM_V6" = "$VPS_V6" ]; then
        log_ok "✅ 域名 IPv6 解析与本机一致（将启用 IPv6 监听）。"
        listen_v6=true
    else
        log_warn "⚠️ 域名当前解析 IP 与本机公网 IP 不一致（若开启了 Cloudflare 小黄云代理，请先改为仅 DNS/灰云）。"
        local cont
        read_tty -p "是否仍要强制尝试签发？(y/n): " cont
        [[ "$cont" == "y" || "$cont" == "Y" ]] || return 1
        [ -z "$VPS_V4" ] && [ -n "$VPS_V6" ] && listen_v6=true
    fi

    prepare_port_80 || return 1

    local extra_flags=""
    [ "$listen_v6" = "true" ] && extra_flags="--listen-v6"

    if "$ACME_SH" --issue -d "$domain" --standalone -k ec-256 --server letsencrypt $extra_flags; then
        install_issued_cert "$domain"
    else
        log_err "❌ 域名证书签发失败！请检查：1) 80 端口公网入站防火墙是否放行；2) 域名解析是否关闭 CDN 小黄云并指向本机。"
        return 1
    fi
}

issue_dns_api() {
    ensure_acme_installed

    local domain
    while true; do
        read_tty -p "请输入域名 (支持单域名如 node.example.com 或泛域名 *.example.com): " domain || return 1
        domain=$(echo "$domain" | sed -E 's#^https?://##; s#/.*$##; s/:[0-9]+$//' | tr -d ' \r\n"'\''' | tr '[:upper:]' '[:lower:]')
        if [[ "$domain" =~ ^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            break
        fi
        log_err "❌ 域名格式无效！"
    done

    echo -e "${CYAN}请选择 DNS 解析托管服务商（DNS 验证无需开放 80 端口，CF 可全程开启小黄云）：${PLAIN}"
    echo -e "  1) Cloudflare (推荐)"
    echo -e "  2) 腾讯云 DNSPod"
    echo -e "  3) 阿里云 Aliyun DNS"
    local dns_choice dns_type=""
    read_tty -p "请选择 [1-3]: " dns_choice
    case "$dns_choice" in
        1)
            dns_type="dns_cf"
            echo -e "  1) Cloudflare API Token (推荐，需 Zone:DNS:Edit 权限)"
            echo -e "  2) Cloudflare Global API Key + 登录邮箱"
            local cf_auth
            read_tty -p "请选择认证方式 [1-2]: " cf_auth
            if [ "$cf_auth" = "1" ]; then
                read_tty -p "请输入 Cloudflare API Token (CF_Token): " CF_Token
                read_tty -p "请输入 Cloudflare Account ID (CF_Account_ID，可回车跳过若使用 Zone Token): " CF_Account_ID
                export CF_Token
                [ -n "$CF_Account_ID" ] && export CF_Account_ID
            else
                read_tty -p "请输入 Cloudflare 登录邮箱 (CF_Email): " CF_Email
                read_tty -p "请输入 Cloudflare Global API Key (CF_Key): " CF_Key
                export CF_Email CF_Key
            fi
            ;;
        2)
            dns_type="dns_dp"
            read_tty -p "请输入 DNSPod DP_Id: " DP_Id
            read_tty -p "请输入 DNSPod DP_Key: " DP_Key
            export DP_Id DP_Key
            ;;
        3)
            dns_type="dns_ali"
            read_tty -p "请输入 Aliyun Ali_Key: " Ali_Key
            read_tty -p "请输入 Aliyun Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret
            ;;
        *)
            log_err "❌ 无效选项！"
            return 1
            ;;
    esac

    local domain_args=(-d "$domain")
    if [[ "$domain" == \*.* ]]; then
        local apex="${domain#\*.}"
        domain_args=(-d "$apex" -d "$domain")
        log_info ">>> 检测到泛域名，将同时签发 ${apex} 与 ${domain}（SAN 将优先匹配根域以兼容直连与 CDN 节点）。"
    fi

    if "$ACME_SH" --issue --dns "$dns_type" "${domain_args[@]}" -k ec-256 --server letsencrypt; then
        local main_d="$domain"
        [[ "$domain" == \*.* ]] && main_d="${domain#\*.}"
        install_issued_cert "$main_d"
    else
        log_err "❌ DNS API 证书签发失败！请核对 API 密钥权限与域名归属。"
        return 1
    fi
}

issue_standalone_ip() {
    ensure_acme_installed
    get_vps_ips
    local default_ip="${VPS_V4:-$VPS_V6}"
    log_info ">>> 本机公网 IPv4: ${VPS_V4:-无} | IPv6: ${VPS_V6:-无}"
    log_warn "💡 提示：Let's Encrypt 短期 IP 证书仅可用于直连节点，不能用于 Cloudflare CDN 优选节点。"

    local target_ip
    read_tty -p "请输入要申请证书的公网 IP [默认 ${default_ip}]: " target_ip
    target_ip=$(echo "$target_ip" | tr -d ' \r\n')
    [ -z "$target_ip" ] && target_ip="$default_ip"
    [ -z "$target_ip" ] && { log_err "❌ 未能检测到本机公网 IP！"; return 1; }

    prepare_port_80 || return 1

    local extra_flags=""
    [[ "$target_ip" == *:* ]] && extra_flags="--listen-v6"

    if "$ACME_SH" --issue -d "$target_ip" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived $extra_flags; then
        install_issued_cert "$target_ip"
    else
        log_err "❌ IP 证书签发失败，请确认 80 端口公网可达且未触发速率限制。"
        return 1
    fi
}

show_cert_status() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}              SSL 证书状态检查                    ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    local active_cert=""
    if [ -f "$XRAY_CONFIG" ] && command -v jq >/dev/null 2>&1; then
        active_cert=$(jq -r '.inbounds[]? | .streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$XRAY_CONFIG" 2>/dev/null | head -n1 || true)
    fi
    [ -z "$active_cert" ] && [ -f "$CERT_FILE" ] && active_cert="$CERT_FILE"
    [ -z "$active_cert" ] && [ -f "/root/ygkkkca/cert.crt" ] && active_cert="/root/ygkkkca/cert.crt"

    if [ -n "$active_cert" ] && [ -f "$active_cert" ]; then
        echo -e "  当前证书路径 : ${CYAN}${active_cert}${PLAIN}"
        echo -e "  证书主题     : $(openssl x509 -in "$active_cert" -noout -subject 2>/dev/null || echo '未知')"
        echo -e "  SAN 扩展域名 : $(openssl x509 -in "$active_cert" -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ' | sed 's/X509v3 Subject Alternative Name://')"
        echo -e "  过期时间     : ${GREEN}$(openssl x509 -in "$active_cert" -noout -enddate 2>/dev/null | cut -d= -f2)${PLAIN}"
    else
        echo -e "  ${YELLOW}⚠️ 当前未检测到已安装证书。${PLAIN}"
    fi

    if [ -x "$ACME_SH" ]; then
        echo -e "\n${CYAN}>>> acme.sh 托管列表：${PLAIN}"
        "$ACME_SH" --list
    else
        echo -e "\n  acme.sh 状态 : ${YELLOW}未安装${PLAIN}"
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
}

renew_certs() {
    if [ ! -x "$ACME_SH" ]; then
        log_err "❌ 未检测到 acme.sh，请先申请证书！"
        return 1
    fi
    log_info ">>> 正在强制触发 acme.sh 证书续期检查..."
    "$ACME_SH" --cron --force
}

issue_menu() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}       官方 acme.sh 免费 SSL 证书申请向导         ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} HTTP-01 独立 80 端口申请域名证书 (需关闭 CF 小黄云，单域名)"
    echo -e " ${GREEN}2.${PLAIN} DNS API 申请域名/泛域名证书 (无需 80 端口，支持 CF/DNSPod/阿里云)"
    echo -e " ${GREEN}3.${PLAIN} HTTP-01 独立 80 端口申请 IP 证书 (无需域名，仅用于直连节点)"
    echo -e " ${YELLOW}0.${PLAIN} 返回/取消"
    echo -e "${BLUE}==================================================${PLAIN}"
    local c
    read_tty -p "请选择申请方式 [0-3]: " c
    case "$c" in
        1) issue_standalone_domain ;;
        2) issue_dns_api ;;
        3) issue_standalone_ip ;;
        0) return 1 ;;
        *) log_err "输入无效！"; return 1 ;;
    esac
}

manage_menu() {
    while true; do
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${GREEN}           SSL 证书管理 (官方 acme.sh)            ${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 查看当前证书状态与到期时间"
        echo -e " ${GREEN}2.${PLAIN} 申请 / 更换 SSL 证书"
        echo -e " ${GREEN}3.${PLAIN} 立即检查/强制续期所有托管证书"
        echo -e " ${YELLOW}0.${PLAIN} 退出"
        echo -e "${BLUE}==================================================${PLAIN}"
        local choice
        read_tty -p "请输入选项 [0-3]: " choice || return 0
        case "$choice" in
            1) show_cert_status ;;
            2) issue_menu || true ;;
            3) renew_certs || true ;;
            0) return 0 ;;
            *) log_err "输入无效！" ;;
        esac
    done
}

case "${1:-}" in
    issue) issue_menu ;;
    standalone) issue_standalone_domain ;;
    dns) issue_dns_api ;;
    ip) issue_standalone_ip ;;
    status) show_cert_status ;;
    renew) renew_certs ;;
    *) manage_menu ;;
esac
