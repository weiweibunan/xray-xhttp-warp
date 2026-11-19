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

install_warp_only() {
    local script=$(get_subscript "install_warp.sh")
    bash "$script"
}

install_xray_only() {
    local script=$(get_subscript "install_xray.sh")
    bash "$script"
}

install_all() {
    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}>>> 步骤一：部署 Cloudflare 官方 WARP SOCKS5 (40000)...${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    install_warp_only

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}>>> 步骤二：部署 Xray VLESS-XHTTP 与 IPv6 分流网关...${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    install_xray_only

    echo -e "\n${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 全套系统已成功就绪！${PLAIN}"
    echo -e "  - WARP 管理命令: ${CYAN}warp${PLAIN} (测试: warp test)"
    echo -e "  - Xray 管理命令: ${CYAN}xm${PLAIN}   (节点: xm info)"
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
    echo -e " ${GREEN}1.${PLAIN} 一键全套安装 (官方 WARP + Xray 双节点 + AI IPv6 分流) [推荐]"
    echo -e " ${GREEN}2.${PLAIN} 仅安装 Cloudflare 官方 WARP (SOCKS5 40000 端口)"
    echo -e " ${GREEN}3.${PLAIN} 仅安装 Xray (VLESS-XHTTP + AI 分流网关)"
    echo -e "--------------------------------------------------"
    echo -e " ${RED}4.${PLAIN} 彻底卸载清理全套组件"
    echo -e " ${YELLOW}0.${PLAIN} 退出向导"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入选项 [0-4]: " choice
    case "$choice" in
        1) install_all ;;
        2) install_warp_only ;;
        3) install_xray_only ;;
        4) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

case "$1" in
    all) install_all ;;
    warp) install_warp_only ;;
    xray) install_xray_only ;;
    uninstall) uninstall_all ;;
    *) show_menu ;;
esac
