/**
 * PC 端「全链路」真机协议验证器
 *
 * 为什么要有它：
 *   在手表上验证一次要经历「编译→安装→重启→点按→看日志」，一轮 3~5 分钟，
 *   而且手表上打日志、看日志都很笨重。协议层（PoW / 请求头 / SSE 帧）的问题
 *   完全可以在 PC 上用同一份算法、同一个账号，几秒钟验证一遍，
 *   把手表留给人机交互（布局、点击、渲染）的验证。
 *
 * token 从哪来：
 *   1) 环境变量 DS_TOKEN（优先）
 *   2) 否则**直接从手表读**：hdc shell cat 应用 Preferences 文件，
 *      从 XML 里取出 token。这样不需要任何人把密码交出来。
 *
 * 用法：
 *   node tools/live-e2e.mjs                 # 读设备 token，跑全链路
 *   node tools/live-e2e.mjs "1+1=?"         # 自定义提问
 *   DS_TOKEN=xxx node tools/live-e2e.mjs    # 用指定 token
 *
 * ⚠️ 这个脚本会在终端打印服务端返回的正文，但**不会把 token 落盘**。
 */
import { execFileSync } from 'child_process';
import { loadDeepSeekHash } from './ets-loader.mjs';

const HDC = 'D:/DevEco Studio/sdk/default/openharmony/toolchains/hdc';
const PREF = '/data/app/el2/100/base/com.dswatch.round/haps/entry/preferences/dswatch_store';
const ORIGIN = 'https://chat.deepseek.com';
const UA = 'Mozilla/5.0 (Linux; HarmonyOS; HUAWEI WATCH) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';

const ok = (s) => `\x1b[32m✓\x1b[0m ${s}`;
const bad = (s) => `\x1b[31m✗\x1b[0m ${s}`;
const info = (s) => `  ${s}`;

// ---------------------------------------------------------------- token
function tokenFromDevice() {
  let xml = '';
  try {
    xml = execFileSync(HDC, ['shell', `cat ${PREF}`], { encoding: 'utf8', timeout: 20000 });
  } catch (e) {
    return '';
  }
  const m = /<string key="token">([^<]+)<\/string>/.exec(xml);
  return m ? m[1] : '';
}

const TOKEN = process.env.DS_TOKEN || tokenFromDevice();
const PROMPT = process.argv[2] || '1+1=?';

if (!TOKEN) {
  console.log(bad('拿不到 token。'));
  console.log(info('手表上还没登录，或者应用沙箱路径变了。'));
  console.log(info('先在手表上登录一次，或用 DS_TOKEN=xxx 直接指定。'));
  process.exit(2);
}
console.log(ok(`拿到 token（${TOKEN.length} 字符，不在日志里回显）`));
console.log('');

const H = {
  'Content-Type': 'application/json',
  'Accept': '*/*',
  'User-Agent': UA,
  'Authorization': 'Bearer ' + TOKEN,
};

let failures = 0;
function check(name, pass, extra = '') {
  if (pass) {
    console.log(ok(name + (extra ? '  ' + extra : '')));
  } else {
    console.log(bad(name + (extra ? '  ' + extra : '')));
    failures++;
  }
}

// ---------------------------------------------------------- 1. 鉴权自检
console.log('【1】token 是否有效（fetch_page）');
{
  const r = await fetch(
    ORIGIN + '/api/v0/chat_session/fetch_page?lte_cursor.pinned=false&count=5',
    { method: 'GET', headers: H });
  const t = await r.text();
  const j = JSON.parse(t);
  // ⚠️ 鉴权失败时 HTTP 状态码也是 200，只能看 code
  check('HTTP 200 且业务码为 0', r.status === 200 && j.code === 0,
    `code=${j.code} msg=${j.msg}`);
  if (j.code === 0) {
    const n = j.data?.biz_data?.chat_sessions?.length ?? 0;
    console.log(info(`会话列表返回 ${n} 条`));
  } else {
    console.log(info('token 失效，后面的用例没有意义，先重新登录'));
    process.exit(1);
  }
}
console.log('');

