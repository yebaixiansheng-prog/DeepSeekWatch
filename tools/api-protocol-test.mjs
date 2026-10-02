/**
 * 官方 API 协议层离线回归测试
 *
 * ★ 纪律（来自 skills/offline-regression-testing，都是踩出来的）：
 *   1. **跑真源码**（用 tools/ets-load.mjs 机械剥离类型后加载），
 *      不跑「手抄的复制品」—— 历史上抄错过 5 处，得出了错误结论。
 *   2. **测试数据贴近真实形态**：SSE 帧、搜索页都用 curl 实测抓下来的原始数据，
 *      不用手编的漂亮数据。旧 Bug（message_id 用唯一串测永不碰撞）就是这么藏住的。
 *   3. **必须有注入测试**：故意改坏 → 确认变红 → 还原。
 *      从没红过的检查等于没有检查。
 *   4. **测「动作痕迹」而非「结果为空」**：断言具体值和分支，
 *      不要只断言 `=== null` 这类弱命题。
 *
 * 覆盖：
 *   A. SseDecoder     分块边界（HTTP 分块与 SSE 事件边界不对齐）
 *   B. SseChunk       真实帧解析
 *   C. ToolCallAccum  工具参数分片拼接
 *   D. ErrMapper      状态码 → 用户文案（六种文案必须互不相同）
 *   E. trimForSend    上下文裁剪不产生非法序列
 *   F. buildBody      请求体字段（尤其 thinking 不能漏）
 *   G. parseBing      搜索页解析（结构变化必须返回空数组）
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEts } from './ets-load.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let pass = 0, fail = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { pass++; }
  else { fail++; failures.push(name + (extra ? '  → ' + extra : '')); }
}
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  ok(name, g === w, `got ${g}  want ${w}`);
}

// ---------------------------------------------------------------------------
// 依赖替身（真常量值，与 Constants.ets 保持一致）
// ---------------------------------------------------------------------------
const PRELUDE = `
function noop() {}
const ErrCode = { OK:0, NETWORK:-1, AUTH:-2, NO_BALANCE:-3, RATE_LIMIT:-4, SERVER:-5, BAD_PAYLOAD:-6, ABORTED:-7, BIZ:-8 };
const ErrMsg = { NETWORK:'网络不通，请检查手表 Wi-Fi', AUTH:'API 密钥无效，请在设置里重新填写',
  NO_BALANCE:'账户余额不足，请先充值', RATE_LIMIT:'请求太频繁，请稍后再试',
  SERVER:'DeepSeek 服务暂时不可用，请稍后重试', BAD_PAYLOAD:'服务端返回了无法识别的数据，请稍后重试',
  ABORTED:'已停止', NO_KEY:'尚未配置 API 密钥' };
const Role = { SYSTEM:'system', USER:'user', ASSISTANT:'assistant', TOOL:'tool' };
const Thinking = { ON:'enabled', OFF:'disabled' };
const SearchCfg = { TOOL_NAME:'web_search', ENDPOINT:'https://cn.bing.com/search', TIMEOUT_MS:12000, MAX_RESULTS:5, MAX_ROUNDS:2 };
const DsHeader = { AUTH:'Authorization', CONTENT_TYPE:'Content-Type', ACCEPT:'Accept', BEARER:'Bearer ' };
const DsApi = { ORIGIN:'https://api.deepseek.com', CHAT:'/chat/completions', BALANCE:'/user/balance' };
const http = { createHttp: () => ({ request: async () => ({ responseCode:200, result:'' }), destroy(){} }),
  RequestMethod:{ GET:'GET', POST:'POST' }, HttpDataType:{ STRING:0 } };
const MAX_SEND_MSGS = 24, MAX_STORED_MSGS = 200, MAX_SESSIONS = 30;
const Store = { async get(){ return ''; }, async put(){}, async remove(){} };
const Keys = {};
`;

const api = await loadEts('model/ApiClient.ets', [
  'export class SseDecoder',
  'export class SseChunk',
  'export class ToolCallAccum',
  'export class ErrMapper',
  'export class ApiClient',
  'export function parseQuery',
  'export class SearchTools'
], PRELUDE);

const search = await loadEts('model/SearchService.ets', [
  'export function parseBing',
  'export function cleanText',
  'export function formatForModel',
  // parseBing 依赖的模块级私有辅助（不导出，但必须在同一作用域）
  'function extractBlocks',
  'function firstTag',
  'function firstParagraph',
  'function firstHref',
  'function stripTagBlock'
], PRELUDE + '\nconst SearchCfg2 = { MAX_RESULTS: 5 };\n');

const store = await loadEts('model/ChatStore.ets', [
  'export function trimForSend',
  'export function validateApiSequence'
], PRELUDE + `
const ChatStore = {};
const Store2 = Store;
`);

const { SseDecoder, SseChunk, ToolCallAccum, ErrMapper, ApiClient, parseQuery } = api;
const { parseBing, cleanText, formatForModel } = search;
const { trimForSend, validateApiSequence } = store;

console.log('=== 官方 API 协议层回归测试 ===\n');

// ---------------------------------------------------------------------------
console.log('A. SseDecoder（分块边界）');
{
  const d = new SseDecoder();
  eq('A1 一次喂入两个完整事件', d.feed('data: {"a":1}\n\ndata: {"b":2}\n\n'), ['{"a":1}', '{"b":2}']);

  const d2 = new SseDecoder();
  eq('A2 半截事件不吐出', d2.feed('data: {"a":'), []);
  eq('A3 补齐后吐出', d2.feed('1}\n\n'), ['{"a":1}']);

  const d3 = new SseDecoder();
  eq('A4 切在 data: 中间（前半）', d3.feed('da'), []);
  eq('A5 切在 data: 中间（后半）', d3.feed('ta: {"x":1}\n\n'), ['{"x":1}']);

  const d4 = new SseDecoder();
  eq('A6 CRLF 分隔', d4.feed('data: {"c":3}\r\n\r\n'), ['{"c":3}']);

  const d5 = new SseDecoder();
  eq('A7 多事件+尾部半截', d5.feed('data: {"a":1}\n\ndata: {"b":2}\n\ndata: {"c":'), ['{"a":1}', '{"b":2}']);
  eq('A8 残留缓冲正确', d5.rest(), 'data: {"c":');

  const d6 = new SseDecoder();
  eq('A9 [DONE] 原样返回', d6.feed('data: [DONE]\n\n'), ['[DONE]']);

  const d7 = new SseDecoder();
  eq('A10 纯注释行不产出数据', d7.feed(': keep-alive\n\n'), []);

  // ★ 逐字节喂入（最极端的切分）——必须与整体喂入结果一致
  const whole = 'data: {"a":1}\n\ndata: {"b":2}\n\n';
  const d8 = new SseDecoder();
  const got = [];
  for (const ch of whole) {
    for (const p of d8.feed(ch)) got.push(p);
  }
  eq('A11 逐字节喂入结果一致', got, ['{"a":1}', '{"b":2}']);
}

// ---------------------------------------------------------------------------
console.log('B. SseChunk（真实帧解析）');
{
  const firstFrame = '{"id":"36b365b7-3d84-4df5-b8d4-73a5e51ee336","object":"chat.completion.chunk","created":1790771894,"model":"deepseek-flash","system_fingerprint":"aeb56401ca74e127821c4f9126dcb669","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}';
  const r1 = SseChunk.parse(firstFrame);
  ok('B1 首帧能解析', r1 !== null);
  eq('B2 首帧 content 为空串', r1.content, '');
  eq('B3 首帧 reasoning 为空串', r1.reasoning, '');
  eq('B4 首帧未 finish', r1.finished, false);

  const bodyFrame = '{"id":"a","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"好的"},"finish_reason":null}]}';
  const r2 = SseChunk.parse(bodyFrame);
  eq('B5 正文帧 content', r2.content, '好的');
  eq('B6 正文帧 reasoning 空', r2.reasoning, '');

  const thinkFrame = '{"choices":[{"index":0,"delta":{"reasoning_content":"让我想想"},"finish_reason":null}]}';
  const r3 = SseChunk.parse(thinkFrame);
  eq('B7 思考帧 reasoning', r3.reasoning, '让我想想');
  eq('B8 思考帧 content 空', r3.content, '');

  const tailFrame = '{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}';
  const r4 = SseChunk.parse(tailFrame);
  eq('B9 尾帧 finished', r4.finished, true);
  eq('B10 尾帧 content 空', r4.content, '');

  eq('B11 [DONE] 返回 null', SseChunk.parse('[DONE]'), null);
  eq('B12 坏 JSON 返回 null', SseChunk.parse('{这不是json'), null);
  eq('B13 缺 choices 返回 null', SseChunk.parse('{"id":"x"}'), null);
  eq('B14 choices 空数组返回 null', SseChunk.parse('{"choices":[]}'), null);

  const fullBody = '{"choices":[{"index":0,"message":{"role":"assistant","content":"收到"},"finish_reason":"stop"}]}';
  eq('B15 非流式解析', SseChunk.parseFull(fullBody), '收到');
}

// ---------------------------------------------------------------------------
console.log('C. ToolCallAccum（工具参数分片拼接）');
{
  const acc = new ToolCallAccum();
  acc.ingest('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_00_abc","type":"function","function":{"name":"web_search","arguments":""}}]},"finish_reason":null}]}');
  acc.ingest('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"que"}}]},"finish_reason":null}]}');
  acc.ingest('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\\": \\"北"}}]},"finish_reason":null}]}');
  acc.ingest('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"京天气\\"}"}}]},"finish_reason":"tool_calls"}]}');

  const list = acc.list();
  eq('C1 只有一个工具调用', list.length, 1);
  eq('C2 id 正确', list[0].id, 'call_00_abc');
  eq('C3 name 正确', list[0].name, 'web_search');
  eq('C4 arguments 完整拼接', list[0].arguments, '{"query": "北京天气"}');
  eq('C5 parseQuery 能取出 query', parseQuery(list[0].arguments), '北京天气');

  const acc2 = new ToolCallAccum();
  acc2.ingest('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"web_search","arguments":"{\\"query\\":\\"A\\"}"}},{"index":1,"id":"b","function":{"name":"web_search","arguments":"{\\"query\\":\\"B\\"}"}}]}}]}');
  eq('C6 两个调用', acc2.list().length, 2);
  eq('C7 第0个 query', parseQuery(acc2.list()[0].arguments), 'A');
  eq('C8 第1个 query', parseQuery(acc2.list()[1].arguments), 'B');

  eq('C9 坏 JSON 返回空串', parseQuery('{bad'), '');
  eq('C10 缺 query 字段', parseQuery('{"q":"x"}'), '');
}

// ---------------------------------------------------------------------------
console.log('D. ErrMapper（错误分流）');
{
  const NUM = { AUTH: -2, NO_BALANCE: -3, RATE_LIMIT: -4, SERVER: -5, NETWORK: -1, BIZ: -8 };
  const cases = [[401, 'AUTH'], [403, 'AUTH'], [402, 'NO_BALANCE'],
                 [429, 'RATE_LIMIT'], [500, 'SERVER'], [503, 'SERVER'], [0, 'NETWORK']];
  for (const [st, want] of cases) {
    const r = ErrMapper.from(st, '');
    eq(`D ${st} → ${want}`, r.code, NUM[want]);
  }

  ok('D 401 文案指名密钥', ErrMapper.from(401, '').message.includes('密钥'));
  ok('D 402 文案指名余额', ErrMapper.from(402, '').message.includes('余额'));
  ok('D 0 文案指名网络', ErrMapper.from(0, '').message.includes('网络'));

  const bizR = ErrMapper.from(400, '{"error":{"message":"max_tokens 超限"}}');
  eq('D 400 带 message → BIZ', bizR.code, NUM.BIZ);
  eq('D 400 用服务端文案', bizR.message, 'max_tokens 超限');

  const b2 = ErrMapper.from(400, '');
  ok('D 400 无 message 兜底含状态码', b2.message.includes('400'));

  // ★ 六种错误文案互不相同（「不许复用文案」纪律的机器检查）
  const msgs = [
    ErrMapper.from(0, '').message,
    ErrMapper.from(401, '').message,
    ErrMapper.from(402, '').message,
    ErrMapper.from(429, '').message,
    ErrMapper.from(500, '').message,
    ErrMapper.from(400, '{"error":{"message":"x"}}').message
  ];
  eq('D 六种错误文案互不相同', new Set(msgs).size, 6);
}

// ---------------------------------------------------------------------------
console.log('E. trimForSend / validateApiSequence（裁剪不产生非法序列）');
{
  const U = (c) => ({ role: 'user', content: c, ts: 1 });
  const A = (c) => ({ role: 'assistant', content: c, ts: 2 });
  const AT = (id) => ({ role: 'assistant', content: '', toolCalls: [{ id, name: 'web_search', arguments: '{}' }], ts: 3 });
  const T = (id) => ({ role: 'tool', content: '结果', toolCallId: id, ts: 4 });
  const S = () => ({ role: 'system', content: 'sys', ts: 0 });

  // ---- 校验器自身的正确性（先证明「尺子」是准的，再用它量东西）----
  eq('E0a 合法序列（无工具）', validateApiSequence([U('a'), A('b')]), []);
  eq('E0b 合法序列（工具配对完整）', validateApiSequence([U('a'), AT('c1'), T('c1'), A('b')]), []);
  ok('E0c 孤立 tool 被识别',
    validateApiSequence([U('a'), T('c1'), A('b')]).length > 0);
  ok('E0d 悬挂 tool_calls 被识别',
    validateApiSequence([U('a'), AT('c1')]).length > 0);
  ok('E0e tool 缺 id 被识别',
    validateApiSequence([U('a'), AT('c1'), { role: 'tool', content: 'x', ts: 5 }]).length > 0);
  ok('E0f id 不匹配被识别',
    validateApiSequence([U('a'), AT('c1'), T('c9')]).length > 0);
  ok('E0g 中间被吞结果被识别',
    validateApiSequence([U('a'), AT('c1'), U('b'), T('c1')]).length > 0);
  eq('E0h 空序列合法', validateApiSequence([]), []);

  // ---- 裁剪行为 ----
  eq('E1 不超限原样', trimForSend([U('a'), A('b')], 10).length, 2);

  const long = [];
  for (let i = 0; i < 40; i++) long.push(i % 2 === 0 ? U('u' + i) : A('a' + i));
  const t2 = trimForSend(long, 10);
  eq('E2 裁到 10 条', t2.length, 10);
  eq('E2 保留的是最新的', t2[t2.length - 1].content, 'a39');
  eq('E2 裁剪结果合法', validateApiSequence(t2), []);

  const withSys = [S()];
  for (let i = 0; i < 40; i++) withSys.push(U('u' + i));
  const t3 = trimForSend(withSys, 10);
  eq('E3 system 保留且在最前', t3[0].role, 'system');
  ok('E3 总数 ≤ 11', t3.length <= 11);
  eq('E3 裁剪结果合法', validateApiSequence(t3), []);

  // ★★ E4：必须让裁剪落点**正好命中 tool**，否则回溯分支根本没被执行
  //    序列：0=U1 1=AT(c1) 2=T(c1) 3=A1 4=U2 5=AT(c2) 6=T(c2) 7=A2
  //    max=2 → start=6 → 命中 T(c2) → 必须回溯到 5
  const seq = [U('u1'), AT('c1'), T('c1'), A('回答1'), U('u2'), AT('c2'), T('c2'), A('回答2')];
  const t4 = trimForSend(seq, 2);
  ok('E4 首条不是孤立 tool', t4[0].role !== 'tool', '首条 role=' + t4[0].role);
  eq('E4 裁剪结果合法', validateApiSequence(t4), []);
  ok('E4 回溯后带上了发起它的 assistant',
    t4[0].role === 'assistant' && t4[0].toolCalls !== undefined,
    '首条=' + JSON.stringify(t4[0]).substring(0, 80));

  // ★★ E4b：同一序列用 max=6（start=2 也命中 tool）再验一次
  const t4b = trimForSend(seq, 6);
  eq('E4b 裁剪结果合法', validateApiSequence(t4b), []);
  ok('E4b 首条不是孤立 tool', t4b[0].role !== 'tool');

  // ★ E5 末尾悬挂的 tool_calls（工具还没回来）→ 必须裁掉
  const tailBad = [U('u1'), A('a1'), AT('c9')];
  const t5 = trimForSend(tailBad, 2);
  const last = t5[t5.length - 1];
  ok('E5 末尾不是悬挂 tool_calls',
    !(last.role === 'assistant' && last.toolCalls && last.toolCalls.length > 0),
    '末条 role=' + last.role);
  eq('E5 裁剪结果合法', validateApiSequence(t5), []);

  // ★ E6 完整配对不该被破坏
  const paired = [U('u1'), AT('c1'), T('c1'), A('a1')];
  eq('E6 全保留', trimForSend(paired, 4).length, 4);
  eq('E6 裁剪结果合法', validateApiSequence(trimForSend(paired, 4)), []);

  // ★★ E7 随机化穷举：对**每一种** max 取值都要求结果合法
  //    （这正是能抓住「某条分支从没被执行」的写法）
  const mixed = [S(), U('u1'), AT('c1'), T('c1'), A('a1'), U('u2'), AT('c2'), T('c2'), A('a2'), U('u3')];
  let allOk = true;
  const badMax = [];
  for (let mx = 1; mx <= mixed.length; mx++) {
    const r = trimForSend(mixed, mx);
    if (validateApiSequence(r).length > 0) {
      allOk = false;
      badMax.push(mx);
    }
  }
  ok('E7 所有 max 取值的裁剪结果都合法', allOk, '非法 max=' + JSON.stringify(badMax));

  // ★★ E8 多轮工具（连续两次搜索）也不能破坏配对
  const twoRounds = [U('u1'), AT('a1'), T('a1'), AT('b1'), T('b1'), A('ans')];
  let ok8 = true;
  const bad8 = [];
  for (let mx = 1; mx <= twoRounds.length; mx++) {
    if (validateApiSequence(trimForSend(twoRounds, mx)).length > 0) {
      ok8 = false;
      bad8.push(mx);
    }
  }
  ok('E8 多轮工具的裁剪结果都合法', ok8, '非法 max=' + JSON.stringify(bad8));
}

// ---------------------------------------------------------------------------
console.log('F. buildBody（请求体正确性）');
{
  const msgs = [{ role: 'user', content: '你好', ts: 1 }];
  const mk = (thinking, search, m = msgs) => ApiClient.buildBody(
    { apiKey: 'k', model: 'deepseek-flash', messages: m, stream: true, thinking, search }, m);

  const b1 = mk(false, false);
  ok('F1 thinking 字段存在', b1.includes('"thinking"'));
  ok('F2 关闭时 disabled', b1.includes('"disabled"'));

  const b2 = mk(true, false);
  ok('F3 开启时 enabled', b2.includes('"enabled"'));

  ok('F4 model 正确', b2.includes('"model":"deepseek-flash"'));
  ok('F5 stream=true', b1.includes('"stream":true'));
  ok('F6 messages 存在', b1.includes('"messages":['));
  ok('F7 内容被 JSON 转义', b1.includes('"content":"你好"'));
  ok('F8 关闭搜索时无 tools', !b1.includes('"tools"'));

  const b3 = mk(false, true);
  ok('F9 开启搜索时有 tools', b3.includes('"tools"'));
  ok('F10 工具名 web_search', b3.includes('web_search'));
  ok('F11 有 tool_choice', b3.includes('"tool_choice":"auto"'));

  for (const [n, b] of [['F12 thinking关', b1], ['F13 thinking开', b2], ['F14 搜索', b3]]) {
    let parsed = null, err = '';
    try { parsed = JSON.parse(b); } catch (e) { err = e.message; }
    ok(n + ' 是合法 JSON', parsed !== null, err);
  }

  // ★ reasoning 绝不回传（官方 API 不接受）
  const wr = [{ role: 'assistant', content: '答案', reasoning: '我这样想的', ts: 2 }];
  const b4 = ApiClient.buildBody({ apiKey: 'k', model: 'm', messages: wr, stream: false, thinking: false, search: false }, wr);
  ok('F15 reasoning 不回传', !b4.includes('reasoning'));

  // ★ 工具消息序列
  const toolMsgs = [
    { role: 'assistant', content: '', toolCalls: [{ id: 'c1', name: 'web_search', arguments: '{}' }], ts: 1 },
    { role: 'tool', content: '搜索结果', toolCallId: 'c1', ts: 2 }
  ];
  const b5 = ApiClient.buildBody({ apiKey: 'k', model: 'm', messages: toolMsgs, stream: false, thinking: false, search: true }, toolMsgs);
  ok('F16 assistant 带 tool_calls', b5.includes('"tool_calls"'));
  ok('F17 tool 消息带 tool_call_id', b5.includes('"tool_call_id":"c1"'));
  ok('F19 工具 assistant 的 content 为 null', b5.includes('"content":null'));
  let p5 = null; try { p5 = JSON.parse(b5); } catch (e) {}
  ok('F18 含工具的消息体是合法 JSON', p5 !== null);
}

// ---------------------------------------------------------------------------
console.log('G. parseBing（搜索页解析）');
{
  const fixturePath = path.join(__dirname, 'fixtures/bing_sample.html');
  ok('G1 存在真实页面样本', fs.existsSync(fixturePath));
  if (fs.existsSync(fixturePath)) {
    const html = fs.readFileSync(fixturePath, 'utf8');
    const items = parseBing(html);
    ok('G2 真实页面能解析出结果', items.length >= 3, '条数=' + items.length);
    ok('G3 结果都有链接', items.every(i => i.url.startsWith('http')));
    ok('G4 结果都有标题或摘要', items.every(i => i.title.length > 0 || i.snippet.length > 0));
    // ★ 不能把导航栏/页脚当结果（标题不该是「登录」「必应」这类）
    const junk = items.filter(i => ['必应', '登录', '设置'].includes(i.title));
    eq('G5 不含明显导航噪声', junk.length, 0);
    console.log('   （真实页面解析出 ' + items.length + ' 条）');
  }

  eq('G6 空 HTML → 空数组', parseBing(''), []);
  eq('G7 无关 HTML → 空数组', parseBing('<html><body><div>hello</div></body></html>'), []);
  eq('G8 有 b_algo 但无链接 → 被过滤', parseBing('<li class="b_algo"><h2>t</h2></li>'), []);

  const synth = '<ol><li class="b_algo"><h2><a href="https://example.com/a">标题甲</a></h2><p>这是摘要甲</p></li></ol>';
  const s1 = parseBing(synth);
  eq('G9 合成样本条数', s1.length, 1);
  eq('G10 标题正确', s1[0].title, '标题甲');
  eq('G11 链接正确', s1[0].url, 'https://example.com/a');
  eq('G12 摘要正确', s1[0].snippet, '这是摘要甲');

  eq('G13 nbsp 解码', cleanText('a&nbsp;b'), 'a b');
  eq('G14 ensp 解码', cleanText('6 天之前&ensp;&#0183;&ensp;DeepSeek'), '6 天之前 · DeepSeek');
  eq('G15 amp 解码', cleanText('a&amp;b'), 'a&b');
  eq('G16 去标签', cleanText('<b>粗</b>体'), '粗体');
  eq('G17 script 内容被移除', cleanText('<script>var x=1;</script>可见'), '可见');
  eq('G18 数字实体', cleanText('&#65;&#66;'), 'AB');

  const emptyFmt = formatForModel('测试', []);
  ok('G19 空结果提示未找到', emptyFmt.includes('未找到'));
  ok('G20 空结果要求不要编造', emptyFmt.includes('不要编造'));
  ok('G21 有结果时列出条目', formatForModel('q', [{ title: 'T', url: 'u', snippet: 's' }]).includes('1. T'));
}

// ---------------------------------------------------------------------------
console.log('\n=== 结果 ===');
console.log(`通过 ${pass} / 失败 ${fail}`);
if (fail > 0) {
  console.log('\n失败项：');
  for (const f of failures) console.log('  ✗ ' + f);
  process.exit(1);
}
console.log('全部通过 ✓');
