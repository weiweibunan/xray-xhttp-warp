#!/bin/bash
# ==============================================================================
# Xray (XHTTP + 隧道穿透 / IPv6 S5 分流) 统一管理命令 (/usr/local/bin/xm)
# 自动适配 Systemd 与无 Systemd 容器/沙箱环境
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

CONFIG="/etc/xray/config.json"
CERT="/root/ygkkkca/cert.crt"
TUNNEL_CONF="/etc/xray/tunnel.conf"
CDN_HOST="www.shopify.com"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限执行此命令！${PLAIN}"
    exit 1
fi

# 加载隧道模式配置
[ -f "$TUNNEL_CONF" ] && . "$TUNNEL_CONF"

is_systemd() {
    [ -d /run/systemd/system ] && systemctl --version >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

show_info() {
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}❌ 未找到配置文件 $CONFIG，请先安装 Xray！${PLAIN}"
        return 1
    fi

    UUID=$(grep -oE '"id": "[0-9a-fA-F-]{36}"' "$CONFIG" 2>/dev/null | head -n1 | cut -d'"' -f4)
    IP=$(curl -s4 --connect-timeout 3 https://icanhazip.com || curl -s4 --connect-timeout 3 https://api.ipify.org || echo "127.0.0.1")

    # 检查进程状态
    if is_systemd; then
        X_ACT=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        CF_ACT=$(systemctl is-active cloudflared 2>/dev/null || echo "inactive")
        [ "$X_ACT" = "active" ] && X_STATUS="${GREEN}运行中 (active)${PLAIN}" || X_STATUS="${RED}未运行 ($X_ACT)${PLAIN}"
        [ "$CF_ACT" = "active" ] && CF_STATUS="${GREEN}运行中 (active)${PLAIN}" || CF_STATUS="${RED}未运行 ($CF_ACT)${PLAIN}"
    else
        pgrep -x xray >/dev/null 2>&1 && X_STATUS="${GREEN}运行中 (PID: $(pgrep -x xray | head -n1))${PLAIN}" || X_STATUS="${RED}未运行${PLAIN}"
        pgrep -x cloudflared >/dev/null 2>&1 && CF_STATUS="${GREEN}运行中 (PID: $(pgrep -x cloudflared | head -n1))${PLAIN}" || CF_STATUS="${RED}未运行${PLAIN}"
    fi

    # ---------------- 容器/隧道穿透模式 (只部署/展示优选节点) ----------------
    if [ "$TUNNEL_MODE" = "1" ]; then
        PATH_XC=$(grep -A5 'xhttp-tunnel-in' "$CONFIG" | grep '"path":' | head -n1 | cut -d'"' -f4)
        [ -z "$PATH_XC" ] && PATH_XC=$(grep -oE '/[0-9a-fA-F-]{36}-xc' "$CONFIG" | head -n1)
        [ -z "$PATH_XC" ] && PATH_XC="/${UUID}-xc"
        PORT_LOCAL="${CF_LOCAL_PORT:-8080}"
        DOMAIN="${CF_TUNNEL_DOMAIN:-$IP}"

        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "  运行模式      : ${CYAN}容器/NAT 穿透模式 (Cloudflare Tunnel 隧道入栈)${PLAIN}"
        echo -e "  Xray 服务状态 : $X_STATUS"
        echo -e "  隧道服务状态  : $CF_STATUS"
        echo -e "  隧道绑定域名  : ${CYAN}${DOMAIN}${PLAIN}"
        echo -e "  本地监听端口  : ${CYAN}127.0.0.1:${PORT_LOCAL}${PLAIN} (免证书/本地回环)"
        echo -e "  用户 UUID     : ${CYAN}${UUID}${PLAIN}"
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "${GREEN}🌐 节点：【VLESS - XHTTP - Cloudflare 优选节点】${PLAIN}(免公网端口/全CDN加速/抗封锁)"
        echo -e "${YELLOW}vless://${UUID}@${CDN_HOST}:443?encryption=none&security=tls&sni=${DOMAIN}&host=${DOMAIN}&type=xhttp&path=${PATH_XC}&mode=auto#XHTTP-CF-Tunnel-优选${PLAIN}"
        echo -e "${BLUE}====================================================================${PLAIN}"
        echo -e "💡 ${CYAN}优选节点使用贴士：${PLAIN}"
        echo -e "  1. 链接地址默认为 ${GREEN}${CDN_HOST}${PLAIN}，导入客户端后可替换为您测速筛选出的任意 Cloudflare 优选 IP/优选域名。"
        echo -e "  2. 确保在 Cloudflare Zero Trust 面板中，已为 ${CYAN}${DOMAIN}${PLAIN} 配置 Public Hostname 指向："
        echo -e "     - Service Type : ${GREEN}HTTP${PLAIN}"
        echo -e "     - URL          : ${GREEN}127.0.0.1:${PORT_LOCAL}${PLAIN} (或 localhost:${PORT_LOCAL})"
        echo -e "${BLUE}====================================================================${PLAIN}"
        return 0
    fi

    # ---------------- 标准原生 VPS 模式 (展示 3 个节点) ----------------
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

    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "  运行模式      : ${CYAN}标准原生 VPS 模式${PLAIN}"
    echo -e "  Xray 服务状态 : $X_STATUS"
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
    if is_systemd; then
        systemctl start xray
        [ "$TUNNEL_MODE" = "1" ] && systemctl start cloudflared
    else
        if ! pgrep -x xray >/dev/null 2>&1; then
            nohup /usr/local/bin/xray run -c "$CONFIG" >/var/log/xray.log 2>&1 &
        fi
        if [ "$TUNNEL_MODE" = "1" ] && ! pgrep -x cloudflared >/dev/null 2>&1; then
            if [ -n "$CF_TUNNEL_TOKEN" ]; then
                nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" >/var/log/cloudflared.log 2>&1 &
            fi
        fi
    fi
    echo -e "${GREEN}✅ 服务已启动！${PLAIN}"
}

stop_xray() {
    if is_systemd; then
        systemctl stop xray
        [ "$TUNNEL_MODE" = "1" ] && systemctl stop cloudflared 2>/dev/null || true
    else
        pkill -x xray 2>/dev/null || true
        pkill -x cloudflared 2>/dev/null || true
    fi
    echo -e "${YELLOW}⏸️ 服务已停止！${PLAIN}"
}

restart_xray() {
    /usr/local/bin/xray -test -config "$CONFIG" >/dev/null 2>&1 || {
        echo -e "${RED}❌ 配置语法测试失败，请勿重启，请先检查配置！${PLAIN}"
        /usr/local/bin/xray -test -config "$CONFIG"
        return 1
    }
    if is_systemd; then
        systemctl restart xray
        [ "$TUNNEL_MODE" = "1" ] && systemctl restart cloudflared 2>/dev/null || true
    else
        stop_xray
        sleep 1
        start_xray
    fi
    echo -e "${GREEN}✅ 服务已成功重启！${PLAIN}"
}

status_xray() {
    if is_systemd; then
        echo -e "${CYAN}>>> Xray 服务状态 (Systemd):${PLAIN}"
        systemctl status xray --no-pager
        if [ "$TUNNEL_MODE" = "1" ]; then
            echo -e "\n${CYAN}>>> Cloudflare Tunnel 状态 (Systemd):${PLAIN}"
            systemctl status cloudflared --no-pager
        fi
    else
        echo -e "${CYAN}>>> 进程运行状态 (容器环境):${PLAIN}"
        ps aux | grep -E 'xray|cloudflared' | grep -v grep || echo "未找到运行中的相关进程"
        echo -e "\n${CYAN}>>> 本地监听端口:${PLAIN}"
        ss -tulpn 2>/dev/null | grep -E 'xray|cloudflared|8080|443|8443' || netstat -tulpn 2>/dev/null | grep -E 'xray|cloudflared|8080|443|8443' || true
    fi
}

show_log() {
    if [ "$TUNNEL_MODE" = "1" ]; then
        echo -e "请选择要查看的日志："
        echo -e " 1) Xray 运行日志"
        echo -e " 2) Cloudflare 隧道日志"
        read -p "请输入选项 [1-2, 默认 1]: " log_choice
        case "$log_choice" in
            2)
                echo -e "${CYAN}>>> 查看 Cloudflare 隧道日志 (Ctrl+C 退出)...${PLAIN}"
                if is_systemd; then
                    journalctl -u cloudflared -f -n 50
                else
                    tail -n 50 -f /var/log/cloudflared.log 2>/dev/null || echo "未找到日志文件 /var/log/cloudflared.log"
                fi
                return
                ;;
            *)
                echo -e "${CYAN}>>> 查看 Xray 运行日志 (Ctrl+C 退出)...${PLAIN}"
                if is_systemd; then
                    journalctl -u xray -f -n 50
                else
                    tail -n 50 -f /var/log/xray.log 2>/dev/null || echo "未找到日志文件 /var/log/xray.log"
                fi
                return
                ;;
        esac
    fi

    echo -e "${CYAN}>>> 查看 Xray 运行日志 (按 Ctrl+C 退出)...${PLAIN}"
    if is_systemd; then
        journalctl -u xray -f -n 50
    else
        tail -n 50 -f /var/log/xray.log 2>/dev/null || echo "未找到日志文件 /var/log/xray.log"
    fi
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

