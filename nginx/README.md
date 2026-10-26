# nginx 反代片段说明（脱敏版）

实际生效的配置在 VPS `/etc/nginx/`，本目录只留结构与关键点（无真实 IP / 密钥 / 证书名）。

## 架构

```
公网 o2a.<你的域名>
   │
   ▼
Cloudflare（proxied，A 记录 -> VPS 公网 IP）
   │
   ▼
CF Worker "o2a-gate"  ← 强制 API Key（KV: O2A_KEYS）
   │
   ▼
源站 nginx :443
   │  ├─ X-O2A-Origin 双头校验（不对 -> 444）
   │  ├─ basic auth（/admin、/api/**）
   │  └─ 限流 zone（o2aadmin / o2aapi / o2aconn）
   ▼
upstream 127.0.0.1:31234  →  o2a 容器（network_mode: host）
```

## 关键点

| 项 | 说明 |
|---|---|
| SSE | `/v1/**` 必须关 buffering（`proxy_buffering off`），否则流式响应卡住 |
| admin | `/admin`、`/api/**` → 独立片段，basic auth + 限流 |
| 默认 | 根路径 404；未知 Host 由 `00-default-deny.conf` 444 兜底 |
| zone | `/etc/nginx/conf.d/00-o2a-zones.conf` 独立文件，nginx.conf 加一行 include |
| 证书 | 用 CF universal SSL 覆盖的通配符证书即可，别重复签 |

## 坑（别再踩）

1. **htpasswd 必须带 `-b`**，否则进交互式 stdin 卡住。
2. **`sed 0,/http{/` 会把 zone 插到 `http{}` 外** → 用独立 conf.d 文件 + include。
3. **别用 `> 被 nginx master 打开着的配置文件`**：master 持旧 fd，截断后按旧偏移写回，
   文件变 0 字节或半截。**一律写 /tmp 再 `mv`。**
4. **heredoc 在某些执行上下文被吞**（文件 0 字节、站点缺 listen）→ 用 `printf '%s\n'` 逐行
   或 Python 生成。
5. **`X-O2A-Origin` 必须内联进 server 块**，放 include 片段不顶用。
6. fail2ban 在 Debian 上的 regex 兼容性差，只吃 `.*?` / `[A-Z]+` / `[^"]+`；
   `\S`、`[^]]`、`\d`、`\[` 可能全部匹配失败（务必 A/B 实测）。
   可用：`^<HOST> .*?\] "[A-Z]+ [^"]+" 401`。
7. Debian 默认 `backend = systemd`，jail 的 `logpath` 被无视 → 显式 `backend = polling`。
8. `ignoreself` 默认 true，本机自测封禁会被跳过 → 测试时临时关，测完撤。

## fail2ban jail

| jail | 匹配 | 阈值 |
|---|---|---|
| `opencode2api-auth` | 401 | 6 次 / 10min |
| `opencode2api-404` | 403 / 404 / 429 | 20 次 / 5min |

## Cloudflare 侧

- Worker 强制 API Key，KV 存 key 列表。
- **坑**：`PUT /workers/scripts/{s}/bindings` 用 API Token 会报权限错（10405），
  变量只能写进上传 multipart 的 `metadata.bindings`。
- **坑**：漏了 `main_module` 会把 env 清空（表现为 Worker 里读不到口令变量，全站 401）。
- **坑**：Worker 抛异常 → `error code: 1101`（CF 吞异常），必须自带 try/catch 返回 502。
- WAF 自定义 block 默认返回 **403**（吃 CF 请求量），想省量要用 **444**。
- **坑**：`PUT /rulesets/default` 对 zone 级 entrypoint 不建集，
  要 `POST /zones/{z}/rulesets` 带 `kind:zone, phase:http_request_firewall_custom` 一次建好。
- Cloudflare Access / Zero Trust 可能无权限（403），管理端可自己用 Bearer 口令实现。

## 本次（10-26）与 nginx 的关系

**无关**。本次故障根因是 opencode.ai 上游额度按出口 IP 耗尽，
nginx 这四层防护全程正常，问题出在 o2a 没配 socks5 出口。
反代链路本身没改，改的是 o2a 的 `config.json`（见 `../config/o2a-config.json`）。
