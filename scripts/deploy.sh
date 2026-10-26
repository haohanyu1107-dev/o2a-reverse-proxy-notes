#!/usr/bin/env bash
# deploy.sh — 按 README 流程一键复现（在【网关机 VPS】上以 root 运行）
#
# 用法：
#   export MIHOMO_SECRET='<external-controller secret>'
#   bash deploy.sh --check        # 只做前置检查，不改任何配置
#   bash deploy.sh --apply        # 检查 + 写入 socks5 配置 + 重启 o2a
#
# 设计原则：默认只读。不加 --apply 绝不改线上配置。

set -uo pipefail

O2A_DIR="${O2A_DIR:-/opt/opencode2api}"
CFG="$O2A_DIR/data/config.json"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:7890}"
PROXY_NAME="${PROXY_NAME:-mihomo-7890}"
UPSTREAM_PROBE="https://opencode.ai/zen/v1/chat/completions"
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"

MODE="check"
[ "${1:-}" = "--apply" ] && MODE="apply"

pass=0; fail=0
ok()   { echo "  ✅ $*"; pass=$((pass+1)); }
bad()  { echo "  ❌ $*"; fail=$((fail+1)); }
info() { echo "  ·  $*"; }

echo "=============================================="
echo " o2a 反代部署复现 · 模式=$MODE"
echo "=============================================="

# ---------- 1. 前置检查 ----------
echo
echo "[1/6] 前置检查"

command -v curl >/dev/null 2>&1 && ok "curl 存在" || bad "curl 缺失"
command -v nft  >/dev/null 2>&1 && ok "nft 存在"  || info "nft 不存在（若不用防火墙收敛可忽略）"

if [ -f "$CFG" ]; then
    ok "配置文件存在: $CFG"
    python3 -c "import json,sys; json.load(open('$CFG'))" 2>/dev/null \
        && ok "配置文件是合法 JSON" || bad "配置文件 JSON 损坏"
else
    bad "配置文件不存在: $CFG"
fi

# ---------- 2. mihomo 存活 ----------
echo
echo "[2/6] mihomo 存活"
if [ -z "${MIHOMO_SECRET:-}" ]; then
    bad "MIHOMO_SECRET 未设置（export MIHOMO_SECRET='...'）"
else
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer $MIHOMO_SECRET" "$MIHOMO_API/version")
    [ "$code" = "200" ] && ok "mihomo API 可达（$code）" || bad "mihomo API 不可达（$code）"
fi

ss -lnt 2>/dev/null | grep -q ':7890 ' && ok "7890 端口在监听" || bad "7890 端口未监听"

# ---------- 3. SOCKS5 通道 ----------
echo
echo "[3/6] SOCKS5 能否出网"
# 关键：先确认端口在监听，否则环境里的 HTTPS_PROXY 会兜底让 curl "看起来成功"
if ss -lnt 2>/dev/null | grep -q ':7890 '; then
    out_ip=$(curl -s -x "socks5h://$SOCKS_ADDR" --max-time 20 \
        --noproxy 'api.ipify.org' https://api.ipify.org 2>/dev/null)
else
    out_ip=""
    info "7890 未监听，跳过 SOCKS5 出网测试（避免环境代理误判）"
fi

if [ -n "$out_ip" ]; then
    ok "SOCKS5 出网正常，出口 IP: ${out_ip:0:7}…"
else
    bad "SOCKS5 出网失败（检查 7890 / 节点是否可用）"
fi
# 直连出口做对比
direct_ip=$(curl -s --noproxy '*' --max-time 15 https://api.ipify.org 2>/dev/null)
if [ -n "$out_ip" ] && [ -n "$direct_ip" ]; then
    if [ "$out_ip" = "$direct_ip" ]; then
        info "注意：代理出口与本机出口相同，节点可能没生效"
    else
        ok "代理出口与本机出口不同，换 IP 生效"
    fi
fi

# ---------- 4. 上游额度探测 ----------
echo
echo "[4/6] 上游额度探测（401=可用 / 429=耗尽）"
# 注意：--noproxy 只对列出的主机生效，不能写 '*'（那样会把 -x 也一并废掉）
NP="opencode.ai,api.ipify.org,127.0.0.1,localhost"
if ss -lnt 2>/dev/null | grep -q ':7890 '; then
    resp=$(curl -s -x "socks5h://$SOCKS_ADDR" --noproxy "$NP" \
        -o /tmp/_o2a_probe.json -w '%{http_code}' --max-time 30 \
        -X POST "$UPSTREAM_PROBE" \
        -H 'Content-Type: application/json' \
        -H 'Authorization: Bearer public' \
        -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"say hi"}]}' 2>/dev/null)
