#!/bin/bash
# ==============================================================================
# Cloudflare WARP 官方客户端简易管理命令 (/usr/local/bin/warp)
# 单文件自包含
# ==============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
_WARP_ARGS=("$@")
CLI=$(command -v warp-cli || true)

if [ -z "$CLI" ]; then
    echo "❌ 未检测到 warp-cli 客户端，请先安装 cloudflare-warp！"
    exit 1
fi

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && [[ "${BASH_SOURCE[0]}" != /dev/fd/* ]] && [[ "${BASH_SOURCE[0]}" != /proc/*/fd/* ]]; then
            echo ">>> 此操作需要 root 权限，正在通过 sudo 自动提权..." >&2
            local -a elevate_env=()
            local _v _self_abs
            for _v in REPO_URL; do
                [ "${!_v+set}" = "set" ] && elevate_env+=("${_v}=${!_v}")
            done
            _self_abs=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
            exec sudo env "${elevate_env[@]}" bash "$_self_abs" "${_WARP_ARGS[@]}"
        fi
        echo "❌ 此操作需要 root 权限，请使用 sudo 或 root 执行！" >&2
        exit 1
    fi
}

detect_socks_port() {
    local custom="${1:-}"
    if [ -n "$custom" ]; then
        echo "$custom"
        return 0
    fi
    local port
    port=$("$CLI" --accept-tos settings 2>/dev/null | grep -iE 'proxy port|local proxy port' | grep -oE '[0-9]+' | tail -n1 || true)
    if [ -z "$port" ] && [ -f /etc/xray/config.json ]; then
        port=$(grep -A6 '"socks-warp"' /etc/xray/config.json 2>/dev/null | grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)
    fi
    echo "${port:-40000}"
}

case "${1:-}" in
    register)
        require_root
        "$CLI" --accept-tos registration new
        ;;

    unregister)
        require_root
        "$CLI" --accept-tos registration delete
        ;;

    start|connect)
        require_root
        "$CLI" --accept-tos connect
        ;;

    stop|disconnect)
        require_root
        "$CLI" --accept-tos disconnect
        ;;

    restart)
        require_root
        "$CLI" --accept-tos disconnect || true
        sleep 1
        "$CLI" --accept-tos connect
        ;;

    status)
        "$CLI" --accept-tos status
        ;;

    info)
        "$CLI" --accept-tos registration show
        ;;

    port)
        require_root
        if [ -z "${2:-}" ] || [[ ! "${2:-}" =~ ^[0-9]+$ ]] || [ "${2}" -lt 1 ] || [ "${2}" -gt 65535 ]; then
            echo "用法: warp port <1-65535> (例如: warp port 40000)"
            exit 1
        fi
        "$CLI" --accept-tos proxy port "$2"
        ;;

    test)
        PORT=$(detect_socks_port "${2:-}")
        echo ">>> 正在通过 SOCKS5 代理 (127.0.0.1:${PORT}) 测试 Cloudflare 双栈连通性与 WARP 出口..."
        echo "--- IPv4 检测 ---"
        curl -fsS --connect-timeout 5 --max-time 10 -x "socks5h://127.0.0.1:${PORT}" https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || echo "IPv4 检测超时或未通"
        echo "--- IPv6 检测 (AI 分流核心通道) ---"
        curl -fsS --connect-timeout 5 --max-time 10 -x "socks5h://127.0.0.1:${PORT}" "https://[2606:4700:4700::1111]/cdn-cgi/trace" | grep -E '^(ip|loc|warp)=' || echo "IPv6 检测超时或未通"
        ;;

    autostart)
        require_root
        case "${2:-}" in
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
                exit 1
                ;;
        esac
        ;;

    logs)
        if command -v journalctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
            journalctl -u warp-svc -n "${2:-100}" --no-pager
        else
            echo "❌ 当前环境未运行 Systemd，无法查看 journalctl 日志。"
            exit 1
        fi
        ;;

    update)
        require_root
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "❌ 当前系统不支持 apt-get 更新！"
            exit 1
        fi
        REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/weiweibunan/xray-xhttp-warp/main}"
        SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        TMP_COMMON=""
        if [ -f "${SCRIPT_DIR}/common.sh" ]; then
            . "${SCRIPT_DIR}/common.sh"
        elif [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
            . "${SCRIPT_DIR}/scripts/common.sh"
        else
            TMP_COMMON=$(mktemp /tmp/warp-common.XXXXXX.sh)
            if ! curl -fsSL --connect-timeout 15 --retry 3 "${REPO_URL}/scripts/common.sh" -o "$TMP_COMMON"; then
                rm -f "$TMP_COMMON"
                echo "❌ 下载公共函数库 scripts/common.sh 失败！"
                exit 1
            fi
            . "$TMP_COMMON"
        fi
        rc=0
        setup_cloudflare_warp_repo && install_cloudflare_warp_headless || rc=$?
        [ -n "$TMP_COMMON" ] && rm -f "$TMP_COMMON"
        [ "$rc" -eq 0 ] || exit "$rc"
        systemctl restart warp-svc 2>/dev/null || true
        for _i in $(seq 1 15); do
            "$CLI" --accept-tos status >/dev/null 2>&1 && break
            sleep 1
        done
        "$CLI" --accept-tos connect 2>/dev/null || true
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
        echo "warp test [端口]    测试 IPv4 & IPv6 出口状态"
        echo "warp autostart on   开启开机自动连接服务"
        echo "warp autostart off  关闭开机自动连接服务"
        echo "warp logs [行数]    查看后台服务日志"
        echo "warp update         更新官方客户端软件包"
        echo "=================================================="
        ;;
esac
