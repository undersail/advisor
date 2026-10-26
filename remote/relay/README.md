# remote/relay —— 档② 轮询中继的 Cloudflare Worker

老 Mac 在 NAT 后面，平台没法主动连进来。这个 Worker 当中间站：平台把消息交给它，
Mac 每 3~5 秒来取一次，处理完把结果交回。

## 部署（需要你自己的 Cloudflare 账号）

```bash
cd remote/relay
npx wrangler login                       # 浏览器里授权一次
npx wrangler kv namespace create RELAY   # 记下返回的 id
#   （真部署前把 wrangler.toml 里的 kv_namespaces 取消注释，填上你自己的 id；
#     或者把这段搬进 wrangler.local.toml 再用 --config 指过去）
npx wrangler secret put RELAY_TOKEN      # 自己生成一串长随机（≥32 字符）
npx wrangler deploy
```

部署完你会得到 `https://advisor-relay.<你的子域>.workers.dev`。

**不要**把 `RELAY_TOKEN` 写进 `wrangler.toml` —— secret 只存在 Worker 那边，
Mac 这边写在 `~/.claude-agent/remote.conf` 的 `RELAY_TOKEN`。

## 本地联调（完全不碰 Cloudflare 账号）

```bash
cd remote/relay
cp wrangler.local.toml.example wrangler.local.toml      # 里面只有全零占位 id
npx wrangler dev --local --config wrangler.local.toml --port 8811 --var RELAY_TOKEN:devtoken
```

`--local` 起的是本地 miniflare，KV 也在本地，不需要登录、不产生任何费用。

```bash
curl -s -H 'authorization: Bearer devtoken' http://127.0.0.1:8811/health
```

`wrangler.local.toml` 在 `.gitignore` 里 —— 你在里面填自己的 KV 命名空间 id 也不会被提交。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/push` | `{"from":"alice","text":"..."}` → `{"ok":true,"id":"00000001"}` |
| GET | `/pull?to=alice&limit=10` | 取走待处理消息（取走即删） |
| POST | `/result` | `{"from":"alice","reply":"..."}` 投回结果 |
| GET | `/outbox?to=alice` | 取走结果（取走即清） |
| GET | `/health` | 存活探针，不要鉴权 |

## 这是一台「你自己部署」的中继

本项目**不提供任何托管服务**，仓库里也不含任何人的 Cloudflare 账号、令牌、
KV 命名空间 id 或 workers.dev 子域。要用中继，就得你自己：

1. 有自己的 Cloudflare 账号（免费额度足够）；
2. `wrangler login` 授权你自己的账号；
3. 建自己的 KV、自己 `secret put RELAY_TOKEN`、自己 deploy；
4. 把得到的地址填进**你自己的** `~/.claude-agent/remote.conf`。

主配置 `wrangler.toml` 里的 `kv_namespaces` 是**故意留空注释掉**的：不填就部署
不上。宁可部署报错，也不要让仓库里出现一个「看起来能用」的、属于别人的 id。

## 已知取舍

- **不做长轮询**：Worker 里空转等消息既费额度也容易踩 CPU 限制。延迟就是 Mac 的
  轮询间隔（3~5 秒），和规划一致。
- **KV 最终一致**：`/pull` 在高并发下可能重复投递。语义是「一个操作者 + 一台 Mac」，
  重复投递比丢消息安全（客户端可按 `id` 去重）。
- **不是持久队列**：KV 会淘汰久未写入的键。要「绝不丢」得换 Durable Object 或队列产品。
- **谁把结果发回手机**：档② 的完整形态需要平台自建应用的发送凭据（企微 corp secret /
  飞书 app token）。Worker 只把结果放进 `/outbox`，发送那一步见 `remote/README.md`。
