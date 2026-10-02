#!/usr/bin/env node
/**
 * 真实 API 全链路测试（PC 端，不需真机）
 *
 * ★ 设计取舍（重要）：
 *   这里**不重写任何协议逻辑** —— 请求体构造、SSE 解析、工具参数累积、
 *   消息序列校验、搜索页解析，全部用 `tools/ets-load.mjs` 加载的**真源码**。
 *   只有「socket」这一层换成 Node 的 fetch（因为 @ohos.net.http 在 PC 上不存在）。
 *
 *   价值：协议层行为与手表上**逐字节一致**。
 *   真机只需验证「UI 有没有把内容显示出来」，而不是「协议对不对」。
 *   若这里也自己写一套解析，验证的就是副本不是产品（历史教训：
 *   抄错 5 处高低位顺序，得出过完全错误的结论）。
 *
 * 覆盖：
 *   1. 非流式对话
 *   2. 流式对话（SSE 逐帧）
 *   3. 思考模式（reasoning_content 是否下发）
 *   4. ★ 联网搜索完整往返（模型要工具 → 真抓 Bing → 回灌 → 出答案）
 *   5. 错误路径（错误密钥 → 鉴权失败分流）
 *
 * 用法：
 *   node tools/live-e2e.mjs                 # 用工程内置密钥
 *   node tools/live-e2e.mjs --key sk-xxx    # 指定密钥
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEts } from './ets-load.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

let pass = 0, fail = 0;
const failures = [];
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else {
    fail++;
    failures.push(name + (extra ? '  → ' + extra : ''));
    console.log('  ✗ ' + name + (extra ? '  → ' + extra : ''));
  }
}

/**
 * 从真源码取密钥，保证与 App 用同一个
 *
 * ★ 密钥现在放在 `LocalKey.ets`（在 .gitignore 里，绝不入库），
 *   `Constants.ets` 只是引用它。所以要读 LocalKey。
 */
function apiKeyFromSource() {
  const p = path.join(ROOT, 'entry/src/main/ets/common/LocalKey.ets');
  if (!fs.existsSync(p)) {
    return '';
  }
  const s = fs.readFileSync(p, 'utf8');
  // 匹配 VALUE: string = 'sk-...'   （允许类型标注的写法）
  const m = s.match(/VALUE\s*:\s*string\s*=\s*'([^']*)'/)
    || s.match(/VALUE\s*=\s*'([^']*)'/);
  return m ? m[1] : '';
}
const argKeyIdx = process.argv.indexOf('--key');
const API_KEY = argKeyIdx >= 0 ? process.argv[argKeyIdx + 1] : apiKeyFromSource();
const BASE = 'https://api.deepseek.com/chat/completions';

