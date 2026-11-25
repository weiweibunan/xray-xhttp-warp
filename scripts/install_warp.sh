#!/bin/bash
# ==============================================================================
# Cloudflare 官方原生 WARP 客户端安装与 SOCKS5 模式配置脚本
# 支持系统：Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (需 Systemd)
# 架构：AMD64, ARM64
# 默认端口：40000 (监听 127.0.0.1)
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
    log_err "❌ 官方 WARP 守护服务 (warp-svc) 需要 Systemd 环境！"
    log_warn "👉 容器/无 Systemd 环境请运行: bash install.sh tunnel"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    log_err "❌ 当前脚本仅支持 Debian/Ubuntu (apt-get) 系统安装官方 cloudflare-warp 包！"
    exit 1
fi

log_ok ">>> [WARP 1/5] 安装必要基础依赖..."
install_pkg curl gpg ca-certificates lsb-release

log_ok ">>> [WARP 2/5] 添加 Cloudflare 官方软件源 GPG Key..."
mkdir -p /usr/share/keyrings
TMP_GPG=$(mktemp)
trap 'rm -f "$TMP_GPG"' EXIT
fetch_to_file "$TMP_GPG" "https://pkg.cloudflareclient.com/pubkey.gpg"
gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg < "$TMP_GPG"
rm -f "$TMP_GPG"

. /etc/os-release 2>/dev/null || true
CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo bookworm)}"
if ! curl -fsI --connect-timeout 5 "https://pkg.cloudflareclient.com/dists/${CODENAME}/Release" >/dev/null 2>&1; then
    if [ "${ID:-}" = "ubuntu" ] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
        CODENAME="noble"
    else
        CODENAME="bookworm"
    fi
    log_warn "⚠️ Cloudflare 官方源暂未提供当前代号仓库，已自动回退使用 ${CODENAME}。"
fi
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

log_ok ">>> [WARP 3/5] 安装官方 cloudflare-warp 客户端..."
install_pkg cloudflare-warp

log_ok ">>> [WARP 4/5] 启动官方服务并配置 SOCKS5 模式 (MASQUE / 40000 端口)..."
systemctl enable --now warp-svc

# 轮询等待 warp-svc IPC 就绪（最多 15 秒）
WARP_READY=false
for _i in $(seq 1 15); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
        WARP_READY=true
        break
    fi
    sleep 1
done
if [ "$WARP_READY" != "true" ]; then
    log_warn "⚠️ 等待 warp-svc 响应超时，将继续尝试注册与配置..."
fi

# 注册 WARP（若已注册则跳过）
warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new

# 优先设置 MASQUE 隧道协议，记录实际生效情况
PROTO_ACTUAL="MASQUE"
if ! warp-cli --accept-tos tunnel protocol set MASQUE 2>/dev/null; then
    PROTO_ACTUAL="WireGuard (MASQUE 不可用已回退)"
    log_warn "⚠️ 设置 MASQUE 协议失败，将使用客户端默认隧道协议。"
fi

# 设置为 SOCKS5 代理模式并固定 40000 端口
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect

# 创建开机自动连接服务
WARP_CLI=$(command -v warp-cli)
cat > /etc/systemd/system/warp-proxy-autoconnect.service << EOF
[Unit]
Description=Cloudflare WARP Proxy Auto Connect
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=${WARP_CLI} --accept-tos connect
ExecStop=${WARP_CLI} --accept-tos disconnect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable warp-proxy-autoconnect.service
systemctl restart warp-proxy-autoconnect.service

# 安装管理命令并建立全局软链接
install_ctl_script "warp_ctl.sh" "/usr/local/bin/warp" "/usr/bin/warp" "$SCRIPT_DIR"

log_ok ">>> [WARP 5/5] 验证 SOCKS5 (127.0.0.1:40000) 连通性..."
WARP_V4_OK=false
WARP_V6_OK=false
for _try in 1 2 3; do
    sleep 2
    if [ "$WARP_V4_OK" != "true" ] && curl -fsS -x "socks5h://127.0.0.1:40000" --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
        WARP_V4_OK=true
    fi
    if [ "$WARP_V6_OK" != "true" ] && curl -fsS -x "socks5h://127.0.0.1:40000" --max-time 8 "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep -q "warp=on"; then
        WARP_V6_OK=true
    fi
    if [ "$WARP_V4_OK" = "true" ] && [ "$WARP_V6_OK" = "true" ]; then
        break
    fi
done

if [ "$WARP_V6_OK" = "true" ] || [ "$WARP_V4_OK" = "true" ]; then
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 Cloudflare 官方 WARP SOCKS5 部署成功！${PLAIN}"
    echo -e "监听地址 : 127.0.0.1:40000"
    echo -e "隧道协议 : ${PROTO_ACTUAL}"
    echo -e "IPv4出口 : $([ "$WARP_V4_OK" = "true" ] && echo "${GREEN}正常 (warp=on)${PLAIN}" || echo "${YELLOW}暂未通${PLAIN}")"
    echo -e "IPv6出口 : $([ "$WARP_V6_OK" = "true" ] && echo "${GREEN}正常 (warp=on)${PLAIN}" || echo "${YELLOW}暂未通${PLAIN}")"
    echo -e "状态指令 : warp status  | 测试指令: warp test"
    echo -e "${GREEN}==================================================${PLAIN}"
else
    log_warn "⚠️ WARP 已配置并启动，当前测试暂时超时，请稍后执行 'warp test' 验证。"
fi