update_tunnel_token() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}     更新 Cloudflare Tunnel 隧道密钥与域名        ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入新的 Cloudflare Tunnel Token: " NEW_INPUT_TOKEN
    NEW_TOKEN=$(echo "$NEW_INPUT_TOKEN" | sed -E 's/.*--token[ =]+//; s/^[ \t]*//; s/[ \t]*$//' | tr -d '\r\n"')
    if [ -z "$NEW_TOKEN" ]; then
        echo -e "${RED}❌ Token 不能为空！${PLAIN}"
        return 1
    fi

    read -p "请输入绑定的隧道域名 (如 tryaltare.20000805.xyz) [回车保持现有]: " NEW_DOMAIN
    NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed -E 's#^https?://##; s#/.*$##' | tr -d ' \r\n"' | tr '[:upper:]' '[:lower:]')
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$CF_TUNNEL_DOMAIN"

    CF_TUNNEL_TOKEN="$NEW_TOKEN"
    CF_TUNNEL_DOMAIN="$NEW_DOMAIN"

    cat > "$TUNNEL_CONF" << EOF
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN}"
CF_TUNNEL_DOMAIN="${CF_TUNNEL_DOMAIN}"
CF_LOCAL_PORT="${CF_LOCAL_PORT:-8080}"
TUNNEL_MODE="1"
EOF
    chmod 600 "$TUNNEL_CONF"

    if is_systemd; then
        cat > /etc/systemd/system/cloudflared.service << SERVICE
