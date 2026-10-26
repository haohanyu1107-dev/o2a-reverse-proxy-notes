#!/usr/bin/env bash
# codex-network-hardening.sh
# nft 暴露面收敛：只允许 loopback 访问内部服务端口，拦 eth0 入站。
#
# ★ 2026-10-26 教训：31234 那一行已回滚。
#   原因：nginx upstream 走 127.0.0.1（loopback）不受影响，
#   但【本地 OpenCode 客户端是直连 <VPS_IP>:31234 / 127.0.0.1:31234】，
#   加 drop 后本地模型立刻不能用。
#   → 加固前必须枚举所有访问方，不能只推演服务端链路。
#
# 用法：bash codex-network-hardening.sh

set -euo pipefail

TABLE="inet codex_network_hardening"

echo "[*] 重建 $TABLE"

nft delete table "$TABLE" 2>/dev/null || true

nft add table "$TABLE"
nft add chain "$TABLE" input '{ type filter hook input priority filter - 10; policy accept; }'

# ---- 需要封的内部端口（31234 已回滚，见文件头教训）----
BLOCKED_PORTS="8001 8790"

for port in $BLOCKED_PORTS; do
    nft add rule "$TABLE" input iifname "eth0" tcp dport "$port" counter drop
    echo "[+] 已封 eth0 -> tcp/$port"
done

echo
echo "[=] 当前规则："
nft list table "$TABLE"

echo
echo "[!] 31234 有意不封。若将来要重新收敛，先确认："
echo "    1) 本地 OpenCode 客户端是否还直连 31234"
echo "    2) 是否有其它客户端绕过 nginx 直连"
echo "    3) 封完后立刻本地 + 公网双向验证"
