#!/bin/bash
# ==============================================================================
# Cloudflare 官方原生 WARP 客户端安装与 SOCKS5 模式配置脚本
# 支持系统：Debian 11/12, Ubuntu 20.04/22.04/24.04
# 架构：AMD64, ARM64
# 默认端口：40000 (监听 127.0.0.1)
# ==============================================================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
PLAIN="\033[0m"

echo -e "${GREEN}>>> [WARP 1/5] 安装必要基础依赖...${PLAIN}"
apt update
apt install -y curl gpg ca-certificates lsb-release

echo -e "${GREEN}>>> [WARP 2/5] 添加 Cloudflare 官方软件源 GPG Key...${PLAIN}"
mkdir -p /usr/share/keyrings
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

. /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
> /etc/apt/sources.list.d/cloudflare-client.list

echo -e "${GREEN}>>> [WARP 3/5] 安装官方 cloudflare-warp 客户端...${PLAIN}"
apt update
apt install -y cloudflare-warp

echo -e "${GREEN}>>> [WARP 4/5] 启动官方服务并配置 SOCKS5 模式 (MASQUE / 40000 端口)...${PLAIN}"
systemctl enable --now warp-svc

# 稍等后台服务就绪
sleep 2

# 注册 WARP（若已注册则跳过）
warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new

# 设置 MASQUE 隧道协议
warp-cli --accept-tos tunnel protocol set MASQUE 2>/dev/null || true

# 设置为 SOCKS5 代理模式
warp-cli --accept-tos mode proxy

# 设置代理端口为 40000
warp-cli --accept-tos proxy port 40000

# 建立连接
warp-cli --accept-tos connect

# 创建开机自动重连守护服务
WARP_CLI=$(command -v warp-cli)
cat > /etc/systemd/system/warp-proxy-autoconnect.service <<EOF
[Unit]
Description=Cloudflare WARP Proxy Auto Connect
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=$WARP_CLI --accept-tos connect
ExecStop=$WARP_CLI --accept-tos disconnect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now warp-proxy-autoconnect.service

# 安装管理命令并建立全局软链接
REPO_URL="https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "${SCRIPT_DIR}/warp_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/warp_ctl.sh" /usr/local/bin/warp
elif [ -f "${SCRIPT_DIR}/scripts/warp_ctl.sh" ]; then
    cp -f "${SCRIPT_DIR}/scripts/warp_ctl.sh" /usr/local/bin/warp
else
    curl -sSL "${REPO_URL}/scripts/warp_ctl.sh" -o /usr/local/bin/warp
fi
chmod +x /usr/local/bin/warp
ln -sf /usr/local/bin/warp /usr/bin/warp

echo -e "${GREEN}>>> [WARP 5/5] 验证 SOCKS5 (127.0.0.1:40000) 连通性...${PLAIN}"
sleep 3
if curl -fsS -x "socks5h://127.0.0.1:40000" --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}🎉 Cloudflare 官方 WARP SOCKS5 部署成功！${PLAIN}"
    echo -e "监听地址: 127.0.0.1:40000"
    echo -e "隧道协议: MASQUE"
    echo -e "状态指令: warp status  | 测试指令: warp test"
    echo -e "${GREEN}==================================================${PLAIN}"
else
    echo -e "${YELLOW}⚠️ WARP 已配置并启动，若测试暂时超时，请稍后执行 'warp test' 验证。${PLAIN}"
fi
