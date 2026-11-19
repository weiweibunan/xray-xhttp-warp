#!/bin/bash
# ==============================================================================
# Xray (XHTTP + IPv6 S5 分流) 统一管理命令 (/usr/local/bin/xm)
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

CONFIG="/etc/xray/config.json"
CERT="/root/ygkkkca/cert.crt"
CDN_HOST="www.shopify.com"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限执行此命令！${PLAIN}"
    exit 1
fi

show_info() {
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}❌ 未找到配置文件 $CONFIG，请先安装 Xray！${PLAIN}"
        return 1
    fi

    UUID=$(grep -oE '"id": "[0-9a-fA-F-]{36}"' "$CONFIG" 2>/dev/null | head -n1 | cut -d'"' -f4)
    IP=$(curl -s4 https://icanhazip.com || curl -s4 https://api.ipify.org)

    SNI=""
    if [ -f "$CERT" ]; then
        SNI=$(openssl x509 -in "$CERT" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -n1 | grep -oE "(DNS:[^, ]+|IP Address:[^, ]+)" | head -n1 | sed -E 's/(DNS:|IP Address:)//')
        [ -z "$SNI" ] && SNI=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN[ =]*//p')
    fi
    [ -z "$SNI" ] && SNI="$IP"
    NODE_ADDR="$SNI"

    PATH_H3=$(grep -A5 'xhttp-h3-in' "$CONFIG" | grep '"path":' | head -n1 | cut -d'"' -f4)
    PATH_XC=$(grep -A5 'xhttp-cdn-443-in' "$CONFIG" | grep '"path":' | head -n1 | cut -d'"' -f4)
    PORT_H3=$(grep -B2 -A5 'xhttp-h3-in' "$CONFIG" | grep '"port":' | head -n1 | awk '{print $2}' | tr -d ',')
    PORT_XC=$(grep -B2 -A5 'xhttp-cdn-443-in' "$CONFIG" | grep '"port":' | head -n1 | awk '{print $2}' | tr -d ',')

    [ -z "$PATH_H3" ] && PATH_H3="/${UUID}-xu"
    [ -z "$PATH_XC" ] && PATH_XC="/${UUID}-xc"
    [ -z "$PORT_H3" ] && PORT_H3=8443
    [ -z "$PORT_XC" ] && PORT_XC=443

    STATUS=$(systemctl is-active xray 2>/dev/null || echo "inactive")
    if [ "$STATUS" = "active" ]; then
        STATUS_TXT="${GREEN}运行中 (active)${PLAIN}"
    else
        STATUS_TXT="${RED}未运行 ($STATUS)${PLAIN}"
    fi

    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "  Xray 服务状态 : $STATUS_TXT"
    echo -e "  服务器 IPv4   : ${CYAN}${IP}${PLAIN}"
    echo -e "  SNI 证书域名  : ${CYAN}${SNI}${PLAIN}"
    echo -e "  用户 UUID     : ${CYAN}${UUID}${PLAIN}"
    echo -e "  分流出站配置  : ${YELLOW}OpenAI + Gemini -> IPv6 -> 40000 端口${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}🌐 节点 1：【VLESS - XHTTP - CDN 优选节点】${PLAIN}(防封/CDN加速)"
    echo -e "${YELLOW}vless://${UUID}@${CDN_HOST}:${PORT_XC}?encryption=none&security=tls&sni=${SNI}&type=xhttp&path=${PATH_XC}&mode=auto#XHTTP-CDN-Shopify${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}🛡️ 节点 2：【VLESS - XHTTP - TCP ${PORT_XC} 直连】${PLAIN}(无 CDN 延迟损耗)"
    echo -e "${YELLOW}vless://${UUID}@${NODE_ADDR}:${PORT_XC}?encryption=none&security=tls&sni=${SNI}&type=xhttp&path=${PATH_XC}&mode=auto#XHTTP-TCP-Direct-${PORT_XC}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}🚀 节点 3：【VLESS - XHTTP - H3 ${PORT_H3} 直连】${PLAIN}(QUIC/UDP 抗丢包)"
    echo -e "${YELLOW}vless://${UUID}@${NODE_ADDR}:${PORT_H3}?encryption=none&security=tls&sni=${SNI}&alpn=h3&type=xhttp&path=${PATH_H3}&mode=auto#XHTTP-H3-Direct-${PORT_H3}${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
}

