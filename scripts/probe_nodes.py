#!/usr/bin/env python3
"""
probe_nodes.py — mihomo 节点批量探测：出口 IP + opencode.ai 额度状态

用途：opencode2api 上游 opencode.ai 免费额度按【出口 IP】计。
     遍历 mihomo 节点，找出「出口 IP 正常 + 额度未耗尽」的节点。

判定依据（关键）：
    HTTP 429 + "FreeUsageLimit"  -> 该出口 IP 额度已耗尽，换
    HTTP 401 + "Missing API key" -> 该出口 IP 额度是好的（只是没带 key），可用
    其它                          -> 节点不通 / 路径错

用法：
    export MIHOMO_SECRET='<external-controller secret>'
    python3 probe_nodes.py                      # 探测全部节点
    python3 probe_nodes.py --limit 20           # 只探前 20 个
    python3 probe_nodes.py --group "🚀 节点选择"  # 指定组名

注意：必须让 curl 走代理，且【不要】加 --noproxy '*'，
      它会把 -x 指定的代理也一起废掉（本次实战踩坑）。
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.parse

MIHOMO_API = "http://127.0.0.1:9090"
# external-controller secret 从环境变量读，别硬编码进仓库
MIHOMO_SECRET = os.environ.get("MIHOMO_SECRET", "")
SELECTOR = "🚀 节点选择"
DEFAULT_GROUP = "🚀 节点选择"
SOCKS5 = "socks5h://127.0.0.1:7890"
UPSTREAM = "https://opencode.ai/zen/v1/chat/completions"
IP_ECHO = "https://api.ipify.org"


def api(path):
    """调 mihomo external-controller API"""
    url = f"{MIHOMO_API}{path}"
    out = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {MIHOMO_SECRET}",
         "--max-time", "15", url],
        capture_output=True, text=True,
    )
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def list_nodes():
    r = api(f"/proxies/{urllib.parse.quote(SELECTOR)}")
    if not r or "all" not in r:
        print(f"[!] 拿不到组 {SELECTOR} 的节点列表", file=sys.stderr)
        sys.exit(1)
    return r["all"]


def select_node(name):
    body = json.dumps({"name": name})
    subprocess.run(
        ["curl", "-s", "-X", "PUT",
         "-H", f"Authorization: Bearer {MIHOMO_SECRET}",
         "-H", "Content-Type: application/json",
         "-d", body, "--max-time", "15",
         f"{MIHOMO_API}/proxies/{urllib.parse.quote(SELECTOR)}"],
        capture_output=True, text=True,
    )


def curl_via_proxy(url, extra=None):
    """走 socks5 代理请求。注意：不能加 --noproxy。"""
    cmd = ["curl", "-s", "-x", SOCKS5, "--max-time", "25", "-o", "/dev/null",
           "-w", "%{http_code}"]
    if extra:
        cmd += extra
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout.strip()


def probe_one(node):
    select_node(node)

    ip = subprocess.run(
        ["curl", "-s", "-x", SOCKS5, "--max-time", "20", IP_ECHO],
        capture_output=True, text=True,
    ).stdout.strip()

    code = curl_via_proxy(UPSTREAM, [
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer public",
        "-d", json.dumps({"model": "glm-5.3-flash",
                          "messages": [{"role": "user", "content": "hi"}]}),
    ])

    if code == "429":
        verdict = "额度耗尽"
    elif code in ("401", "400"):
        verdict = "额度可用"
    elif code in ("000", ""):
        verdict = "节点不通"
    else:
        verdict = f"HTTP {code}"

    return ip, code, verdict


def main():
    global SELECTOR

    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--group", default=DEFAULT_GROUP)
    args = ap.parse_args()

    SELECTOR = args.group

    nodes = list_nodes()
    if args.limit:
        nodes = nodes[:args.limit]
    print(f"[*] 共 {len(nodes)} 个节点，开始探测（每个 15-40s，请耐心）\n")

    good = []
    for i, node in enumerate(nodes, 1):
        try:
            ip, code, verdict = probe_one(node)
        except Exception as e:                       # noqa: BLE001
            print(f"[{i:3d}/{len(nodes)}] {node} | 异常 {e}")
            continue
        print(f"[{i:3d}/{len(nodes)}] {node} | ip={ip or '-'} | {verdict}")
        if verdict == "额度可用":
            good.append((node, ip))

    print(f"\n[=] 可用节点 {len(good)} 个：")
    for node, ip in good:
        print(f"    OK   {node} -> {ip}")


if __name__ == "__main__":
    main()
