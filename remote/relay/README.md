# remote/relay —— 档② 轮询中继的 Cloudflare Worker（Durable Object 队列）

老 Mac 在 NAT 后面，平台没法主动连进来。这个 Worker 当中间站：平台侧把消息交给它，
Mac 每 3~5 秒来取一次，处理完把结果交回。

**队列后端是 Durable Object，不是 KV。** 理由：

| 需求 | KV | Durable Object |
|---|---|---|
| 取走即删要原子 | list → get → delete 三步，会重复投递 | 单实例串行，天然原子 |
| push 完立刻能 pull 到 | 最终一致，跨地区可能延迟到分钟级 | 强一致 |
| 序号只增 | 读-改-写会丢更新（并发 push 重号） | input gate 串行化，不重号 |

## 部署（需要你自己的 Cloudflare 账号）

```bash
cd remote/relay
npx wrangler login                  # 浏览器里授权一次
npx wrangler deploy                 # DO 不用手建、不用填 id，直接部署
npx wrangler secret put RELAY_TOKEN # 自己生成一串长随机（≥32 字符）
```

部署完你会得到 `https://advisor-relay.<你的子域>.workers.dev`。

**不需要** `kv namespace create`，仓库里也不会有任何 id —— DO 的实例由
`idFromName('main')` 在运行时算出来，`wrangler.toml` 里只有绑定名和迁移声明。

**不要**把 `RELAY_TOKEN` 写进 `wrangler.toml`：secret 只放在 Worker 那边，
用它的那台机器写在 `~/.claude-agent/remote.conf` / `platform.conf` 里。

## 本地联调（完全不碰 Cloudflare 账号、不花钱）

```bash
cd remote/relay
npx wrangler dev --local --port 8811 --var RELAY_TOKEN:devtoken
curl -s http://127.0.0.1:8811/health
# {"ok":true,"service":"advisor-relay","backend":"durable-object"}
```

队列逻辑本身（取走即删 / 先进先出 / 序号只增 / 鉴权）有不需要 wrangler 的测试：

```bash
node scripts/test-relay-do.mjs     # 真跑 remote/relay/worker.js，21 项
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/push` | `{"from":"alice","text":"..."}` → `{"ok":true,"id":"00000001"}` |
| GET | `/pull?to=alice&limit=10` | 取走待处理消息（取走即删） |
| POST | `/result` | `{"from":"alice","reply":"..."}` 投回结果 |
| GET | `/outbox?to=alice` | 取走结果（取走即清） |
| GET | `/health` | 存活探针，不要鉴权 |

除 `/health` 外都要 `Authorization: Bearer <RELAY_TOKEN>`；没配 token 时**一律拒绝**（fail-closed）。

## 两种部署形态

**A. 一台机器全包**（自己有公网入口/穿透）：`platform.pl` 和网关在同一台机器上，
中继只是可选备份路径 —— 配了 `RELAY_URL` 才走它。

**B. 公网小机器 + 家里 Mac**（NAT 场景）：

```
手机 → 企微/飞书 → 公网机器上的 platform.pl → /push → 中继 DO
                                                      ↓ 每 3~5 秒拉取
                                          家里 Mac 的 gateway.pl --poll
                                                      ↓ 处理完
                                  platform.pl 取 /outbox → 推回手机
```

公网机器上的 `platform.conf`：

```
RELAY_URL = https://advisor-relay.<你的子域>.workers.dev
RELAY_TOKEN = <与 secret put 的一致>
RELAY_POLL = 3
```

配了 `RELAY_URL` 后 `platform.pl` **不再本地起网关**，只做「投递 + 取结果」。
家里 Mac 那边：

```bash
perl remote/gateway.pl --poll          # 从队列取消息，处理，把结果写回
```

## 这是一台「你自己部署」的中继

本项目**不提供任何托管服务**，仓库里不含任何人的 Cloudflare 账号、令牌或子域。
要用中继就得你自己注册、自己 `wrangler login`、自己 deploy，把地址填进自己的配置。

## 已知取舍

- **不做长轮询**：Worker 里空转等消息既费额度也容易踩 CPU 限制。延迟就是轮询间隔
  （3~5 秒）。
- **只用一个 DO 实例**（`idFromName('main')`）：个人自用场景串行处理最省心；真要多租户
  再按 mailbox 拆实例。
- **队列不设过期**：DO 存储会持久保留，取走才删。崩在中间的消息会留在队列里，下次
  拉取会再看到（宁可重复处理，也不丢）。
- **结果推回手机由 `platform.pl` 负责**：它持有平台发送凭据（企微 corp secret / 飞书
  app token）；Worker 只负责搬消息，不碰凭据。