// ------------------------------------------------------------- 2. PoW
console.log('【2】PoW 挑战与求解（用工程真源码算法）');
let pow = null;
{
  const r = await fetch(ORIGIN + '/api/v0/chat/create_pow_challenge', {
    method: 'POST', headers: H,
    body: JSON.stringify({ target_path: '/api/v0/chat/completion' }),
  });
  const j = await r.json();
  check('取到挑战', j.code === 0 && !!j.data?.biz_data?.challenge?.challenge,
    `code=${j.code}`);
  if (j.code !== 0) { process.exit(1); }

  const c = j.data.biz_data.challenge;
  console.log(info(`algorithm=${c.algorithm} difficulty=${c.difficulty}`));

  const { DeepSeekHash } = await loadDeepSeekHash();
  const prefix = `${c.salt}_${c.expire_at}_`;
  const t0 = Date.now();
  const answer = DeepSeekHash.searchRange(prefix, c.challenge, 0, c.difficulty);
  const ms = Date.now() - t0;
  check('在难度范围内搜出 nonce', answer >= 0, `answer=${answer} 耗时=${ms}ms`);

  // 交叉确认：把 nonce 代回去必须命中挑战
  // 注意 hashString 返回的是 Uint8Array（32 字节），要用 toHex 才可比字符串
  const h = DeepSeekHash.toHex(DeepSeekHash.hashString(prefix + answer));
  check('代回验证哈希等于 challenge', h === c.challenge,
    h === c.challenge ? '' : `得到 ${h.slice(0, 16)}… 期望 ${c.challenge.slice(0, 16)}…`);

  pow = {
    algorithm: c.algorithm, challenge: c.challenge, salt: c.salt,
    answer, signature: c.signature, target_path: '/api/v0/chat/completion',
  };
}
console.log('');

// ------------------------------------------------- 3. 建会话 + SSE 对话
console.log(`【3】发送消息并接收流式回复（"${PROMPT}"）`);
let sessionId = '';
let answerText = '';
let frames = 0;
let sawFinish = false;
{
  // 建会话
  const cr = await fetch(ORIGIN + '/api/v0/chat_session/create', {
    method: 'POST', headers: H, body: '{}',
  });
  const cj = await cr.json();
  sessionId = cj.data?.biz_data?.chat_session?.id ?? '';
  check('创建会话', sessionId.length > 0, `session=${sessionId.slice(0, 12)}…`);

  const powB64 = Buffer.from(JSON.stringify(pow)).toString('base64');
  const body = JSON.stringify({
    chat_session_id: sessionId,
    parent_message_id: null,
    model_type: 'default',
    prompt: PROMPT,
    ref_file_ids: [],
    thinking_enabled: false,
    search_enabled: false,
    preempt: false,
  });

  const t0 = Date.now();
  const r = await fetch(ORIGIN + '/api/v0/chat/completion', {
    method: 'POST',
    headers: {
      ...H,
      'Accept': 'text/event-stream',
      'X-DS-PoW-Response': powB64,
    },
    body,
  });
  check('SSE 连接建立', r.status === 200, `status=${r.status}`);

  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  // 正文增量集中在 response/fragments/<idx>/content
  const frags = new Map();

  while (true) {
    const { value, done } = await reader.read();
    if (done) { break; }
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) { continue; }
      const payload = line.slice(5).trim();
      if (!payload) { continue; }
      frames++;
      let obj;
      try { obj = JSON.parse(payload); } catch { continue; }
      if (obj.p === 'response/status' || obj.p === 'status') { continue; }

      // JSON-Patch: {p, o, v}
      if (obj.o === 'APPEND' && typeof obj.p === 'string') {
        const m = /^response\/fragments\/(\d+)\/content$/.exec(obj.p);
        if (m) {
          const i = Number(m[1]);
          frags.set(i, (frags.get(i) || '') + obj.v);
        }
      }
      // 结束帧
      if (obj.p === 'response' && obj.o === 'SET' && obj.v && obj.v.status) {
        if (obj.v.status === 'FINISHED') { sawFinish = true; }
      }
      if (obj.v && obj.v.status === 'FINISHED') { sawFinish = true; }
    }
    if (Date.now() - t0 > 120000) { break; }
  }

  // 正文 = 所有 RESPONSE 类片段拼接（这里取第 1 个之后的非 THINK 片段；
  // 简化处理：把所有 fragment 内容拼起来，THINK 内容通常在最前置的片段）
  answerText = [...frags.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([, v]) => v)
    .join('');

  console.log(info(`收到 ${frames} 帧，片段数=${frags.size}，耗时=${Date.now() - t0}ms`));
  check('收到流式帧', frames > 0);
  check('正文非空', answerText.length > 0, `长度=${answerText.length}`);
  check('收到结束态', sawFinish);
  console.log('');
  console.log('  ── 回答正文 ──');
  console.log('  ' + answerText.trim().slice(0, 500).replace(/\n/g, '\n  '));
  console.log('  ──────────────');
}
console.log('');

// -------------------------------------------- 4. 历史消息能读回来
console.log('【4】历史消息回读');
{
  const r = await fetch(ORIGIN + '/api/v0/chat/history_messages?chat_session_id=' + sessionId, {
    method: 'GET', headers: H,
  });
  const j = await r.json();
  check('history_messages 返回 0', j.code === 0, `code=${j.code}`);
  const msgs = j.data?.biz_data?.chat_messages ?? [];
  console.log(info(`取回 ${msgs.length} 条消息`));
}
console.log('');

// ------------------------------------------------------------- 汇总
if (failures === 0) {
  console.log('\x1b[32m全部通过\x1b[0m —— PoW、鉴权、SSE 对话、历史回读均正常');
} else {
  console.log(`\x1b[31m${failures} 项失败\x1b[0m`);
  process.exitCode = 1;
}