if (!API_KEY) {
  console.error('未找到 API 密钥。');
  console.error('  密钥应在 entry/src/main/ets/common/LocalKey.ets 里（该文件不入库）。');
  console.error('  若文件不存在，先执行：');
  console.error('    cp entry/src/main/ets/common/LocalKey.ets.example \\');
  console.error('       entry/src/main/ets/common/LocalKey.ets');
  console.error('  然后填入 sk- 密钥；或用 --key sk-xxx 直接指定。');
  process.exit(1);
}
console.log('使用密钥: ' + API_KEY.substring(0, 7) + '…' + API_KEY.slice(-4) + '\n');

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
const http = { createHttp: () => ({ request: async () => ({responseCode:200, result:''}), destroy(){} }) };
const MAX_SEND_MSGS = 24, MAX_STORED_MSGS = 200, MAX_SESSIONS = 30;
const Store = { async get(){ return ''; }, async put(){}, async remove(){} };
const Keys = {};
`;

const api = await loadEts('model/ApiClient.ets', [
  'export class SseDecoder', 'export class SseChunk', 'export class ToolCallAccum',
  'export class ErrMapper', 'export class ApiClient', 'export function parseQuery',
  'export class SearchTools'
], PRELUDE);

const search = await loadEts('model/SearchService.ets', [
  'export function parseBing', 'export function cleanText', 'export function formatForModel',
  'function extractBlocks', 'function firstTag', 'function firstParagraph',
  'function firstHref', 'function stripTagBlock'
], PRELUDE);

const store = await loadEts('model/ChatStore.ets', [
  'export function trimForSend', 'export function validateApiSequence'
], PRELUDE + '\nconst ChatStore = {};\n');

const { SseDecoder, SseChunk, ToolCallAccum, ErrMapper, ApiClient, parseQuery } = api;
const { parseBing, formatForModel } = search;
const { validateApiSequence } = store;

// ---------------------------------------------------------------------------
async function callApi(req, msgs) {
  const body = ApiClient.buildBody(req, msgs);
  const r = await fetch(BASE, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'Authorization': 'Bearer ' + req.apiKey
    },
    body
  });
  const text = await r.text();
  return { status: r.status, body: text, sentBody: body };
}

function consume(text) {
  const dec = new SseDecoder();
  const acc = new ToolCallAccum();
  let content = '', reasoning = '', sawDone = false, frames = 0;
  for (const p of dec.feed(text)) {
    if (p === '[DONE]') { sawDone = true; break; }
    frames++;
    acc.ingest(p);
    const d = SseChunk.parse(p);
    if (d === null) continue;
    content += d.content;
    reasoning += d.reasoning;
  }
  return { content, reasoning, sawDone, frames, toolCalls: acc.list() };
}

// ---------------------------------------------------------------------------
console.log('1. 非流式对话');
{
  const msgs = [{ role: 'user', content: '只回复两个字：你好', ts: Date.now() }];
  const req = { apiKey: API_KEY, model: 'deepseek-flash', messages: msgs,
    stream: false, thinking: false, search: false };
  const r = await callApi(req, msgs);
  ok('HTTP 200', r.status === 200, 'status=' + r.status);
  let full = '';
  try { full = SseChunk.parseFull(r.body); } catch (e) { full = ''; }
  ok('能解析出正文', full.length > 0, 'content=' + JSON.stringify(full).substring(0, 60));
  ok('请求体含 thinking=disabled（显式关闭思考）',
    r.sentBody.includes('"thinking":{"type":"disabled"}'));
}

// ---------------------------------------------------------------------------
console.log('\n2. 流式对话');
{
  const msgs = [{ role: 'user', content: '从1数到5，只要数字', ts: Date.now() }];
  const req = { apiKey: API_KEY, model: 'deepseek-flash', messages: msgs,
    stream: true, thinking: false, search: false };
  const r = await callApi(req, msgs);
  ok('HTTP 200', r.status === 200, 'status=' + r.status);
  const c = consume(r.body);
  ok('收到多个 SSE 帧', c.frames >= 3, 'frames=' + c.frames);
  ok('以 [DONE] 结束', c.sawDone);
  ok('正文非空', c.content.length > 0, JSON.stringify(c.content).substring(0, 60));
  ok('关闭思考时无 reasoning', c.reasoning.length === 0, 'len=' + c.reasoning.length);
}

// ---------------------------------------------------------------------------
console.log('\n3. 思考模式（reasoning_content 应下发）');
{
  const msgs = [{ role: 'user', content: '1+1等于几', ts: Date.now() }];
  const req = { apiKey: API_KEY, model: 'deepseek-flash', messages: msgs,
    stream: true, thinking: true, search: false };
  const r = await callApi(req, msgs);
  ok('HTTP 200', r.status === 200, 'status=' + r.status);
  const c = consume(r.body);
  ok('收到 reasoning 内容', c.reasoning.length > 0, 'len=' + c.reasoning.length);
  ok('最终正文非空', c.content.length > 0, JSON.stringify(c.content).substring(0, 60));
}

// ---------------------------------------------------------------------------
console.log('\n4. ★ 联网搜索完整往返');
{
  const msgs = [{ role: 'user', content: '今天有什么科技新闻？用一句话说。', ts: Date.now() }];
  const req = { apiKey: API_KEY, model: 'deepseek-flash', messages: msgs,
    stream: true, thinking: false, search: true };

  const r1 = await callApi(req, msgs);
  ok('第一轮 HTTP 200', r1.status === 200, 'status=' + r1.status);
  ok('第一轮请求带上了 tools', r1.sentBody.includes('"tools"'));
  const c1 = consume(r1.body);
  ok('模型返回了 tool_calls', c1.toolCalls.length > 0,
    'content=' + JSON.stringify(c1.content).substring(0, 50));

  if (c1.toolCalls.length === 0) {
    console.log('    （模型这次没调工具，跳过搜索往返验证）');
  } else {
    const q = parseQuery(c1.toolCalls[0].arguments);
    ok('能解出搜索关键词', q.length > 0, 'query=' + JSON.stringify(q));
    console.log('    模型要搜: ' + q);

    let html = '';
    try {
      const url = 'https://cn.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-CN&ensearch=0';
      const br = await fetch(url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9'
        }
      });
      html = await br.text();
    } catch (e) {
      html = '';
    }
    ok('Bing 抓取成功', html.length > 0, 'len=' + html.length);
    const items = parseBing(html);
    ok('解析出搜索结果', items.length > 0, '条数=' + items.length);
    if (items.length > 0) {
      console.log('    取到 ' + items.length + ' 条，首条: ' + items[0].title.substring(0, 40));
    }
    const toolText = formatForModel(q, items.slice(0, 5));

    msgs.push({ role: 'assistant', content: '', toolCalls: c1.toolCalls, ts: Date.now() });
    msgs.push({ role: 'tool', content: toolText, toolCallId: c1.toolCalls[0].id, ts: Date.now() });

    const seqErrs = validateApiSequence(msgs);
    ok('回灌后的消息序列合法（真校验器）', seqErrs.length === 0, seqErrs.join('; '));

    const r2 = await callApi(req, msgs);
    ok('第二轮 HTTP 200', r2.status === 200, 'status=' + r2.status);
    if (r2.status !== 200) {
      console.log('    响应: ' + r2.body.substring(0, 300));
    }
    const c2 = consume(r2.body);
    ok('第二轮有正文回答', c2.content.length > 0, JSON.stringify(c2.content).substring(0, 80));
    if (c2.content.length > 0) {
      console.log('    最终回答: ' + c2.content.replace(/\n/g, ' ').substring(0, 100));
    }
  }
}

// ---------------------------------------------------------------------------
console.log('\n5. 错误路径（错误密钥）');
{
  const msgs = [{ role: 'user', content: 'hi', ts: Date.now() }];
  const req = { apiKey: 'sk-0000000000000000000000000000dead', model: 'deepseek-flash',
    messages: msgs, stream: false, thinking: false, search: false };
  const r = await callApi(req, msgs);
  ok('返回非 200', r.status !== 200, 'status=' + r.status);
  const em = ErrMapper.from(r.status, r.body);
  ok('分流为「鉴权失败」', em.code === -2, 'code=' + em.code);
  ok('文案指名密钥', em.message.includes('密钥'), em.message);
  console.log('    用户看到的文案: ' + em.message);
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
