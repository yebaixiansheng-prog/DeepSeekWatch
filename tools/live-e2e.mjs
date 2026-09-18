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
// ★ 必须与 entry/src/main/ets/common/Constants.ets 的 DsHeader.USER_AGENT 保持一致。
//   旧版本这里是伪造的 "HarmonyOS; HUAWEI WATCH … Mobile Safari"，自称 Mozilla
//   却没有 Chrome/Safari 版本号 —— 正是触发风控 RISK_DEVICE_DETECTED 的原因之一。
//   如果这里和 App 不一致，本脚本「通过」就不能代表 App 会通过。
const UA = 'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const PLATFORM = 'web';

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
  'x-ds-platform': PLATFORM,
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
    // ★ 与 App 保持一致：抢占语义。false 会在「上一轮流未结束」时被服务端排队挂死。
    preempt: true,
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

// ============================================================================
// 【5】多轮连续对话 —— 专门盯「聊两轮之后再也发不出去」
//
// 为什么要单独一个用例：
//   用户反馈「对话超过两次之后就达上限、无法继续」。这个现象只在
//   **同一个会话里连续多轮**才会出现，单轮用例永远测不到。
//   根因是 `preempt:false` 的排队语义 + 服务端残留的僵尸流：
//   第 3 轮开始请求会被挂在服务端，客户端一帧都收不到。
//
//   本用例连发 3 轮并逐轮打印 code / 帧数 / 耗时。
//   判定标准：**每一轮都必须在 timeout 内收到帧**。
//   如果第 N 轮 0 帧且超时 → 复现成功，说明 preempt 仍是 false。
// ============================================================================
if (!process.env.SKIP_MULTITURN) {
  console.log('【5】多轮连续对话（复现 / 回归「聊两轮后就发不出去」）');
  const ROUNDS = 3;
  const PER_ROUND_MS = 60000;
  let prevAssistantId = null;

  for (let round = 1; round <= ROUNDS; round++) {
    const ask = `第${round}轮：只回复数字 ${round}`;
    const powR = await fetch(ORIGIN + '/api/v0/chat/create_pow_challenge', {
      method: 'POST', headers: H,
      body: JSON.stringify({ target_path: '/api/v0/chat/completion' }),
    });
    const powJ = await powR.json();
    if (powJ.code !== 0) { check(`第 ${round} 轮取 PoW`, false, `code=${powJ.code}`); break; }
    const c = powJ.data.biz_data.challenge;
    const { DeepSeekHash } = await loadDeepSeekHash();
    const answer = DeepSeekHash.searchRange(
      `${c.salt}_${c.expire_at}_`, c.challenge, 0, c.difficulty);
    const powB64 = Buffer.from(JSON.stringify({
      algorithm: c.algorithm, challenge: c.challenge, salt: c.salt,
      answer, signature: c.signature, target_path: '/api/v0/chat/completion',
    })).toString('base64');

    const bodyObj = {
      chat_session_id: sessionId,
      prompt: ask,
      ref_file_ids: [],
      thinking_enabled: false,
      search_enabled: false,
      // ★ 与 App 保持一致：必须是 true。改成 false 就能复现挂死。
      preempt: true,
      model_type: 'default',
    };
    if (prevAssistantId) { bodyObj.parent_message_id = prevAssistantId; }

    const t0 = Date.now();
    let r;
    try {
      r = await fetch(ORIGIN + '/api/v0/chat/completion', {
        method: 'POST',
        headers: { ...H, 'Accept': 'text/event-stream', 'X-DS-PoW-Response': powB64 },
        body: JSON.stringify(bodyObj),
        signal: AbortSignal.timeout(PER_ROUND_MS),
      });
    } catch (e) {
      check(`第 ${round} 轮收到响应`, false,
        `挂死/超时 ${Date.now() - t0}ms（${e.name}）← 这就是「发不出去」的现象`);
      break;
    }

    // 边读边计时，超时就判挂死
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = '', roundFrames = 0, roundErr = null, newMsgId = null, sawDone = false;
    const tRead = Date.now();
    try {
      while (true) {
        if (Date.now() - tRead > PER_ROUND_MS) { throw new Error('read_timeout'); }
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).replace(/\r$/, '');
          buf = buf.slice(nl + 1);
          if (!line.startsWith('data:')) continue;
          const payload = line.slice(5).trim();
          if (!payload) continue;
          roundFrames++;
          let obj; try { obj = JSON.parse(payload); } catch { continue; }
          if (typeof obj.code === 'number' && obj.code !== 0) roundErr = obj;
          // 首帧 response 对象里的 message_id —— 下一轮 parent 要用它
          const resp = obj.v?.response ?? obj.v;
          if (resp && typeof resp === 'object') {
            if (resp.message_id || resp.messageId || resp.id) {
              newMsgId = resp.message_id || resp.messageId || resp.id;
            }
          }
          if (obj.v && obj.v.status === 'FINISHED') sawDone = true;
          if (obj.p === 'response' && obj.o === 'SET' && obj.v?.status === 'FINISHED') sawDone = true;
        }
      }
    } catch (e) {
      roundErr = { code: 'LOCAL', msg: e.message };
    }

    const ms = Date.now() - t0;
    if (roundErr && roundErr.code !== 'LOCAL') {
      check(`第 ${round} 轮`, false, `服务端错误 code=${roundErr.code} msg=${roundErr.msg}`);
      break;
    }
    check(`第 ${round} 轮收到流式数据`, roundFrames > 0,
      `帧数=${roundFrames} 耗时=${ms}ms ${sawDone ? '已结束' : '未收到结束态'}`);
    if (roundFrames === 0) {
      console.log(info('⚠ 复现成功：服务端接受了连接但一个字节都没回。'));
      console.log(info('  检查 completion 请求体里的 preempt 是否为 true。'));
      break;
    }
    if (newMsgId) {
      prevAssistantId = newMsgId;
      console.log(info(`  ↑ 服务端 message_id=${newMsgId.slice(0, 12)}…（下一轮 parent_message_id）`));
    } else {
      // 拿不到 id 就用历史接口取最近一条 assistant id，保证链路连续
      try {
        const hr = await fetch(ORIGIN + '/api/v0/chat/history_messages?chat_session_id=' + sessionId,
          { method: 'GET', headers: H });
        const hj = await hr.json();
        const msgs = hj.data?.biz_data?.chat_messages ?? [];
        const lastA = [...msgs].reverse().find((m) => m.role === 'ASSISTANT');
        if (lastA) prevAssistantId = lastA.id;
        console.log(info(`  ↑ 从历史接口取到 parent=${String(prevAssistantId).slice(0, 12)}…`));
      } catch { /* 拿不到就下一轮不带 parent，不影响挂死判定 */ }
    }
  }
  console.log('');
}

// ------------------------------------------------------------- 汇总
if (failures === 0) {
  console.log('\x1b[32m全部通过\x1b[0m —— PoW、鉴权、SSE 对话、历史回读均正常');
} else {
  console.log(`\x1b[31m${failures} 项失败\x1b[0m`);
  process.exitCode = 1;
}
