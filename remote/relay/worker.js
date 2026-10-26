/**
 * remote/relay/worker.js —— 档② 轮询中继（Cloudflare Worker + KV）
 *
 * 解决什么问题：
 *   老 Mac 在 NAT 后面，平台（企微 / 飞书）没法主动连进来。
 *   所以中间放一个 Worker：平台把消息交给它，Mac 每 3~5 秒来取一次。
 *
 * 接口（全部要 Authorization: Bearer <RELAY_TOKEN>）：
 *   POST /push    {"from":"alice","text":"..."}      投一条待处理消息，返回 {id}
 *   GET  /pull?to=alice&limit=10                     取走该收件人的待处理消息（取走即删）
 *   POST /result  {"from":"alice","reply":"..."}     投回处理结果
 *   GET  /outbox?to=alice                            取走结果（取走即清）
 *   GET  /health                                      存活探针，不要鉴权
 *
 * 键布局（KV）：
 *   seq:<to>              该收件人下一条消息的序号（只增）
 *   q:<to>:<8位序号>       待处理消息 JSON
 *   out:<to>:<8位序号>     处理结果 JSON
 *   seen:<token-hash>      （保留，未来做速率限制）
 *
 * 已知取舍：
 *   · KV 是最终一致的，/pull 在高并发下可能重复投递。本工具的语义是
 *     「一个操作者 + 一个 Mac」，重复投递比丢消息安全（客户端可按 id 去重）。
 *   · 不做长轮询：Worker 里空转等消息既费额度也容易踩 CPU 限制。Mac 侧每
 *     3~5 秒问一次，延迟就是那个数量级 —— 和规划里说的一致。
 *   · 队列不设过期（KV 自己会淘汰久未写入的键，但别指望它当持久队列）。
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
  // 定长比较，避免按字符比较泄漏长度以外的信息（这里长度已经先比过，够了）
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

async function nextSeq(env, to) {
  const key = `seq:${to}`;
  const cur = parseInt((await env.RELAY.get(key)) || '0', 10) || 0;
  const nxt = cur + 1;
  await env.RELAY.put(key, String(nxt));
  return nxt;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (path === '/health') {
      return json({ ok: true, service: 'advisor-relay' });
    }

    if (!authOK(req, env)) {
      // 不区分「没带 token」和「token 错」；也不回显任何东西
      return json({ error: 'unauthorized' }, 401);
    }

    if (!env.RELAY) {
      return json({ error: 'KV binding RELAY missing' }, 500);
    }

    if (path === '/push' && req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
      const from = (body.from || '').toString().trim();
      const text = (body.text || '').toString();
      if (!from) return json({ error: 'from required' }, 400);
      if (!text) return json({ error: 'text required' }, 400);
      if (text.length > 8000) return json({ error: 'text too long' }, 413);
      const seq = await nextSeq(env, from);
      const id = pad(seq);
      await env.RELAY.put(`q:${from}:${id}`, JSON.stringify({
        id, from, text, at: Date.now(),
      }));
      return json({ ok: true, id });
    }

    if (path === '/pull' && req.method === 'GET') {
      const to = (url.searchParams.get('to') || '').trim();
      if (!to) return json({ error: 'to required' }, 400);
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '10', 10) || 10, 50);
      const list = await env.RELAY.list({ prefix: `q:${to}:` });
      const keys = list.keys.sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit);
      const messages = [];
      for (const k of keys) {
        const v = await env.RELAY.get(k.name);
        if (v) {
          try { messages.push(JSON.parse(v)); } catch { /* 坏数据就丢 */ }
        }
        await env.RELAY.delete(k.name);        // 取走即删
      }
      return json({ ok: true, messages });
    }

    if (path === '/result' && req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
      const from = (body.from || '').toString().trim();
      const reply = (body.reply || '').toString();
      if (!from) return json({ error: 'from required' }, 400);
      const seq = await nextSeq(env, `out:${from}`);
      const id = pad(seq);
      await env.RELAY.put(`out:${from}:${id}`, JSON.stringify({
        id, from, reply, at: Date.now(),
      }));
      return json({ ok: true, id });
    }

    if (path === '/outbox' && req.method === 'GET') {
      const to = (url.searchParams.get('to') || '').trim();
      if (!to) return json({ error: 'to required' }, 400);
      const list = await env.RELAY.list({ prefix: `out:${to}:` });
      const keys = list.keys.sort((a, b) => a.name.localeCompare(b.name));
      const replies = [];
      for (const k of keys) {
        const v = await env.RELAY.get(k.name);
        if (v) {
          try { replies.push(JSON.parse(v)); } catch { /* 坏数据就丢 */ }
        }
        await env.RELAY.delete(k.name);
      }
      return json({ ok: true, replies });
    }

    return json({ error: 'not found', path }, 404);
  },
};
