#!/bin/bash
# ==============================================================================
# Cloudflare WARP 官方客户端简易管理命令 (/usr/local/bin/warp)
# ==============================================================================

CLI=$(command -v warp-cli)

if [ -z "$CLI" ]; then
  echo "❌ 未检测到 warp-cli 客户端，请先安装 cloudflare-warp！"
  exit 1
fi

case "$1" in
  register)
    $CLI --accept-tos registration new
    ;;

  unregister)
    $CLI --accept-tos registration delete
    ;;

  start|connect)
    $CLI --accept-tos connect
    ;;

  stop|disconnect)
    $CLI --accept-tos disconnect
    ;;

  restart)
    $CLI --accept-tos disconnect || true
    sleep 1
    $CLI --accept-tos connect
    ;;

  status)
    $CLI --accept-tos status
    ;;

  info)
    $CLI --accept-tos registration show
    ;;

  port)
    if [ -z "$2" ]; then
      echo "用法: warp port 40000"
      exit 1
    fi
    $CLI --accept-tos proxy port "$2"
    ;;

  test)
    echo ">>> 正在通过 SOCKS5 代理 (127.0.0.1:${2:-40000}) 测试 Cloudflare 连通性与 IP 出口..."
    curl -fsS -x "socks5h://127.0.0.1:${2:-40000}" https://www.cloudflare.com/cdn-cgi/trace
    ;;

  autostart)
    case "$2" in
      on)
        systemctl enable --now warp-proxy-autoconnect.service
        echo "✅ WARP 开机自启动已开启！"
        ;;
      off)
        systemctl disable --now warp-proxy-autoconnect.service
        echo "⏸️ WARP 开机自启动已关闭！"
        ;;
      *)
        echo "用法: warp autostart on|off"
        ;;
    esac
    ;;

  logs)
    journalctl -u warp-svc -n "${2:-100}" --no-pager
    ;;

  update)
    apt update && apt install --only-upgrade -y cloudflare-warp
    ;;

  *)
    echo "=================================================="
    echo "       Cloudflare 官方原生 WARP SOCKS5 管理"
    echo "=================================================="
    echo "warp register       注册 WARP 客户端"
    echo "warp unregister     注销当前注册设备"
    echo "warp start          启动连接 (connect)"
    echo "warp stop           断开连接 (disconnect)"
    echo "warp restart        重启连接"
    echo "warp status         查看连接状态"
    echo "warp info           查看注册信息与设备 ID"
    echo "warp port 40000     修改 SOCKS5 监听端口"
    echo "warp test           测试 SOCKS5 代理出口 IP"
    echo "warp autostart on   开启开机自动连接服务"
    echo "warp autostart off  关闭开机自动连接服务"
    echo "warp logs           查看后台服务日志"
    echo "warp update         更新官方客户端软件包"
    echo "=================================================="
    ;;
esac