else
    resp="000"
    info "7890 未监听，跳过额度探测"
fi
case "$resp" in
    401|400) ok "HTTP $resp → 该出口额度可用" ;;
    429)     bad "HTTP 429 → 该出口额度已耗尽，需换节点" ;;
    000|"")  bad "无响应 → 节点不通或未测试" ;;
    *)       info "HTTP $resp（非预期，看响应体）" ;;
esac

# ---------- 5. o2a 当前出口配置 ----------
echo
echo "[5/6] o2a 配置现状"
if [ -f "$CFG" ]; then
    python3 - "$CFG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
proxies = cfg.get("socks5_proxies") or []
active  = cfg.get("active_socks5") or "(未设置)"
print(f"  ·  socks5_proxies 数量: {len(proxies)}")
for p in proxies:
    print(f"       - {p.get('name')} -> {p.get('addr')}")
print(f"  ·  active_socks5: {active}")
print(f"  ·  socks5_paid_direct: {cfg.get('socks5_paid_direct')}")
if proxies:
    print("  ✅ 已配置 socks5 出口")
else:
    print("  ❌ 未配置 socks5 出口（这就是 429 的根因）")
PY
fi

# ---------- 6. 反代链路 ----------
echo
echo "[6/6] 反代链路"
local_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:31234/health)
[ "$local_code" = "200" ] && ok "o2a 本地 /health = 200" || bad "o2a 本地 /health = $local_code"

# ---------- 结论 ----------
echo
echo "=============================================="
echo " 检查结果：通过 $pass · 失败 $fail"
echo "=============================================="

if [ "$MODE" = "apply" ]; then
    echo
    echo "[*] 开始应用配置…"
    if [ ! -f "$CFG" ]; then
        echo "❌ 配置文件不存在，中止"; exit 1
    fi
    ts=$(date +%Y%m%d-%H%M%S)
    cp "$CFG" "$CFG.bak-before-socks5-$ts" && echo "  ✅ 已备份: config.json.bak-before-socks5-$ts"

    python3 - "$CFG" "$PROXY_NAME" "$SOCKS_ADDR" <<'PY'
import json, sys
path, name, addr = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path))
cfg.setdefault("socks5_proxies", [])
if not any(p.get("name") == name for p in cfg["socks5_proxies"]):
    cfg["socks5_proxies"].append({"name": name, "addr": addr,
                                  "username": "", "password": ""})
cfg["active_socks5"] = addr
cfg.setdefault("socks5_paid_direct", False)
cfg.setdefault("socks5_sticky", True)
json.dump(cfg, open(path, "w"), ensure_ascii=False, indent=2)
print("  ✅ 配置已写入（active_socks5=Addr，上游按 Addr 匹配）")
PY

    echo "  [*] 重启 o2a 容器…"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode2api; then
        docker restart opencode2api >/dev/null 2>&1 && echo "  ✅ 容器已重启"
        sleep 8
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:31234/health)
        [ "$c" = "200" ] && echo "  ✅ 重启后 /health = 200" || echo "  ❌ 重启后 /health = $c"
    else
        echo "  ⚠️  未找到 opencode2api 容器，请手动重启"
    fi
else
    echo
    echo "提示：确认前置检查通过后，加 --apply 才会真正改配置。"
fi

[ "$fail" -gt 0 ] && exit 1
exit 0
