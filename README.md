# opencode2api SOCKS5 出口配置指南

[opencode2api](https://github.com/6kmfi6hp/opencode2api)（下称 **o2a**）把
OpenCode 免费模型翻译成 OpenAI 兼容 API。它的免费额度**按出口 IP 计**——服务器
只有一个公网 IP，耗尽后全部模型 429。

本仓库给出解法：**让 o2a 的出站流量走本机 mihomo 的 SOCKS5，用代理节点池换出口 IP**。

## 从零部署 o2a（已跑通可跳过）

需要：一台境外 VPS、Docker、本机已装 [mihomo](https://wiki.metacubex.one/)。

```bash
mkdir -p /opt/opencode2api/data

docker run -d --name opencode2api --restart unless-stopped \
  --network host \
  -v /opt/opencode2api/data:/data \
  ghcr.io/6kmfi6hp/opencode2api:latest
```

配置文件在宿主机 `/opt/opencode2api/data/config.json`（容器内 WorkingDir=/data），
首启自动生成默认配置，随后按下一节接入 SOCKS5。

上游免费模型开箱即用（匿名通道，额度限制见下文注意事项第 2 条）；
要稳定高配额，需自备 OpenCode 账号/key 写入 `config.json` 的 `key_pool`。

```
客户端 ──> nginx ──> opencode2api (127.0.0.1:31234)
                          │
                          │ socks5 127.0.0.1:7890   ← config.json 里配
                          ▼
                    mihomo 节点池（140+ 节点轮换出口）
                          │
                          ▼
                     opencode.ai
```

## 前置条件

- 一台已跑通 o2a 的服务器（Docker `network_mode: host`，监听 31234）
- 本机已装 [mihomo](https://wiki.metacubex.one/)，且有一个可用的代理组
- 确认 mixed-port 可用（HTTP + SOCKS5 同端口）：

```bash
curl -x socks5h://127.0.0.1:7890 https://api.ipify.org
# 返回节点出口 IP 而非本机 IP = 代理通道正常
```

## 配置步骤

### 1. 备份现有配置

```bash
cp /opt/opencode2api/data/config.json \
   /opt/opencode2api/data/config.json.bak-$(date +%Y%m%d-%H%M%S)
```

### 2. 写入 socks5 出口

编辑 `/opt/opencode2api/data/config.json`，合并以下字段（完整示例见
[`config/o2a-config.json`](config/o2a-config.json)）：

```json
{
  "socks5_proxies": [
    { "addr": "127.0.0.1:7890", "username": "", "password": "", "name": "mihomo-7890" }
  ],
  "active_socks5": "127.0.0.1:7890",
  "socks5_paid_direct": false,
  "socks5_sticky": true
}
```

| 字段 | 说明 |
|---|---|
| `socks5_proxies[]` | 候选出口列表，`{name, addr, username, password}` |
| `active_socks5` | 填 **`socks5_proxies[].addr` 的值**（上游按 Addr 匹配，填 name 会**静默直连**失效）；填 `"__round_robin__"` 可在多个出口间轮询 |
| `socks5_paid_direct` | 付费模型是否绕过代理直连 |
| `socks5_sticky` | 会话粘连（同会话固定同一出口） |

> 这些字段没写在官方文档里，是从 o2a 二进制的 json tag 里扒出来的：
> `socks5_proxies` / `active_socks5` / `socks5_paid_direct` / `socks5_sticky`。

### 3. 重启加载

```bash
docker restart opencode2api
# 或调 o2a 的 /api/reload
```

### 4. 验证

```bash
curl http://127.0.0.1:31234/health       # OK（部分版本返回 {"healthy":true}，判 2xx 即可）
curl http://127.0.0.1:31234/v1/models    # 模型列表
```

### 5.（可选）探测各节点上游可用性

[`scripts/probe_nodes.py`](scripts/probe_nodes.py) 逐个节点测出口 IP 与
上游额度状态（401 = 该出口额度可用，429 = 耗尽，换节点）：

```bash
export MIHOMO_SECRET='<external-controller secret>'
python3 scripts/probe_nodes.py                # 全部节点
python3 scripts/probe_nodes.py --limit 20     # 前 20 个
python3 scripts/probe_nodes.py --group "🚀 节点选择"
```

[`scripts/deploy.sh`](scripts/deploy.sh) 是一键部署后校验（`--check` 只读体检，
`--apply` 才改配置），覆盖 mihomo 存活、SOCKS5 出网、上游额度、o2a 健康。

## 注意事项

1. **测出口 IP 时清掉环境代理**。如果 shell 里有 `https_proxy` 环境变量，
   `curl -x socks5h://...` 失败会被它兜底"看似成功"，得出代理失效的误判：

   ```bash
   env -u http_proxy -u https_proxy curl -x socks5h://127.0.0.1:7890 https://api.ipify.org
   ```

   同理 `curl --noproxy '*'` 会把 `-x` 一起废掉，只对目标域名写白名单：
   `--noproxy 'api.ipify.org'`。

2. **限流根因判断**。`Bearer public` 匿名通道的额度是全局+IP 双重限制，
   换 IP 只解 IP 那一半；若配了 `key_pool`（`enabled: true`）则按 key 计。
   先分清打的是哪条通道，再决定换 IP 还是换 key。

3. **`network_mode: host` 下端口收不了**。o2a 实际绑 `0.0.0.0:31234`，
   compose 里改端口映射无效，只能靠防火墙（nft/iptables）限制 `eth0` 入站。
   收紧前先确认没有客户端绕过反代直连该端口。

4. **mihomo listener 想固定出口组**时，在 `listeners:` 里给 socks 入站加
   `proxy: <组名>`；改 `GLOBAL` 组的指向不影响 listener 绑定。

## License

MIT
