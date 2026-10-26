/**
 * scripts/test-relay-do.mjs —— 中继队列（Durable Object）逻辑测试
 *
 * 为什么这样测：
 *   · 队列语义（取走即删、先进先出、序号只增）全是 worker.js 里的逻辑，
 *     只要有 storage 就能验，不需要 Cloudflare 账号、不需要 wrangler。
 *   · 直接 import 真实的 worker.js（不是抄一份），所以测的就是要部署的东西。
 *   · 真连 Cloudflare 的那一步只能你本机 `npx wrangler dev --local` 验，
 *     测不到的部分这里不假装测到。
 *
 * 运行：node scripts/test-relay-do.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const workerPath = path.join(here, '..', 'remote', 'relay', 'worker.js');

// worker.js 是 ESM，但仓库里没有 package.json type=module（不想为它改整个仓库），
// 所以读原文、把 export 摘掉，再用 data URL 当模块加载。测的仍是同一个文件。
const src = fs.readFileSync(workerPath, 'utf8');
const patched = src
  .replace(/^export class /m, 'class ')
  .replace(/^export default /m, 'const __worker = ') +
  '\nexport { RelayRoom, __worker as default };\n';
const mod = await import('data:text/javascript;base64,' +
  Buffer.from(patched, 'utf8').toString('base64'));
const { RelayRoom } = mod;
const worker = mod.default;

let pass = 0;
const fails = [];

function check(name, ok, detail) {
  if (ok) {
    pass++;
    console.log('  ok   ' + name);
  } else {
    fails.push(name);
    console.log('  FAIL ' + name + (detail ? ' | ' + detail : ''));
    // CI 里让失败项变成 annotation，不用登录也能看到（GitHub Actions 会收集）
    console.log('::error::中继队列测试失败: ' + name + (detail ? ' | 细节: ' + detail : ''));
  }
}

// ---------------------------------------------------------------- 假 storage
function makeStorage() {
  const map = new Map();
  return {
    map,
    async get(k) { return map.has(k) ? map.get(k) : undefined; },
    async put(k, v) { map.set(k, v); },
    async delete(k) { const had = map.has(k); map.delete(k); return had; },
    async list({ prefix = '', limit = 1000 } = {}) {
      const out = new Map();
      for (const k of [...map.keys()].sort()) {
        if (k.startsWith(prefix)) out.set(k, map.get(k));
      }
      return out;
    },
  };
}

function makeEnv(token = 'devtoken') {
  const storage = makeStorage();
  const instance = new RelayRoom({ storage });
  // ★ 忠实模拟 Durable Object 的 input gate：同一个实例上的请求串行处理，
  //   一个请求在 await 存储的时候，别的请求不会被插进来。
  //   如果没有这个性质，worker.js 里「读序号 → 写序号」就会丢更新（KV 正是如此）。
  //   所以这里不是给测试开绿灯，而是复现平台的真实保证。
  let chain = Promise.resolve();
  const serial = (fn) => {
    const next = chain.then(fn, fn);
    chain = next.catch(() => {});
    return next;
  };
  const env = {
    RELAY_TOKEN: token,
    RELAY: {
      idFromName: (n) => 'id:' + n,
      get: () => ({ fetch: (req) => serial(() => instance.fetch(req)) }),
    },
    _storage: storage,
  };
  return env;
}

function call(env, p, opts = {}) {
  const url = 'https://relay.test' + p;
  const headers = {};
  if (opts.token !== null) headers.authorization = 'Bearer ' + (opts.token ?? env.RELAY_TOKEN);
  let body;
  if (opts.body !== undefined) {
    headers['content-type'] = 'application/json';
    body = typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body);
  }
  return worker.fetch(new Request(url, { method: opts.method || (body ? 'POST' : 'GET'), headers, body }), env);
}

const j = async (r) => ({ status: r.status, body: await r.json() });

// ---------------------------------------------------------------- 用例
console.log('中继队列（Durable Object）');

{
  let r = await j(await call(makeEnv(), '/health', { token: null }));
  check('/health 不要鉴权且报出后端是 DO', r.status === 200 && r.body.backend === 'durable-object', JSON.stringify(r.body));
}

{
  const env = makeEnv();
  check('没带 token → 401', (await call(env, '/health', { token: null })).status === 200
    && (await call(env, '/pull?to=alice', { token: null })).status === 401);
  check('token 错 → 401', (await call(env, '/pull?to=alice', { token: 'wrong' })).status === 401);
  const env2 = makeEnv('');
  check('没配 RELAY_TOKEN 时一律拒绝（fail-closed）',
    (await call(env2, '/pull?to=alice')).status === 401);
}

{
  const env = makeEnv();
  const a = await j(await call(env, '/push', { body: { from: 'alice', text: '第一条' } }));
  const b = await j(await call(env, '/push', { body: { from: 'alice', text: '第二条' } }));
  check('push 返回只增序号', a.body.id === '00000001' && b.body.id === '00000002',
    a.body.id + ',' + b.body.id);

  const p1 = await j(await call(env, '/pull?to=alice'));
  check('pull 按先进先出返回', p1.body.messages.length === 2
    && p1.body.messages[0].text === '第一条' && p1.body.messages[1].text === '第二条',
    JSON.stringify(p1.body.messages.map((m) => m.text)));

  const p2 = await j(await call(env, '/pull?to=alice'));
  check('取走即删：再 pull 是空的', p2.body.messages.length === 0, JSON.stringify(p2.body));

  const p3 = await j(await call(env, '/pull?to=bob'));
  check('不同收件人互不串台', p3.body.messages.length === 0, JSON.stringify(p3.body));
}

{
  const env = makeEnv();
  await call(env, '/push', { body: { from: 'alice', text: 'A' } });
  await call(env, '/push', { body: { from: 'bob', text: 'B' } });
  const pa = await j(await call(env, '/pull?to=alice'));
  const pb = await j(await call(env, '/pull?to=bob'));
  check('两个收件人的消息不混淆', pa.body.messages.length === 1 && pa.body.messages[0].text === 'A'
    && pb.body.messages.length === 1 && pb.body.messages[0].text === 'B');
}

{
  const env = makeEnv();
  await call(env, '/result', { body: { from: 'alice', reply: '第一段' } });
  await call(env, '/result', { body: { from: 'alice', reply: '第二段' } });
  const o1 = await j(await call(env, '/outbox?to=alice'));
  check('outbox 按顺序取回结果', o1.body.replies.length === 2
    && o1.body.replies[0].reply === '第一段' && o1.body.replies[1].reply === '第二段');
  const o2 = await j(await call(env, '/outbox?to=alice'));
  check('outbox 取走即清', o2.body.replies.length === 0);
}

{
  const env = makeEnv();
  // 正文里带引号、括号、换行 —— 队列不能把消息拧坏
  const tricky = '含 "引号" 和 [括号] 还有\n换行 </script> & \\ 反斜杠';
  await call(env, '/push', { body: { from: 'alice', text: tricky } });
  const p = await j(await call(env, '/pull?to=alice'));
  check('正文里的引号/括号/换行原样保留', p.body.messages[0].text === tricky,
    JSON.stringify(p.body.messages[0].text));
}

{
  const env = makeEnv();
  check('push 缺 from → 400', (await call(env, '/push', { body: { text: 'x' } })).status === 400);
  check('push 缺 text → 400', (await call(env, '/push', { body: { from: 'a' } })).status === 400);
  check('push 非 JSON → 400', (await call(env, '/push', { body: '{oops' })).status === 400);
  check('超长正文 → 413', (await call(env, '/push', { body: { from: 'a', text: 'x'.repeat(8001) } })).status === 413);
  check('pull 缺 to → 400', (await call(env, '/pull')).status === 400);
  check('方法不对 → 405', (await call(env, '/push', { method: 'GET' })).status === 405);
  check('未知路径 → 404', (await call(env, '/nope')).status === 404);
}

{
  // 序号必须是「读-改-写」在同一个实例内串行，否则会重号（KV 的典型丢更新）
  const env = makeEnv();
  const ids = await Promise.all([1, 2, 3, 4, 5, 6, 7, 8].map((i) =>
    call(env, '/push', { body: { from: 'alice', text: 'm' + i } }).then((r) => r.json()).then((b) => b.id)));
  const uniq = new Set(ids);
  check('并发 push 不重号（依赖 DO 的 input gate 串行化）', uniq.size === ids.length, ids.join(','));
  const p = await j(await call(env, '/pull?to=alice&limit=50'));
  check('并发 push 的 8 条一条不丢', p.body.messages.length === 8, 'n=' + p.body.messages.length);
}

console.log('\n' + pass + '/' + (pass + fails.length) + ' 通过');
if (fails.length) {
  console.log('失败项: ' + fails.join('；'));
  process.exit(1);
}