[Unit]
Description=Cloudflare Tunnel Agent
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl restart cloudflared
    else
        pkill -x cloudflared 2>/dev/null || true
        sleep 1
        nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" > /var/log/cloudflared.log 2>&1 &
    fi

    echo -e "${GREEN}✅ Cloudflare 隧道配置已更新并重启！${PLAIN}"
    show_info
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

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'BBRCONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBRCONF

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1

    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$NEW_CC" = "bbr" ]; then
        echo -e "${GREEN}🎉 成功开启 TCP BBR 加速！当前算法：${NEW_CC}${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ 已写入配置，如容器受宿主机限制，BBR 需宿主机开启。${PLAIN}"
    fi
}

uninstall_xray() {
    read -p "⚠️ 确认要彻底卸载服务与配置吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        stop_xray
        if is_systemd; then
            systemctl disable xray 2>/dev/null || true
            systemctl disable cloudflared 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
            systemctl daemon-reload
        fi
        sed -i '/\[xray-xhttp-warp\] Container Autostart Hook/,+14d' /root/.bashrc 2>/dev/null || true
        sed -i '/\[xray-xhttp-warp\] Container Autostart Hook/,+14d' /etc/profile 2>/dev/null || true
        rm -rf /etc/xray /usr/local/share/xray /usr/local/bin/xray /usr/local/bin/cloudflared /usr/local/bin/xm /usr/local/bin/xinfo /var/log/xray.log /var/log/cloudflared.log
        echo -e "${GREEN}✅ 服务及管理组件已彻底清理卸载干净！${PLAIN}"
        exit 0
    fi
}

menu() {
    clear
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}       Xray 统一综合管理控制台 (/usr/local/bin/xm)${PLAIN}"
    if [ "$TUNNEL_MODE" = "1" ]; then
        echo -e "       当前模式: ${CYAN}容器/NAT 穿透模式 (Cloudflare Tunnel)${PLAIN}"
    else
        echo -e "       当前模式: ${CYAN}标准原生 VPS 模式${PLAIN}"
    fi
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 查看节点链接与详细信息 (info)"
    echo -e " ${GREEN}2.${PLAIN} 启动服务 (start)"
    echo -e " ${GREEN}3.${PLAIN} 停止服务 (stop)"
    echo -e " ${GREEN}4.${PLAIN} 重启服务 (restart)"
    echo -e " ${GREEN}5.${PLAIN} 查看详细运行状态 (status)"
    echo -e " ${GREEN}6.${PLAIN} 查看实时访问日志 (log)"
    echo -e "--------------------------------------------------"
    echo -e " ${GREEN}7.${PLAIN} 重置/更换 用户 UUID (uuid)"
    if [ "$TUNNEL_MODE" = "1" ]; then
        echo -e " ${GREEN}8.${PLAIN} 修改/更新 Cloudflare Tunnel Token (token)"
    fi
    echo -e " ${GREEN}9.${PLAIN} 升级 Xray 官方最新内核 (update-core)"
    echo -e " ${GREEN}10.${PLAIN} 升级 geosite/geoip 规则库 (update-geo)"
    echo -e " ${GREEN}11.${PLAIN} 校验配置文件语法 (test)"
    echo -e " ${GREEN}12.${PLAIN} 开启/检查系统 BBR 加速 (bbr)"
    echo -e "--------------------------------------------------"
    echo -e " ${RED}13.${PLAIN} 彻底卸载清理组件 (uninstall)"
    echo -e " ${YELLOW}0.${PLAIN} 退出菜单"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入选项 [0-13]: " choice
    case "$choice" in
        1) show_info ;;
        2) start_xray ;;
        3) stop_xray ;;
        4) restart_xray ;;
        5) status_xray ;;
        6) show_log ;;
        7) reset_uuid ;;
        8) [ "$TUNNEL_MODE" = "1" ] && update_tunnel_token || echo -e "${RED}仅在隧道模式下有效${PLAIN}" ;;
        9) upgrade_core ;;
        10) upgrade_geo ;;
        11) test_config ;;
        12) enable_bbr ;;
        13) uninstall_xray ;;
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
    token) update_tunnel_token ;;
    update-core) upgrade_core ;;
    update-geo) upgrade_geo ;;
    test) test_config ;;
    bbr) enable_bbr ;;
    uninstall|del) uninstall_xray ;;
    *) menu ;;
esac
