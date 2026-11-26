#!/bin/bash
# ==============================================================================
# Cloudflare WARP 兼容入口包装脚本（核心逻辑已统一合并至 /usr/local/bin/xm）
# ==============================================================================

if [ -x /usr/local/bin/xm ]; then
    if [ "$#" -eq 0 ]; then
        exec /usr/local/bin/xm warp help
    fi
    exec /usr/local/bin/xm warp "$@"
fi

echo "❌ 未检测到 /usr/local/bin/xm，请重新运行 install.sh 安装管理脚本！" >&2
exit 1
