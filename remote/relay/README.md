# remote/relay —— 档② 轮询中继的 Cloudflare Worker

老 Mac 在 NAT 后面，平台没法主动连进来。这个 Worker 当中间站：平台把消息交给它，
Mac 每 3~5 秒来取一次，处理完把结果交回。

## 部署（需要你自己的 Cloudflare 账号）

```bash
cd remote/relay
npx wrangler login                       # 浏览器里授权一次
npx wrangler kv namespace create RELAY   # 记下返回的 id
#   把 id 填进 wrangler.toml 的 kv_namespaces
npx wrangler secret put RELAY_TOKEN      # 自己生成一串长随机（≥32 字符）
npx wrangler deploy
```

部署完你会得到 `https://advisor-relay.<你的子域>.workers.dev`。

**不要**把 `RELAY_TOKEN` 写进 `wrangler.toml` —— secret 只存在 Worker 那边，
Mac 这边写在 `~/.claude-agent/remote.conf` 的 `RELAY_TOKEN`。

## 本地联调（不碰你的账号）

```bash
cd remote/relay
npx wrangler dev --local --port 8787 --var RELAY_TOKEN:devtoken
```

`--local` 起的是本地 miniflare，KV 也在本地。然后：

```bash
curl -s -H 'authorization: Bearer devtoken' http://127.0.0.1:8787/health
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/push` | `{"from":"alice","text":"..."}` → `{"ok":true,"id":"00000001"}` |
| GET | `/pull?to=alice&limit=10` | 取走待处理消息（取走即删） |
| POST | `/result` | `{"from":"alice","reply":"..."}` 投回结果 |
| GET | `/outbox?to=alice` | 取走结果（取走即清） |
| GET | `/health` | 存活探针，不要鉴权 |

## 已知取舍

- **不做长轮询**：Worker 里空转等消息既费额度也容易踩 CPU 限制。延迟就是 Mac 的
  轮询间隔（3~5 秒），和规划一致。
- **KV 最终一致**：`/pull` 在高并发下可能重复投递。语义是「一个操作者 + 一台 Mac」，
  重复投递比丢消息安全（客户端可按 `id` 去重）。
- **不是持久队列**：KV 会淘汰久未写入的键。要「绝不丢」得换 Durable Object 或队列产品。
- **谁把结果发回手机**：档② 的完整形态需要平台自建应用的发送凭据（企微 corp secret /
  飞书 app token）。Worker 只把结果放进 `/outbox`，发送那一步见 `remote/README.md`。
