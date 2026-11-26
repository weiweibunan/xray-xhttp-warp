#!/bin/bash
# ==============================================================================
# xray-xhttp-warp 项目综合主安装向导
# ==============================================================================

set -e

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"

# 非 root 用户（如云主机默认的 ubuntu/debian/admin 账号）直接执行 bash <(curl ...) 时自动通过 sudo 提权；
# 若直接写 sudo bash <(curl ...)，sudo 会关闭 /dev/fd 管道句柄导致报 No such file or directory，因此由脚本内部安全中转。
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo ">>> 检测到当前为非 root 用户 ($(id -un))，正在通过 sudo 自动提权..."
        _ELEVATE_ENV=()
        for _v in REPO_URL CERT_PATH KEY_PATH ENABLE_CF_TUNNEL CF_TOKEN CF_DOMAIN LOCAL_PORT; do
            if [ "${!_v+set}" = "set" ]; then
                _ELEVATE_ENV+=("${_v}=${!_v}")
            fi
        done
        _SELF_SRC="${BASH_SOURCE[0]:-}"
        if [ -n "$_SELF_SRC" ] && [ -f "$_SELF_SRC" ] && [[ "$_SELF_SRC" != /dev/fd/* ]] && [[ "$_SELF_SRC" != /proc/*/fd/* ]]; then
            _SELF_ABS=$(cd "$(dirname "$_SELF_SRC")" && pwd)/$(basename "$_SELF_SRC")
            exec sudo env "${_ELEVATE_ENV[@]}" bash "$_SELF_ABS" "$@"
        else
            _TMP_SELF=$(mktemp /tmp/xray-install.XXXXXX.sh)
            trap 'rm -f "$_TMP_SELF"' EXIT
            if ! curl -fsSL --connect-timeout 15 --retry 3 "${REPO_URL}/install.sh" -o "$_TMP_SELF"; then
                rm -f "$_TMP_SELF"
                echo "❌ 下载安装脚本进行 sudo 提权失败！请先执行 'sudo -i' 切换到 root 后重试。" >&2
                exit 1
            fi
            chmod 644 "$_TMP_SELF"
            _rc=0
            sudo env "${_ELEVATE_ENV[@]}" bash "$_TMP_SELF" "$@" || _rc=$?
            rm -f "$_TMP_SELF"
            exit "$_rc"
        fi
    else
        echo "❌ 请使用 root 权限执行此脚本！（提示：可先执行 'su -' 切换到 root 后再运行）" >&2
        exit 1
    fi
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
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

TMP_STAGE_DIR=""
cleanup_stage() {
    if [ -n "$TMP_STAGE_DIR" ] && [ -d "$TMP_STAGE_DIR" ]; then
        rm -rf "$TMP_STAGE_DIR"
    fi
    return 0
}
trap cleanup_stage EXIT

get_subscript() {
    local name="$1"
    if [ -f "${SCRIPT_DIR}/scripts/${name}" ]; then
        echo "${SCRIPT_DIR}/scripts/${name}"
    else
        [ -z "$TMP_STAGE_DIR" ] && TMP_STAGE_DIR=$(mktemp -d)
        local dest="${TMP_STAGE_DIR}/${name}"
        if ! fetch_to_file "$dest" "${REPO_URL}/scripts/${name}"; then
            log_err "❌ 下载子脚本 scripts/${name} 失败！"
            return 1
        fi
        chmod +x "$dest"
        echo "$dest"
    fi
}

ensure_ctl() {
    install_unified_xm_ctl "$SCRIPT_DIR" || true
}

preflight_xray_cert() {
    resolve_or_issue_xray_cert "$SCRIPT_DIR"
}

install_cert_only() {
    local script
    script=$(get_subscript "install_cert.sh")
    bash "$script" "$@"
}

install_warp_only() {
    local script
    script=$(get_subscript "install_warp.sh")
    bash "$script"
    ensure_ctl
}

install_xray_only() {
    local script
    script=$(get_subscript "install_xray.sh")
    bash "$script"
    ensure_ctl
}

install_tunnel_only() {
    local script
    script=$(get_subscript "install_tunnel.sh")
    bash "$script"
    ensure_ctl
}

install_all() {
    if ! is_systemd; then
        log_err "❌ 检测到当前处于非 Systemd 环境（如容器/PRoot），标准原生模式依赖 Systemd 运行 warp-svc！"
        log_warn "👉 请改用选项 2（容器/NAT 穿透模式）或执行: bash install.sh tunnel"
        exit 1
    fi

    preflight_xray_cert

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}>>> 步骤一：开启/检查系统 TCP BBR 加速...${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    enable_bbr

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}>>> 步骤二：部署 Cloudflare 官方 WARP SOCKS5 (40000)...${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    install_warp_only

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}>>> 步骤三：部署 Xray VLESS-XHTTP 与 IPv6 分流网关...${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    install_xray_only

    echo -e "\n${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 全套系统已成功就绪！${PLAIN}"
    echo -e "  - BBR 加速状态 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo -e "  - WARP 管理命令: ${CYAN}xm warp${PLAIN} (测试: xm warp test | 仍兼容 warp 命令)"
    echo -e "  - 综合管理控制台: ${CYAN}xm${PLAIN} (节点: xm info | 升级脚本: xm update-script)"
    echo -e "${GREEN}==================================================${PLAIN}"
}

uninstall_all() {
    local auto_yes=0 purge_cert=0 _arg confirm=""
    for _arg in "$@"; do
        case "$_arg" in
            --yes|-y) auto_yes=1 ;;
            --purge-cert) purge_cert=1 ;;
        esac
    done

    if [ "$auto_yes" -ne 1 ]; then
        read_tty -p "⚠️ 确认要彻底卸载 Xray、Cloudflare Tunnel 与 WARP 全套组件及配置吗？(y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_warn "已取消卸载。"
            return 0
        fi
    fi

    log_warn ">>> 正在卸载全套服务..."
    if [ -x /usr/local/bin/xm ]; then
        /usr/local/bin/xm uninstall --yes || true
    fi

    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli --accept-tos disconnect 2>/dev/null || true
        warp-cli --accept-tos registration delete 2>/dev/null || true
    fi
    if is_systemd; then
        systemctl stop warp-proxy-autoconnect.service warp-svc.service 2>/dev/null || true
        systemctl disable warp-proxy-autoconnect.service warp-svc.service 2>/dev/null || true
    fi
    pkill -x xray 2>/dev/null || true
    pkill -x cloudflared 2>/dev/null || true
    pkill -x warp-svc 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1; then
        command -v apt-mark >/dev/null 2>&1 && apt-mark unhold cloudflare-warp >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
    fi

    cleanup_autostart_hooks
    rm -f /etc/systemd/system/warp-proxy-autoconnect.service \
          /etc/systemd/system/xray.service \
          /etc/systemd/system/cloudflared.service \
          /etc/systemd/system/xray-geo-update.service \
          /etc/systemd/system/xray-geo-update.timer \
          /etc/apt/sources.list.d/cloudflare-client.list \
          /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
          /usr/local/bin/warp /usr/bin/warp \
          /usr/local/bin/xm /usr/bin/xm /usr/local/bin/xinfo \
          /usr/local/bin/xray /usr/local/bin/cloudflared \
          /var/log/xray.log /var/log/cloudflared.log /var/log/xray-geo-update.log
    cleanup_xray_dir_preserving_cert 0
    rm -rf /usr/local/share/xray /var/lib/cloudflare-warp
    is_systemd && systemctl daemon-reload 2>/dev/null || true

    if [ -d /etc/xray/cert ] || [ -x /root/.acme.sh/acme.sh ] || [ -d /root/.acme.sh ]; then
        if [ "$auto_yes" -ne 1 ]; then
            local rm_cert=""
            read_tty -p "检测到 SSL 证书 (/etc/xray/cert) 或 acme.sh，是否一并卸载清理？[y/N] (默认回车保留，防重装限频): " rm_cert || rm_cert="n"
            [[ "$rm_cert" == "y" || "$rm_cert" == "Y" ]] && purge_cert=1
        fi
        if [ "$purge_cert" -eq 1 ]; then
            cleanup_xray_dir_preserving_cert 1
            [ -x /root/.acme.sh/acme.sh ] && /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
            rm -rf /root/.acme.sh
            log_warn "🗑️ 已一并卸载清理 SSL 证书与 acme.sh。"
        else
            log_info "ℹ️ 已保留 SSL 证书 (/etc/xray/cert) 与 acme.sh 续期配置（下次安装可直接选择使用）。"
        fi
    fi

    log_ok "✅ 全套服务、配置、凭据与管理命令已清理干净！"
}

show_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "${GREEN}          xray-xhttp-warp 全官方原生网关一键安装程序                ${PLAIN}"
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 一键全套安装 (证书 + BBR + WARP + 原生双栈 + 可选CF隧道) [原生VPS推荐]"
        echo -e " ${GREEN}2.${PLAIN} 容器/NAT穿透模式 (Cloudflare 隧道入栈 + 仅部署优选节点) [容器/无端口推荐]"
        echo -e " ${GREEN}3.${PLAIN} 仅安装 Cloudflare 官方 WARP (SOCKS5 40000 端口)"
        echo -e " ${GREEN}4.${PLAIN} 仅安装 Xray (原生双栈 + 可选CF隧道 + AI 分流网关)"
        echo -e " ${GREEN}5.${PLAIN} 申请 / 管理 SSL 证书 (集成官方 acme.sh)"
        echo -e " ${GREEN}6.${PLAIN} 开启/检查系统 TCP BBR 加速"
        echo -e "--------------------------------------------------------------------"
        echo -e " ${RED}7.${PLAIN} 彻底卸载清理全套组件"
        echo -e " ${YELLOW}0.${PLAIN} 退出向导"
        echo -e "${BLUE}====================================================================${PLAIN}"
        read_tty -p "请输入选项 [0-7]: " choice || exit 0
        case "$choice" in
            1) install_all; break ;;
            2) install_tunnel_only; break ;;
            3) install_warp_only; break ;;
            4) install_xray_only; break ;;
            5) install_cert_only ;;
            6) enable_bbr; echo ""; read_tty -p "按回车键返回主菜单..." _pause || break ;;
            7) uninstall_all; break ;;
            0) exit 0 ;;
            *) log_err "输入无效，请重新输入！"; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    all) install_all ;;
    tunnel|container) install_tunnel_only ;;
    warp) install_warp_only ;;
    xray) install_xray_only ;;
    cert) install_cert_only "${2:-}" ;;
    bbr) enable_bbr ;;
    uninstall) shift; uninstall_all "$@" ;;
    *) show_menu ;;
esac
