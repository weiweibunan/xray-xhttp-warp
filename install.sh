#!/bin/bash
# ==============================================================================
# xray-xhttp-warp 项目综合主安装向导
# ==============================================================================

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

REPO_URL="https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限执行此脚本！${PLAIN}"
    exit 1
fi

get_subscript() {
    local name=$1
    if [ -f "${SCRIPT_DIR}/scripts/${name}" ]; then
        echo "${SCRIPT_DIR}/scripts/${name}"
    else
        local tmp="/tmp/${name}"
        curl -sSL "${REPO_URL}/scripts/${name}" -o "$tmp"
        chmod +x "$tmp"
        echo "$tmp"
    fi
}

ensure_ctl() {
    if [ ! -s /usr/local/bin/xm ]; then
        curl -sSL "${REPO_URL}/scripts/xm_ctl.sh" -o /usr/local/bin/xm 2>/dev/null && chmod +x /usr/local/bin/xm || true
    fi
    ln -sf /usr/local/bin/xm /usr/bin/xm 2>/dev/null || true

    if [ ! -s /usr/local/bin/warp ]; then
        curl -sSL "${REPO_URL}/scripts/warp_ctl.sh" -o /usr/local/bin/warp 2>/dev/null && chmod +x /usr/local/bin/warp || true
    fi
    ln -sf /usr/local/bin/warp /usr/bin/warp 2>/dev/null || true
}

install_warp_only() {
    local script=$(get_subscript "install_warp.sh")
    bash "$script"
    ensure_ctl
}

install_xray_only() {
    local script=$(get_subscript "install_xray.sh")
    bash "$script"
    ensure_ctl
}

enable_bbr() {
    echo -e "\n${CYAN}>>> 检查并开启系统 TCP BBR 加速...${PLAIN}"
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$CURRENT_CC" = "bbr" ]; then
        echo -e "${GREEN}✅ 系统已启用 BBR 加速！当前算法：${CURRENT_CC}${PLAIN}"
        return 0
    fi

    # 遵循现代系统规范：使用 /etc/sysctl.d/99-bbr.conf 独立配置文件
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'BBRCONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBRCONF

    # 清理旧版 /etc/sysctl.conf 历史遗留并重载系统配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1

    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$NEW_CC" = "bbr" ]; then
        echo -e "${GREEN}🎉 成功开启 TCP BBR 加速！当前算法：${NEW_CC}${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ 已写入 /etc/sysctl.d/99-bbr.conf，如未立即生效，建议重启服务器 (reboot)。${PLAIN}"
    fi
}

install_all() {
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
    echo -e "  - WARP 管理命令: ${CYAN}warp${PLAIN} (测试: warp test)"
    echo -e "  - Xray 管理命令: ${CYAN}xm${PLAIN}   (节点: xm info | BBR: xm bbr)"
    echo -e "${GREEN}==================================================${PLAIN}"
}

uninstall_all() {
    echo -e "${YELLOW}>>> 正在卸载全套服务...${PLAIN}"
    if [ -x /usr/local/bin/xm ]; then
        /usr/local/bin/xm uninstall || true
    fi
    systemctl stop warp-proxy-autoconnect.service warp-svc.service 2>/dev/null || true
    systemctl disable warp-proxy-autoconnect.service warp-svc.service 2>/dev/null || true
    apt purge -y cloudflare-warp 2>/dev/null || true
    rm -f /etc/systemd/system/warp-proxy-autoconnect.service /usr/local/bin/warp
    systemctl daemon-reload
    echo -e "${GREEN}✅ 全套服务已清理干净！${PLAIN}"
}

show_menu() {
    clear
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}   xray-xhttp-warp 全官方原生网关一键安装程序     ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 一键全套安装 (开启BBR + 官方WARP + Xray双节点 + AI分流) [推荐]"
    echo -e " ${GREEN}2.${PLAIN} 仅安装 Cloudflare 官方 WARP (SOCKS5 40000 端口)"
    echo -e " ${GREEN}3.${PLAIN} 仅安装 Xray (VLESS-XHTTP + AI 分流网关)"
    echo -e " ${GREEN}4.${PLAIN} 开启/检查系统 TCP BBR 加速"
    echo -e "--------------------------------------------------"
    echo -e " ${RED}5.${PLAIN} 彻底卸载清理全套组件"
    echo -e " ${YELLOW}0.${PLAIN} 退出向导"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
        1) install_all ;;
        2) install_warp_only ;;
        3) install_xray_only ;;
        4) enable_bbr ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

case "$1" in
    all) install_all ;;
    warp) install_warp_only ;;
    xray) install_xray_only ;;
    bbr) enable_bbr ;;
    uninstall) uninstall_all ;;
    *) show_menu ;;
esac