start_xray() {
    systemctl start xray
    echo -e "${GREEN}✅ Xray 服务已启动！${PLAIN}"
}

stop_xray() {
    systemctl stop xray
    echo -e "${YELLOW}⏸️ Xray 服务已停止！${PLAIN}"
}

restart_xray() {
    /usr/local/bin/xray -test -config "$CONFIG" >/dev/null 2>&1 || {
        echo -e "${RED}❌ 配置语法测试失败，请勿重启，检查配置！${PLAIN}"
        /usr/local/bin/xray -test -config "$CONFIG"
        return 1
    }
    systemctl restart xray
    echo -e "${GREEN}✅ Xray 服务已成功重启！${PLAIN}"
}

status_xray() {
    systemctl status xray
}

show_log() {
    echo -e "${CYAN}>>> 正在查看 Xray 实时日志 (按 Ctrl+C 退出)...${PLAIN}"
    journalctl -u xray -f -n 50
}

reset_uuid() {
    OLD_UUID=$(grep -oE '"id": "[0-9a-fA-F-]{36}"' "$CONFIG" 2>/dev/null | head -n1 | cut -d'"' -f4)
    NEW_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    
    echo -e "当前 UUID : ${YELLOW}$OLD_UUID${PLAIN}"
    echo -e "新 UUID   : ${GREEN}$NEW_UUID${PLAIN}"
    read -p "确认更换 UUID 并自动更新配置与路径？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        sed -i "s/$OLD_UUID/$NEW_UUID/g" "$CONFIG"
        restart_xray
        echo -e "${GREEN}✅ UUID 更换成功！新节点信息如下：${PLAIN}"
        show_info
    else
        echo -e "${YELLOW}操作已取消。${PLAIN}"
    fi
}

upgrade_core() {
    echo -e "${CYAN}>>> 正在检查并升级官方最新 Xray 内核...${PLAIN}"
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64|amd64) FILE="Xray-linux-64.zip" ;;
      aarch64|arm64) FILE="Xray-linux-arm64-v8a.zip" ;;
      *) echo -e "${RED}不支持的 CPU 架构: $ARCH${PLAIN}"; return 1 ;;
    esac

    TMP_DIR=$(mktemp -d)
    curl -sSL "https://github.com/XTLS/Xray-core/releases/latest/download/${FILE}" -o "${TMP_DIR}/xray.zip"
    unzip -qo "${TMP_DIR}/xray.zip" xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -rf "$TMP_DIR"
    restart_xray
    echo -e "${GREEN}✅ Xray 内核升级完成！当前版本：${PLAIN}"
    /usr/local/bin/xray version | head -n1
}

