/**
 * remote/relay/worker.js —— 档② 轮询中继（Cloudflare Worker + Durable Object）
 *
 * 解决什么问题：
 *   老 Mac 在 NAT 后面，平台（企微 / 飞书）没法主动连进来。
 *   所以中间放一个 Worker：平台侧把消息交给它，Mac 每 3~5 秒来取一次。
 *
 * 为什么用 Durable Object 而不是 KV：
 *   · 「取走即删」在 KV 里是 list → get → delete 三步，没有原子性，会重复投递；
 *   · KV 是最终一致的（跨地区可见延迟最长约 60 秒），刚 push 完立刻 pull 可能读不到，
 *     这会把「5 秒级延迟」的目标直接毁掉；
 *   · 序号用 KV 需要读-改-写，天然有丢更新（两个请求同时 push 会拿到同一个序号）。
 *   DO 是单实例串行 + 强一致 + 事务存储，队列语义正是它的靶心。
 *
 * 接口（全部要 Authorization: Bearer ***，/health 除外）：
 *   POST /push    {"from":"alice","text":"..."}      投一条待处理消息，返回 {id}
 *   GET  /pull?to=alice&limit=10                     取走该收件人的待处理消息（取走即删）
 *   POST /result  {"from":"alice","reply":"..."}     投回处理结果
 *   GET  /outbox?to=alice                            取走结果（取走即清）
 *   GET  /health                                     存活探针，不要鉴权
 *
 * 存储布局（DO storage，键有序）：
 *   seq:q:<to>            该收件人下一条消息的序号（只增）
 *   q:<to>:<8 位序号>      待处理消息 JSON
 *   out:<to>:<8 位序号>    处理结果 JSON
 *
 * 已知取舍：
 *   · 只用一个 DO 实例（idFromName('main')）：个人自用串行处理最省心，也顺手拿到原子性；
 *     真要多租户再按 mailbox 拆实例。
 *   · 不做长轮询：Worker 里空转等消息既费额度也容易踩 CPU 限制。
 */

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

function pad(n) {
  return String(n).padStart(8, '0');
}

function authOK(req, env) {
  const want = env.RELAY_TOKEN;
  if (!want) return false;                     // 没配 token 就没人能用（fail-closed）
  const got = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (got.length !== want.length) return false;
  // 定长比较，避免按字符比较提前返回
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

// ------------------------------------------------------------------ Durable Object
export class RelayRoom {
  constructor(state) {
    this.storage = state.storage;
  }

  // 单实例串行：读-改-写在两个 await 之间不会被别的请求插进来（input gate 挂住）
  async nextSeq(kind, to) {
    const key = `seq:${kind}:${to}`;
    const cur = parseInt((await this.storage.get(key)) || '0', 10) || 0;
    const nxt = cur + 1;
    await this.storage.put(key, String(nxt));
    return nxt;
  }

  async takePrefix(prefix, limit) {
    const map = await this.storage.list({ prefix });
    const keys = [...map.keys()].sort();            // 定长序号：字典序即先进先出
    const out = [];
    for (const k of keys.slice(0, limit)) {
      const v = await this.storage.get(k);
      if (v) {
        try { out.push(JSON.parse(v)); } catch { /* 坏数据就丢 */ }
      }
      await this.storage.delete(k);                  // 取走即删（同一实例内原子）
    }
    return out;
  }

  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === '/push') {
      const body = await req.json();
      const seq = await this.nextSeq('q', body.from);
      const id = pad(seq);
      await this.storage.put(`q:${body.from}:${id}`, JSON.stringify({
        id, from: body.from, text: body.text, at: Date.now(),
      }));
      return json({ ok: true, id });
    }

    if (path === '/pull') {
      const to = url.searchParams.get('to');
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '10', 10) || 10, 50);
      return json({ ok: true, messages: await this.takePrefix(`q:${to}:`, limit) });
    }

    if (path === '/result') {
      const body = await req.json();
      const seq = await this.nextSeq('out', body.from);
      const id = pad(seq);
      await this.storage.put(`out:${body.from}:${id}`, JSON.stringify({
        id, from: body.from, reply: body.reply, at: Date.now(),
      }));
      return json({ ok: true, id });
    }

    if (path === '/outbox') {
      const to = url.searchParams.get('to');
      return json({ ok: true, replies: await this.takePrefix(`out:${to}:`, 50) });
    }

    return json({ error: 'not found', path }, 404);
  }
}

// ------------------------------------------------------------------ Worker 路由
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (path === '/health') {
      return json({ ok: true, service: 'advisor-relay', backend: 'durable-object' });
    }

    if (!authOK(req, env)) {
      // 不区分「没带 token」和「token 错」；也不回显任何东西
      return json({ error: 'unauthorized' }, 401);
    }

    if (!env.RELAY) {
      return json({ error: 'Durable Object binding RELAY missing' }, 500);
    }

    // 入参校验在 Worker 层做一次，DO 里不重复判断
    let inner = null;
    if (path === '/push' || path === '/result') {
      if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
      let body;
      try { body = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
      const from = (body.from || '').toString().trim();
      if (!from) return json({ error: 'from required' }, 400);
      if (path === '/push') {
        const text = (body.text || '').toString();
        if (!text) return json({ error: 'text required' }, 400);
        if (text.length > 8000) return json({ error: 'text too long' }, 413);
        inner = { from, text };
      } else {
        inner = { from, reply: (body.reply || '').toString() };
      }
    } else if (path === '/pull' || path === '/outbox') {
      if (req.method !== 'GET') return json({ error: 'method not allowed' }, 405);
      const to = (url.searchParams.get('to') || '').trim();
      if (!to) return json({ error: 'to required' }, 400);
    } else {
      return json({ error: 'not found', path }, 404);
    }

    const id = env.RELAY.idFromName('main');       // 个人自用：一个实例串行处理
    const stub = env.RELAY.get(id);
    // ★ 必须带上 query（?to= / ?limit=）：只转发 pathname 的话 DO 收不到 to，
    //   /pull 会按 `q:undefined:` 前缀去查，永远返回空 —— 队列看着正常其实收不到消息。
    const target = new URL(url.pathname + url.search, 'https://relay');
    if (inner) {
      return stub.fetch(new Request(target.toString(), {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(inner),
      }));
    }
    return stub.fetch(new Request(target.toString(), { method: 'GET' }));
  },
};