upgrade_geo() {
    echo -e "${CYAN}>>> 正在升级 geosite.dat 与 geoip.dat 规则库...${PLAIN}"
    mkdir -p /usr/local/share/xray
    curl -sSL --retry 3 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/share/xray/geosite.dat || \
    curl -sSL --retry 3 "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" -o /usr/local/share/xray/geosite.dat

    curl -sSL --retry 3 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o /usr/local/share/xray/geoip.dat || \
    curl -sSL --retry 3 "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" -o /usr/local/share/xray/geoip.dat

    cp -f /usr/local/share/xray/*.dat /usr/local/bin/ 2>/dev/null || true
    cp -f /usr/local/share/xray/*.dat /etc/xray/ 2>/dev/null || true
    restart_xray
    echo -e "${GREEN}✅ 规则库更新成功！大小：$(ls -lh /usr/local/share/xray/geosite.dat | awk '{print $5}')${PLAIN}"
}

test_config() {
    echo -e "${CYAN}>>> 正在测试配置文件语法合法性...${PLAIN}"
    /usr/local/bin/xray -test -config "$CONFIG"
}

enable_bbr() {
    echo -e "${CYAN}>>> 正在检查并开启系统 TCP BBR 加速...${PLAIN}"
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$CURRENT_CC" = "bbr" ]; then
        echo -e "${GREEN}✅ 系统已启用 BBR 加速！当前算法：${CURRENT_CC}${PLAIN}"
        return 0
    fi

    KERNEL_VER=$(uname -r | cut -d- -f1)
    MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
    MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)
    if [ "$MAJOR" -lt 4 ] || ([ "$MAJOR" -eq 4 ] && [ "$MINOR" -lt 9 ]); then
        echo -e "${RED}❌ 当前内核版本 ($KERNEL_VER) 过低，BBR 需要 Linux 4.9 以上内核！${PLAIN}"
        return 1
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

uninstall_xray() {
    read -p "⚠️ 确认要彻底卸载 Xray 服务及配置吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
        rm -rf /etc/xray /usr/local/share/xray /usr/local/bin/xray /usr/local/bin/xm /usr/local/bin/xinfo
        echo -e "${GREEN}✅ Xray 服务及管理脚本已彻底卸载干净！${PLAIN}"
        exit 0
    fi
}

menu() {
    clear
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}         Xray (XHTTP + IPv6 S5) 管理控制台        ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 查看节点链接与配置 (info)"
    echo -e " ${GREEN}2.${PLAIN} 启动 Xray 服务 (start)"
    echo -e " ${GREEN}3.${PLAIN} 停止 Xray 服务 (stop)"
    echo -e " ${GREEN}4.${PLAIN} 重启 Xray 服务 (restart)"
    echo -e " ${GREEN}5.${PLAIN} 查看详细运行状态 (status)"
    echo -e " ${GREEN}6.${PLAIN} 查看实时访问日志 (log)"
    echo -e "--------------------------------------------------"
    echo -e " ${GREEN}7.${PLAIN} 重置/更换 用户 UUID (uuid)"
    echo -e " ${GREEN}8.${PLAIN} 升级 Xray 官方最新内核 (update-core)"
    echo -e " ${GREEN}9.${PLAIN} 升级 geosite/geoip 规则库 (update-geo)"
    echo -e " ${GREEN}10.${PLAIN} 校验配置文件语法 (test)"
    echo -e " ${GREEN}11.${PLAIN} 开启/检查系统 BBR 加速 (bbr)"
    echo -e "--------------------------------------------------"
    echo -e " ${RED}12.${PLAIN} 彻底卸载 Xray (uninstall)"
    echo -e " ${YELLOW}0.${PLAIN} 退出菜单"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入选项 [0-12]: " choice
    case "$choice" in
        1) show_info ;;
        2) start_xray ;;
        3) stop_xray ;;
        4) restart_xray ;;
        5) status_xray ;;
        6) show_log ;;
        7) reset_uuid ;;
        8) upgrade_core ;;
        9) upgrade_geo ;;
        10) test_config ;;
        11) enable_bbr ;;
        12) uninstall_xray ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新输入！${PLAIN}" ;;
    esac
}

case "$1" in
    info) show_info ;;
    start) start_xray ;;
    stop) stop_xray ;;
    restart|res) restart_xray ;;
    status) status_xray ;;
    log) show_log ;;
    uuid) reset_uuid ;;
    update-core) upgrade_core ;;
    update-geo) upgrade_geo ;;
    test) test_config ;;
    bbr) enable_bbr ;;
    uninstall|del) uninstall_xray ;;
    *) menu ;;
esac
