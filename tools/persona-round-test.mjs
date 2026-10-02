/**
 * 人设（Persona）与圆屏几何的离线回归测试
 *
 * ★ 2026-10-03 新增。
 *
 * 为什么这两块要单独一套测试：
 *   · **人设**是新功能，唯一的「正确性证据」就是这里。它有两个容易错的地方：
 *     ① system prompt 的拼装（空字段怎么处理、尾部约束有没有）——
 *        错了不会报错，只会让模型表现怪，真机上很难定位；
 *     ② 与裁剪的**顺序**（先 trim 再 inject）—— 错了会静默少发一条对话。
 *   · **圆屏几何**是纯数学，算错了界面就是歪的/点不到，
 *     而且真机验证成本很高（要连手表、要截图量坐标）。
 *     这里用「与独立实现的公式对照」的方式锁住。
 *
 * ★ 纪律：本文件跑的是**真源码**（经 tools/ets-load.mjs 机械剥离），
 *   不是手抄的副本。任何断言失败都表示源码有问题，不是测试有问题。
 */

import { loadEts } from './ets-load.mjs';

// ========================================================================
//  迷你测试框架
// ========================================================================

let PASS = 0;
let FAIL = 0;
const FAILURES = [];

function ok(cond, name, extra = '') {
  if (cond) {
    PASS++;
  } else {
    FAIL++;
    FAILURES.push(name + (extra ? '  [' + extra + ']' : ''));
    console.log('  ✗ ' + name + (extra ? '  [' + extra + ']' : ''));
  }
}

function eq(actual, expected, name) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a === b) {
    PASS++;
  } else {
    FAIL++;
    const msg = name + '\n      期望: ' + b + '\n      实际: ' + a;
    FAILURES.push(name);
    console.log('  ✗ ' + msg);
  }
}

function group(title) {
  console.log('\n' + title);
}

// ========================================================================
//  加载被测源码
// ========================================================================

// Store / Keys 是 Preferences 封装，Node 里没有 —— 给一个内存替身。
// ★ 注意：替换的是**依赖**不是**被测逻辑**。PersonaStore 的序列化/CRUD
//   仍然跑真代码，只有底层 kv 是假的。
const storePrelude = `
const __mem = new Map();
class Store {
  static async init() {}
  static isReady() { return true; }
  static async put(k, v) { __mem.set(k, String(v)); }
  static async get(k, def = '') { return __mem.has(k) ? __mem.get(k) : def; }
  static async getChecked(k) { return { ok: true, value: __mem.has(k) ? __mem.get(k) : '' }; }
  static async remove(k) { __mem.delete(k); }
}
class Keys {
  static PERSONA_LIST = 'persona_list';
  static LAST_PERSONA = 'last_persona_id';
}
function __resetMem() { __mem.clear(); }
function __putRaw(k, v) { __mem.set(k, v); }
`;

const P = await loadEts(
  'model/Persona.ets',
  [
    // ★ 块顺序 = 源码依赖顺序。`PERSONA_FIELDS` 引用了 `PersonaField`，
    //   所以类必须排在常量前面（否则 TDZ 报「Cannot access before initialization」）。
    'export class PersonaField',
    'export const PERSONA_FIELDS',
    'export const NAME_MAX_LEN',
    'export const MAX_PERSONAS',
    'export function buildSystemPrompt',
    'function appendSeg',
    'export function validatePersona',
    'export function readField',
    'export function withField',
    'export function isBlank',
    'export function summaryOf',
    'export function defaultName',
    'export class PersonaSeq',
    'export function newPersona',
    'export function seedPersona',
    'export class PersonaStore',
    'export function encode',
    'export function decode',
    'function str',
    'function num',
  ],
  storePrelude,
  ['__resetMem', '__putRaw']
);
// Store 在 prelude 里，PersonaStore 用的是它 —— 但 loadEts 的 prelude 是文本注入，
// 上面的 __resetMem 已经在同一个作用域里了。
// 同时把 constants 里的 Role 也塞进来（ChatStore 的 injectSystem 需要）。

const CS = await loadEts(
  'model/ChatStore.ets',
  [
    'export function injectSystem',
    'export function isBlankPersona',
    'export function personaBadge',
    'export function needsFreshSession',
    'export function trimForSend',
    'export function validateApiSequence',
    'export const MAX_SEND_MSGS',
    'export const MAX_STORED_MSGS',
    'export const MAX_SESSIONS',
    'export class ChatStore',
    'function str',
    'function num',
  ],
  `
const __mem2 = new Map();
class Store {
  static async init() {}
  static isReady() { return true; }
  static async put(k, v) { __mem2.set(k, String(v)); }
  static async get(k, def = '') { return __mem2.has(k) ? __mem2.get(k) : def; }
  static async getChecked(k) { return { ok: true, value: __mem2.has(k) ? __mem2.get(k) : '' }; }
  static async remove(k) { __mem2.delete(k); }
}
class Keys {
  static SESSION_INDEX = 'session_index';
  static LAST_SESSION = 'last_session_id';
}
class Role {
  static SYSTEM = 'system';
  static USER = 'user';
  static ASSISTANT = 'assistant';
  static TOOL = 'tool';
}
// 测试用：直接往内存 kv 塞原始值（模拟「升级前存下来的老数据」）
function __putMem(k, v) { __mem2.set(k, v); }
function __resetMem2() { __mem2.clear(); }
`,
  ['__putMem', '__resetMem2', 'isBlankPersona', 'personaBadge', 'needsFreshSession']
);

const R = await loadEts(
  'common/RoundScreen.ets',
  [
    'export class Unit',
    'export class Round',
    'export class RadialHit',
    'export class RadialMenuState',
    'export enum FontScale',
    'export class Typo',
    'export class CrownSelector',
  ],
  '',
  ['FontScale', 'Typo', 'Round', 'Unit', 'CrownSelector', 'RadialHit', 'RadialMenuState']
);

// ========================================================================
//  1. system prompt 拼装
// ========================================================================

group('【1】buildSystemPrompt —— 四个字段拼装成结构化 prompt');

const full = {
  id: 'p1', name: '严谨助手', personality: '沉稳、直接',
  background: '十年经验的资深工程师',
  tone: '简洁，不说客套话',
  replyStyle: '先说结论，再分点',
  createdAt: 0, builtin: false
};

const sp1 = P.buildSystemPrompt(full);

ok(sp1.includes('「严谨助手」'), '1.1 开头声明角色名');
ok(sp1.includes('## 性格'), '1.2 含「## 性格」段落标签');
ok(sp1.includes('## 背景'), '1.3 含「## 背景」段落标签');
ok(sp1.includes('## 语气'), '1.4 含「## 语气」段落标签');
ok(sp1.includes('## 回复风格'), '1.5 含「## 回复风格」段落标签');
ok(sp1.includes('沉稳、直接'), '1.6 性格内容原样写入');
ok(sp1.includes('十年经验的资深工程师'), '1.7 背景内容原样写入');
ok(sp1.includes('简洁，不说客套话'), '1.8 语气内容原样写入');
ok(sp1.includes('先说结论，再分点'), '1.9 风格内容原样写入');

// ★ 标签必须**各出现一次**：重复出现说明拼装逻辑把字段叠了
eq(sp1.split('## 性格').length - 1, 1, '1.10 「## 性格」只出现一次');
eq(sp1.split('## 背景').length - 1, 1, '1.11 「## 背景」只出现一次');
eq(sp1.split('## 语气').length - 1, 1, '1.12 「## 语气」只出现一次');
eq(sp1.split('## 回复风格').length - 1, 1, '1.13 「## 回复风格」只出现一次');

// ★ 字段顺序：必须与 PERSONA_FIELDS 一致（性格→背景→语气→回复风格）
const iPer = sp1.indexOf('## 性格');
const iBg = sp1.indexOf('## 背景');
const iTone = sp1.indexOf('## 语气');
const iStyle = sp1.indexOf('## 回复风格');
ok(iPer < iBg && iBg < iTone && iTone < iStyle, '1.14 段落顺序 = 性格→背景→语气→回复风格');

// ★★ 尾部通用约束 —— 这是防「模型出戏」和「模型复述设定」的关键，缺了人设会很怪
ok(sp1.includes('不要跳出角色'), '1.15 含「不要跳出角色」约束');
ok(sp1.includes('不要提及') && sp1.includes('扮演'), '1.16 含「不要提及扮演」约束');
ok(sp1.includes('不要复述'), '1.17 含「不要复述设定」约束 —— 防模型把设定原文念给用户');
ok(sp1.includes('以用户的当前要求为准'), '1.18 含「冲突时以用户为准」兜底');

// ========================================================================

group('【2】buildSystemPrompt —— 空字段必须被省略，不能留「无」');

const partial = {
  id: 'p2', name: '半个', personality: '外向',
  background: '', tone: '   ', replyStyle: '',
  createdAt: 0, builtin: false
};
const sp2 = P.buildSystemPrompt(partial);

ok(sp2.includes('## 性格'), '2.1 有值的字段保留');
ok(!sp2.includes('## 背景'), '2.2 空字符串字段整段省略');
ok(!sp2.includes('## 语气'), '2.3 纯空白字段也省略（trim 后才判空）');
ok(!sp2.includes('## 回复风格'), '2.4 空字段省略');
ok(!sp2.includes('无'), '2.5 ★ 不产生「无」这种占位 —— 会让模型真去演「性格：无」');

// 四个字段全空 + 有名字 → 仍应产出可用的最小 prompt
const nameOnly = {
  id: 'p3', name: '只有名字', personality: '',
  background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false
};
const sp3 = P.buildSystemPrompt(nameOnly);
ok(sp3.length > 0, '2.6 只有名字时仍产出非空 prompt');
ok(sp3.includes('只有名字'), '2.7 包含名字');
ok(sp3.includes('不要跳出角色'), '2.8 仍带角色约束');

// 连名字都没有 → 明确返回空串（调用方据此跳过注入）
const nothing = {
  id: 'p4', name: '', personality: '',
  background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false
};
eq(P.buildSystemPrompt(nothing), '', '2.9 全空（含名字）→ 返回空串，调用方跳过注入');

// ========================================================================

group('【3】validatePersona —— 只拦「存不下去」的，不拦「填得少」');

ok(P.validatePersona(full).length === 0, '3.1 完整人设合法');
ok(P.validatePersona(nothing).length > 0, '3.2 没名字 → 报错');
ok(P.validatePersona(nameOnly).length === 0, '3.3 ★ 只有名字、四字段全空 → 合法（手表上打字成本高，不刁难用户）');
ok(P.validatePersona({ id: 'x', name: 'a'.repeat(P.NAME_MAX_LEN), personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }).length === 0,
  '3.4 名称恰好到上限 → 合法');
ok(P.validatePersona({ id: 'x', name: 'a'.repeat(P.NAME_MAX_LEN + 1), personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }).length > 0,
  '3.5 名称超上限 → 报错');
ok(P.validatePersona({ id: 'x', name: 'a\nb', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }).length > 0,
  '3.6 名称含换行 → 报错（列表里会撑破一行）');
ok(P.validatePersona({ id: 'x', name: '   ', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }).length > 0,
  '3.7 名称纯空白 → 报错');

// 超长字段
for (const f of P.PERSONA_FIELDS) {
  const over = { id: 'x', name: 'n', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false };
  const o2 = P.withField(over, f.key, 'x'.repeat(f.maxLen + 1));
  ok(P.validatePersona(o2).length > 0, '3.8 ' + f.label + ' 超上限 → 报错');
  const at = P.withField(over, f.key, 'x'.repeat(f.maxLen));
  ok(P.validatePersona(at).length === 0, '3.9 ' + f.label + ' 恰好到上限 → 合法');
}

// ========================================================================

group('【4】withField / readField —— 不可变更新');

const base = { id: 'q', name: 'N', personality: 'P', background: 'B', tone: 'T', replyStyle: 'S', createdAt: 1, builtin: false };

for (const f of P.PERSONA_FIELDS) {
  const next = P.withField(base, f.key, 'NEW');
  eq(P.readField(next, f.key), 'NEW', '4.1 withField(' + f.label + ') 写入生效');
  // ★ 其余字段必须保持不变 —— 写错字段名会静默丢数据
  for (const g of P.PERSONA_FIELDS) {
    if (g.key === f.key) continue;
    eq(P.readField(next, g.key), P.readField(base, g.key),
      '4.2 withField(' + f.label + ') 不改动 ' + g.label);
  }
  eq(next.id, base.id, '4.3 withField(' + f.label + ') 保持 id');
  eq(next.builtin, base.builtin, '4.4 withField(' + f.label + ') 保持 builtin');
  // ★ 必须是新对象（ArkUI @State 依赖引用变化）
  ok(next !== base, '4.5 withField(' + f.label + ') 返回新对象（不可变）');
}

// 未知 key 不应崩，也不应改任何东西
const unknown = P.withField(base, 'not_a_field', 'X');
eq(P.readField(unknown, 'personality'), base.personality, '4.6 未知字段名不误伤已有字段');

// ========================================================================

group('【5】isBlank / summaryOf');

ok(P.isBlank({ id: 'x', name: 'n', personality: '', background: '  ', tone: '', replyStyle: '', createdAt: 0, builtin: false }),
  '5.1 四字段全空白 → isBlank=true');
ok(!P.isBlank(full), '5.2 有内容 → isBlank=false');

eq(P.summaryOf({ id: 'x', name: 'n', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }),
  '未填写设定', '5.3 全空摘要 = 「未填写设定」');
ok(P.summaryOf(full).includes('性格：'), '5.4 摘要含字段标签');
ok(P.summaryOf(full).includes('沉稳、直接'), '5.5 摘要含字段值');
ok(!P.summaryOf(full).includes('背景：') === false, '5.6 摘要含背景');
// 换行必须被压掉（列表第二行只有一行高度）
const multi = { id: 'x', name: 'n', personality: 'a\nb\nc', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false };
ok(!P.summaryOf(multi).includes('\n'), '5.7 摘要里换行被压缩');

// ========================================================================

group('【6】defaultName / newPersona');

eq(P.defaultName([], 1), '人设1', '6.1 空列表 → 人设1');
eq(P.defaultName([{ id: 'a', name: '人设1', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }], 1),
  '人设2', '6.2 重名时往后顺延');
eq(P.defaultName([
  { id: 'a', name: '人设1', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false },
  { id: 'b', name: '人设2', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false },
], 1), '人设3', '6.3 连续重名时继续顺延');

const np = P.newPersona([]);
ok(np.id.length > 0, '6.4 新对象有 id');
ok(np.name.length > 0, '6.5 新对象有默认名');
ok(np.personality === '' && np.background === '' && np.tone === '' && np.replyStyle === '',
  '6.6 新对象四字段为空（用户自己填）');
eq(np.builtin, false, '6.7 新对象不是内置');

// ========================================================================

group('【7】PersonaStore CRUD —— 用真源码 + 内存 kv');

P.__resetMem();
const all0 = await P.PersonaStore.all();
eq(all0.length, 1, '7.1 冷启动种入 1 条默认人设');
eq(all0[0].name, '通用助手', '7.2 默认人设名 = 通用助手');

const saved = await P.PersonaStore.save(full);
eq(saved, true, '7.3 新增成功');
const all1 = await P.PersonaStore.all();
eq(all1.length, 2, '7.4 列表变 2 条');

// 更新（同 id 应替换而非追加）
const updated = P.withField(full, 'tone', '改过的语气');
await P.PersonaStore.save(updated);
const all2 = await P.PersonaStore.all();
eq(all2.length, 2, '7.5 同 id 保存是更新不是新增');
const got = await P.PersonaStore.get('p1');
eq(got.tone, '改过的语气', '7.6 更新内容正确');

eq(await P.PersonaStore.get('不存在的id'), null, '7.7 查不到返回 null');

// ★ 删除后再取，必须立刻失效（缓存要同步）
await P.PersonaStore.remove('p1');
eq(await P.PersonaStore.get('p1'), null, '7.8 删除后立即查不到（缓存已失效）');
eq((await P.PersonaStore.all()).length, 1, '7.9 删除后列表长度正确');

// 删空 → 必须再种一条，否则用户会卡在「无人设可选」
await P.PersonaStore.remove('p_default');
const all3 = await P.PersonaStore.all();
ok(all3.length >= 1, '7.10 ★ 删空后仍有可选人设（不会卡住）');

// 上限
P.__resetMem();
await P.PersonaStore.all();
let over = false;
for (let i = 0; i < P.MAX_PERSONAS + 5; i++) {
  const p = P.newPersona(await P.PersonaStore.all());
  const r = await P.PersonaStore.save(p);
  if (!r) { over = true; break; }
}
ok(over, '7.11 ★ 超过 MAX_PERSONAS 时保存被拒（返回 false，不是静默丢弃）');
ok((await P.PersonaStore.all()).length <= P.MAX_PERSONAS, '7.12 列表长度不超上限');

// 持久化往返（序列化不能丢字段）
// ★ 这里不直接读 kv（注入的闭包变量拿不到），而是靠「清缓存后重新 all()」
//   走一遍**真实的解码路径** —— 这比读原文更能证明「存进去的能读回来」。
//
// ★★ 2026-10-03 修正：原版只调 `__resetMem()` 就以为「存储清空了」，
//   但 `__resetMem` 清的是 kv，**`PersonaStore.loaded` 和 `cache` 还在**：
//   随后 `all()` 看到 `loaded===true` 直接返回旧 cache，既没重新种入
//   也没走 `persist()` —— 于是 kv 始终是空的，`invalidate()` 之后就什么都读不回来。
//   这是**测试自己的错**（忘了 invalidate），不是源码的错。
//   撤掉内存替身的状态时，必须把「kv」和「被测代码的缓存」**一起**复位。
P.__resetMem();
P.PersonaStore.invalidate();   // ★ 关键：同时丢掉 PersonaStore 的内存缓存
await P.PersonaStore.all();    // 重新种入 p_default 并持久化
await P.PersonaStore.save(full);
P.PersonaStore.invalidate();                    // 丢弃内存缓存
const reloaded = await P.PersonaStore.get('p1'); // 必然从存储反序列化
ok(reloaded !== null, '7.13 清缓存后仍能读回（已真正持久化）');
eq(reloaded !== null ? reloaded.name : '', '严谨助手', '7.14 名称往返无损');
eq(reloaded !== null ? reloaded.personality : '', '沉稳、直接', '7.15 ★ 中文字段值往返无损');
eq(reloaded !== null ? reloaded.replyStyle : '', '先说结论，再分点', '7.16 replyStyle 往返无损');
eq(reloaded !== null ? reloaded.builtin : true, false, '7.17 builtin 往返无损');

// decode 宽容性
eq(P.decode({}), null, '7.18 无 id 的项解码为 null（丢弃而不是崩）');
const dec = P.decode({ id: 'z', name: 'n' });
ok(dec !== null && dec.personality === '', '7.19 缺字段按空串处理');
ok(dec !== null && dec.builtin === false, '7.20 缺 builtin 按 false');
ok(dec !== null && dec.createdAt === 0, '7.21 缺 createdAt 按 0');

// 坏 JSON → 降级种入默认项，不卡死
P.__resetMem();
P.PersonaStore.invalidate();
// 通过 Store 塞一个坏值（Store 在 prelude 里，是同一个模块作用域内的类）
await P.__putRaw('persona_list', '{{{ 这不是 JSON');
const rec = await P.PersonaStore.all();
ok(rec.length >= 1, '7.22 ★ 存储损坏时降级为「种入默认项」而不是卡死');
ok(rec[0].name.length > 0, '7.23 降级后的人设有名字');

// ========================================================================
//  8. injectSystem + trimForSend 的顺序
// ========================================================================

group('【8】injectSystem —— 人设生效的唯一注入点');

const M = (role, content, extra = {}) => Object.assign({ role, content, ts: 1 }, extra);

const convo = [M('user', '你好'), M('assistant', '你好！')];

const injected = CS.injectSystem(convo, 'SYS');
eq(injected.length, 3, '8.1 注入后多一条');
eq(injected[0].role, 'system', '8.2 system 在最前面');
eq(injected[0].content, 'SYS', '8.3 system 内容正确');
eq(injected[1].role, 'user', '8.4 原消息顺序不变（1）');
eq(injected[2].role, 'assistant', '8.5 原消息顺序不变（2）');

// ★★ 空 prompt 必须什么都不做 —— 未绑定人设的老会话行为要逐字节一致
const noop = CS.injectSystem(convo, '');
eq(noop.length, 2, '8.6 ★ 空 prompt 不注入任何东西');
eq(CS.injectSystem(convo, '   ').length, 2, '8.7 ★ 纯空白 prompt 也不注入');

// ★ 不可变：入参不能被改（ArkUI @State 依赖引用变化）
const origLen = convo.length;
CS.injectSystem(convo, 'SYS2');
eq(convo.length, origLen, '8.8 ★ injectSystem 不修改入参（列表长度不变）');
ok(CS.injectSystem(convo, 'S') !== convo, '8.9 返回新数组');

// ★ 已有 system 时用「插入」而不是「替换」
const withSys = [M('system', '旧设定'), M('user', 'hi')];
const inj2 = CS.injectSystem(withSys, '新设定');
eq(inj2.length, 3, '8.10 已有 system 时是插入');
eq(inj2[0].content, '新设定', '8.11 新 system 在前');
eq(inj2[1].content, '旧设定', '8.12 ★ 旧 system 未被静默吃掉');

// ========================================================================

group('【9】顺序：必须先 trimForSend 再 injectSystem');

// 造一个「不裁剪也不会碰 tool 配对」的长会话
const longConvo = [];
for (let i = 0; i < 40; i++) {
  longConvo.push(M(i % 2 === 0 ? 'user' : 'assistant', 'm' + i));
}

const trimmed = CS.trimForSend(longConvo, 24);
eq(trimmed.length, 24, '9.1 裁剪到 24 条');
eq(CS.injectSystem(trimmed, 'SYS').length, 25, '9.2 裁剪后注入 → 25 条');

// ★★ 顺序纪律的真正含义（2026-10-03 修正，此前这条断言是**错的**）：
//
//   初版断言「先注入再裁剪会少一条真实对话」。实测证明**这是错的** ——
//   `trimForSend` 规则 1 明确写着「system 永远保留，且**不占 max 配额**」，
//   所以两种顺序得到的真实对话条数**完全一样**（都是 24）。
//   两条断言 `wrongReal <= rightReal` 与 `<= 24` 会恒真/恒假，
//   属于「看着在测，其实什么也没测」的假绿断言 —— 已删除。
//
//   但顺序纪律仍然要守，理由是**契约而非配额**：
//   · trim 的职责是「裁剪真实对话」，它要能看见真实的序列形态
//     （首条是不是 tool、末尾有没有孤立的 tool_calls）才能正确修正边界；
//     先注入会把一个 system 塞进序列头，虽然当前实现能正确跳过它，
//     但这依赖 trim 的「跳过首条 system」这一实现细节 ——
//     一旦 trim 的这段逻辑被改（比如改成只认 role 不认位置），
//     先注入就会静默出错。**先 trim 再 inject 不依赖任何内部细节。**
//   · 所以这里断言的是「两种顺序结果等价」+「正确顺序的输出契约」，
//     而不是去断言一个并不存在的配额差异。
const wrongOrder = CS.trimForSend(CS.injectSystem(longConvo, 'SYS'), 24);
const wrongReal = wrongOrder.filter(m => m.role !== 'system').length;
const rightReal = trimmed.length;
eq(wrongReal, rightReal,
  '9.3 ★ 两种顺序的真实对话条数相同（system 不占配额，见 trimForSend 规则 1）');
eq(wrongOrder.filter(m => m.role === 'system').length, 1,
  '9.4 ★ 错误顺序下 system 也还在（当前实现能跳过它）');

// 正确顺序下，system 一定在首位
eq(CS.injectSystem(trimmed, 'SYS')[0].role, 'system', '9.5 正确顺序：system 在首位');

// ★ 正确顺序下序列合法性不被破坏
eq(CS.validateApiSequence(CS.injectSystem(trimmed, 'SYS')).length, 0,
  '9.6 ★ 注入 system 后序列仍然合法');
eq(CS.validateApiSequence(CS.injectSystem([], 'SYS')).length, 0,
  '9.7 只注入 system（空对话）也合法');
// 空 prompt 时裁剪结果本身的合法性
eq(CS.validateApiSequence(trimmed).length, 0, '9.8 未注入时序列合法');

// ★ system 不算「tool 配对」的参与者，注入不能掩盖非法序列
const illegal = [M('tool', 'x', { toolCallId: 'c9' }), M('user', 'hi')];
ok(CS.validateApiSequence(illegal).length > 0, '9.9 非法序列被识别（首条 tool）');
ok(CS.validateApiSequence(CS.injectSystem(illegal, 'SYS')).length > 0,
  '9.10 ★ 注入 system 后非法序列仍非法（校验没被 injection 骗过）');

// 带 tool 配对的会话，注入后配对关系不变
const withTool = [
  M('user', 'q'),
  M('assistant', '', { toolCalls: [{ id: 'c1', name: 'web_search', arguments: '{}' }] }),
  M('tool', '结果', { toolCallId: 'c1' }),
  M('assistant', '答'),
];
eq(CS.validateApiSequence(withTool).length, 0, '9.11 带 tool 的会话本身合法');
eq(CS.validateApiSequence(CS.injectSystem(withTool, 'SYS')).length, 0,
  '9.12 ★ 注入 system 后 tool 配对仍完整');

// ========================================================================
//  10. 圆屏几何 —— 与独立实现的公式对照
// ========================================================================

group('【10】圆屏几何 —— 安全弦宽必须等于圆方程');

// 独立实现（不复用被测代码），刻意用「物理弦宽 × 安全系数」的等价写法，
// 避免和被测实现共享同一个错误。
const R_PX = 233;
const CY = 233;
const SAFE = 0.88;
function refSafeWidth(y) {
  const r = R_PX * SAFE;
  const d = Math.min(Math.abs(y - CY), r);
  return 2 * Math.sqrt(Math.max(0, r * r - d * d));
}
function refPhysicalWidth(y) {
  const d = Math.min(Math.abs(y - CY), R_PX);
  return 2 * Math.sqrt(Math.max(0, R_PX * R_PX - d * d));
}

// 先验证参照实现与「记忆里的实测值」一致 —— 如果这一步失败，
// 说明我记的实测值有问题，而不是源码有问题。
//
// ★ 2026-10-03 修正：y=428 原记为 262px，实测应为 255.1px。
//   教训：**圆方程是权威，手抄的实测值不是**。当时是目测读数，
//   误差 7px（约 3%）—— 在「要不要把按钮放下」这种判断上足够翻盘，
//   所以凡是拿实测值当断言的，先跑一遍圆方程对账。
const MEMO = [
  [415, 291], [428, 255], [450, 170], [466, 0],
];
for (const [y, expected] of MEMO) {
  const got = refPhysicalWidth(y);
  ok(Math.abs(got - expected) <= 1,
    '10.1 参照实现与实测弦宽吻合 y=' + y + '（期望≈' + expected + '，算得 ' + got.toFixed(1) + '）');
}

// 安全弦宽：逐点与参照实现对照
for (const y of [28, 60, 120, 200, 233, 280, 350, 400, 415, 428, 436, 450, 466]) {
  const got = R.Round.safeWidthAtY(y);
  const exp = refSafeWidth(y);
  ok(Math.abs(got - exp) < 1e-6,
    '10.2 safeWidthAtY(' + y + ') 与圆方程一致（' + got.toFixed(2) + '）');
}

// 关键性质
ok(R.Round.safeWidthAtY(CY) > 0, '10.3 圆心处弦宽 > 0');
ok(Math.abs(R.Round.safeWidthAtY(CY) - R.Round.safeRadius * 2) < 1e-6,
  '10.4 ★ 圆心处弦宽 = 安全直径（最大值）');
ok(R.Round.safeWidthAtY(0) === 0, '10.5 屏幕顶端弦宽 = 0');
ok(R.Round.safeWidthAtY(466) === 0, '10.6 屏幕底端弦宽 = 0');

// ★ 单调性：从圆心往两端必须单调递减（圆屏排版的前提）
let mono = true;
for (let y = CY; y < 466; y++) {
  if (R.Round.safeWidthAtY(y + 1) > R.Round.safeWidthAtY(y) + 1e-9) { mono = false; break; }
}
ok(mono, '10.7 ★ 圆心→底部 弦宽单调不增');
mono = true;
for (let y = CY; y > 0; y--) {
  if (R.Round.safeWidthAtY(y - 1) > R.Round.safeWidthAtY(y) + 1e-9) { mono = false; break; }
}
ok(mono, '10.8 ★ 圆心→顶部 弦宽单调不增');

// ★ 对称性
for (const d of [10, 50, 100, 150, 200]) {
  ok(Math.abs(R.Round.safeWidthAtY(CY - d) - R.Round.safeWidthAtY(CY + d)) < 1e-6,
    '10.9 上下对称（偏移 ' + d + 'px）');
}

// ========================================================================

group('【11】wPctAtY / blockPct —— 不能超过真实可用宽度');

// ★★ 这组断言 2026-10-03 修过一次，原因是**测试自己写错了单位**：
//   源码 `wPctAtY(yVp, padVp)` 收的是 **vp**，内部 `vp2px` 后算 px。
//   旧测试又把 yVp 乘了一遍 2，于是 y=233vp 被当成 466px（屏幕最底端，
//   安全弦宽 = 0），availPx 变成负数，断言当然失败 —— **测的是错的坐标**。
//   现在统一：只传 vp，px 换算只用 Unit.vp2px 一处。
//
// 可测范围也收敛到「安全圆内」：safeTop≈28px、safeBottom≈438px。
// 超出这个范围弦宽本来就是 0，百分比只能靠 20% 下限兜底，
// 拿它去比对「不超过可用宽度」是没意义的（20% 下限本身就是**故意**越界的兜底）。
const SAFE_TOP_PX = CY - R_PX * SAFE;   // ≈ 27.96
const SAFE_BOT_PX = CY + R_PX * SAFE;   // ≈ 438.04

// ★ 可测范围：**只在 20% 下限不生效的区间**断言「不超过可用宽度」。
//   下限附近的 y（安全圆顶部收口处）可用宽度本来就 < 93px（=20% 屏宽），
//   此时函数**故意**返回 20% —— 那是有意为之的兜底，不是越界 bug。
//   所以这类点单独断言「返回 20%」，不放进「不超过可用宽度」这组。
const floorZone = [];
const normalZone = [];
for (const yVp of [14, 16, 20, 25, 30, 40, 50, 75, 100, 116, 133, 150, 180, 200, 207]) {
  const pctStr = R.Round.wPctAtY(yVp, 6);
  const pct = parseFloat(pctStr);
  ok(pctStr.endsWith('%'), '11.1 返回百分比字符串（y=' + yVp + 'vp → ' + pctStr + '）');

  const yPx = R.Unit.vp2px(yVp);                 // vp → px，只此一处换算
  const availPx = refSafeWidth(yPx) - 12 * 2;  // padVp=6 → 左右各 12px
  const claimedPx = pct / 100 * 466;

  if (claimedPx > availPx + 1.5) {
    // 只允许一种「越界」：刚好等于 20% 下限
    ok(Math.abs(pct - 20) < 1e-9,
      '11.2a y=' + yVp + 'vp 越界时**只允许**是 20% 下限（实际 ' + pctStr + '）');
    floorZone.push(yVp);
  } else {
    ok(claimedPx <= availPx + 1.5,
      '11.2 ★ y=' + yVp + 'vp 声称宽度 ' + claimedPx.toFixed(1) + 'px ≤ 可用 ' + availPx.toFixed(1) + 'px');
    normalZone.push(yVp);
  }
}
// 说明：下限区必须存在（否则说明安全系数算错了，圆顶不会被收口）
ok(floorZone.length >= 1, '11.2d 安全圆顶部收口区确实由 20% 下限兜底（y=' + floorZone.join(',') + 'vp）');
ok(normalZone.length >= 10, '11.2e 大部分位置走真实几何计算（' + normalZone.length + ' 个采样点）');

// ★ 安全圆外（弦宽=0）：必须退到 20% 下限，且**不得**声称 0%（0 宽 = 布局崩塌）
ok(parseFloat(R.Round.wPctAtY(233)) === 20, '11.2b ★ 安全圆外退到 20% 下限，不成 0');
ok(parseFloat(R.Round.wPctAtY(0)) === 20, '11.2c ★ 屏幕顶端也是 20% 下限');

// 下限兜底（避免出现 3% 这种诡异值）
ok(parseFloat(R.Round.wPctAtY(260)) >= 20, '11.3 极端位置的百分比有下限兜底（≥20%）');

// 上限兜底：再宽也不能超过 100%
for (const yVp of [100, 116, 120, 130]) {
  ok(parseFloat(R.Round.wPctAtY(yVp, 0)) <= 100,
    '11.3b y=' + yVp + 'vp pad=0 时不超过 100%（' + R.Round.wPctAtY(yVp, 0) + '）');
}

// blockPct 取最窄处：区间越靠下，结果越小
const bTop = parseFloat(R.Round.blockPct(60, 120, 6));
const bBot = parseFloat(R.Round.blockPct(150, 207, 6));
ok(bBot < bTop, '11.4 ★ blockPct 取区间最窄处（越靠下越窄）');
// 端点为 0 宽的区间不应崩
ok(parseFloat(R.Round.blockPct(200, 233, 6)) >= 20, '11.5 区间触及屏幕底部时仍返回可用值');

// ★ blockPct 必须 ≤ 区间内任一点的 wPctAtY（「取最窄处」的定义）
for (const [t, b] of [[60, 120], [120, 180], [150, 207]]) {
  const bp = parseFloat(R.Round.blockPct(t, b, 6));
  let worst = Infinity;
  for (let y = t; y <= b; y += 1) {
    const w = parseFloat(R.Round.wPctAtY(y, 6));
    if (w < worst) worst = w;
  }
  ok(bp <= worst + 1,
    '11.5b ★ blockPct(' + t + ',' + b + ')=' + bp + ' ≤ 区间逐点最小 ' + worst);
}

group('【11b】rowPct 逐行宽度（长列表专用）');

// ★ rowPct 的语义是「把可点击行均分到安全圆的上半/下半」。
//   这里不假设它一定递减 —— 因为**跨过圆心后**弦宽会重新变大。
//   旧断言「逐行不增」在 y 跨过圆心时必然失败（那是圆的正确行为，不是 bug）。
//   真正要守的性质是：±(圆心) 对称的行**宽度相同**，且越远离圆心越窄。
const TOTAL = 10;
const rows = [];
for (let i = 0; i < TOTAL; i++) rows.push(parseFloat(R.Round.rowPct(i, TOTAL)));

// 对称性：第 i 行 与 倒数第 i 行，关于圆心对称 → 宽度应相等
let symOK = true;
const bad = [];
for (let i = 0; i < Math.floor(TOTAL / 2); i++) {
  const a = rows[i];
  const b = rows[TOTAL - 1 - i];
  if (Math.abs(a - b) > 1.5) { symOK = false; bad.push(i + '/' + (TOTAL - 1 - i) + ':' + a + 'vs' + b); }
}
ok(symOK, '11.6 ★ rowPct 关于圆心对称的行宽度相等（' + (bad.length ? bad.join(' ') : '全部通过') + '）');

// 从圆心向两端单调不增（先找最宽的那一行，即中心行）
let peak = 0;
for (let i = 1; i < TOTAL; i++) if (rows[i] > rows[peak]) peak = i;
let monoOut = true;
for (let i = peak; i + 1 < TOTAL; i++) if (rows[i + 1] > rows[i] + 1e-9) monoOut = false;
for (let i = peak; i > 0; i--) if (rows[i - 1] > rows[i] + 1e-9) monoOut = false;
ok(monoOut, '11.6b ★ rowPct 从中心行向两端单调不增（峰值在第 ' + peak + ' 行）');

// ========================================================================

group('【12】手势区与舒适线');

eq(R.Round.fitsAboveGesture(218), true, '12.1 218vp(=436px) 在硬上限上 → 允许');
eq(R.Round.fitsAboveGesture(218.5), false, '12.2 超过 436px → 拒绝');
eq(R.Round.fitsAboveGesture(207), true, '12.3 ★ 207vp(=414px) 在舒适线内 → 推荐');

eq(R.Round.safeBottomPx, 436, '12.4 硬上限 = 436px');
eq(R.Round.comfortBottomPx, 415, '12.5 ★ 舒适线 = 415px（此处物理弦宽 291px，放得下按钮）');
eq(R.Round.gestureTopPx, 450, '12.6 系统手势区起点 = 450px');

// ★ 舒适线处的物理弦宽必须够放一个按钮
const wAtComfort = refPhysicalWidth(415);
ok(wAtComfort >= 280, '12.7 ★ 舒适线处物理弦宽 ' + wAtComfort.toFixed(0) + 'px 足够放主按钮');
// 硬上限处已经很窄了 —— 这正是「硬上限 ≠ 可用」的证据
const wAtHard = refPhysicalWidth(436);
ok(wAtHard < wAtComfort, '12.8 硬上限处弦宽更窄（' + wAtHard.toFixed(0) + 'px < '
  + wAtComfort.toFixed(0) + 'px）');

// bottomUsable 必须 ≤ 该位置的安全弦宽
for (const yTopPx of [300, 350, 380, 400, 415]) {
  const u = R.Round.bottomUsablePx(yTopPx, 10);
  const cap = refSafeWidth(Math.min(yTopPx, 415)) - 20;
  ok(u <= cap + 1e-6, '12.9 bottomUsablePx(' + yTopPx + ')=' + u.toFixed(1)
    + ' ≤ 安全弦宽 ' + cap.toFixed(1));
  ok(u >= 0, '12.10 bottomUsablePx(' + yTopPx + ') 非负');
}
// 越往下可用宽度越小
ok(R.Round.bottomUsablePx(400) <= R.Round.bottomUsablePx(350),
  '12.11 bottomUsablePx 随 y 单调不增');

// 单位换算
eq(R.Unit.vp2px(1), 2, '12.12 1vp = 2px');
eq(R.Unit.px2vp(466), 233, '12.13 466px = 233vp');
eq(R.Unit.px2vp(R.Unit.vp2px(37)), 37, '12.14 vp/px 往返一致');

// ========================================================================

group('【13】CrownSelector —— 表冠驱动的选择器');

const sel = new R.CrownSelector(4, true);
eq(sel.index, 0, '13.1 初始选中 0');
eq(sel.feed(1), true, '13.2 向右一步 → 变化');
eq(sel.index, 1, '13.3 选中 1');
sel.feed(1); sel.feed(1);
eq(sel.index, 3, '13.4 到末尾');
sel.feed(1);
eq(sel.index, 0, '13.5 ★ loop=true 时回到第一项');
sel.feed(-1);
eq(sel.index, 3, '13.6 ★ 反向也从末尾绕回');
eq(sel.feed(0), false, '13.7 0 步不产生变化');

// 大步长
const sel2 = new R.CrownSelector(4, true);
sel2.feed(9);
eq(sel2.index, 1, '13.8 大步长取模正确（9 % 4）');

// 不循环
const sel3 = new R.CrownSelector(3, false);
sel3.feed(10);
eq(sel3.index, 2, '13.9 ★ loop=false 到头停住（不绕回）');
sel3.feed(-10);
eq(sel3.index, 0, '13.10 loop=false 反向也停住');

// 空列表不崩
const sel4 = new R.CrownSelector(0, true);
eq(sel4.feed(1), false, '13.11 空列表 feed 无效果');
eq(sel4.index, 0, '13.12 空列表索引保持 0');

// select
const sel5 = new R.CrownSelector(4, true);
eq(sel5.select(2), true, '13.13 select 生效');
eq(sel5.index, 2, '13.14 索引更新');
eq(sel5.select(2), false, '13.15 选同一项无变化');
eq(sel5.select(99), false, '13.16 越界被拒');
eq(sel5.select(-1), false, '13.17 负数被拒');
eq(sel5.index, 2, '13.18 非法 select 不破坏状态');

// ========================================================================
//  14. 会话绑定人设 —— personaId 字段与向后兼容
// ========================================================================

group('【14】会话绑定人设（Session.personaId + 向后兼容）');

// ★ 新会话带上 personaId
const sWithPersona = await CS.ChatStore.create('p_abc');
eq(sWithPersona.personaId, 'p_abc', '14.1 新建会话能绑定人设');
eq(sWithPersona.messages.length, 0, '14.2 新会话消息为空');

// ★ 默认参数：不传 personaId 时是空串（旧调用点不用改）
const sDefault = await CS.ChatStore.create();
eq(sDefault.personaId, '', '14.3 ★ 不传 personaId 时为空串（旧调用点零改动）');

// ★ 存读往返：personaId 不能丢
await CS.ChatStore.save(sWithPersona);
const reloaded14 = await CS.ChatStore.load(sWithPersona.id);
ok(reloaded14 !== null, '14.4 会话能读回');
eq(reloaded14 !== null ? reloaded14.personaId : 'X', 'p_abc', '14.5 ★ personaId 往返无损');

// ★★ 向后兼容：**升级前存的老会话**（JSON 里没有 personaId 键）
//   这是本组最重要的断言 —— 老用户升级后不能读不出会话。
//   直接往 kv 里塞一份「没有 personaId 字段」的会话 JSON。
const legacyJson = JSON.stringify({
  id: 's_legacy', title: '老对话',
  createdAt: 1000, updatedAt: 2000,
  messages: [{ role: 'user', content: '旧消息', ts: 1000 }]
  // ← 故意没有 personaId
});
await CS.__putMem(CS.ChatStore.msgKey('s_legacy'), legacyJson);
const legacy = await CS.ChatStore.load('s_legacy');
ok(legacy !== null, '14.6 ★ 老会话（无 personaId 字段）仍能读出');
eq(legacy !== null ? legacy.personaId : 'X', '',
  '14.7 ★★ 老会话 personaId 自动补为空串（不因多字段而读不出）');
eq(legacy !== null ? legacy.messages.length : -1, 1, '14.8 老会话消息完整');
eq(legacy !== null ? legacy.messages[0].content : '', '旧消息', '14.9 老会话内容无损');

// ★ 空 personaId 的会话 → 发出去的序列与「无人设」完全一致
const noPersonaSend = CS.injectSystem(
  CS.trimForSend(legacy !== null ? legacy.messages : [], 24), '');
eq(noPersonaSend.length, 1, '14.10 ★ 未绑定人设时不注入 system（序列不变）');
ok(noPersonaSend.every(m => m.role !== 'system'),
  '14.11 ★ 未绑定人设时序列里没有 system（升级前后逐字节一致）');

// ========================================================================
//  15. 径向菜单几何 —— 命中判定与渲染必须用同一套角度基准
// ========================================================================

group('【15】RadialHit / RadialMenuState —— 圆环菜单');

// 角度基准：0° = 正上方，顺时针。这是判定与渲染的共同基准，
// 错了会表现成「点 A 选中 B」—— 用户最难忍受的一类 Bug。
eq(Math.round(R.RadialHit.angleOf(0, -100)), 0, '15.1 正上方 = 0°');
eq(Math.round(R.RadialHit.angleOf(100, 0)), 90, '15.2 正右方 = 90°');
eq(Math.round(R.RadialHit.angleOf(0, 100)), 180, '15.3 正下方 = 180°');
eq(Math.round(R.RadialHit.angleOf(-100, 0)), 270, '15.4 正左方 = 270°');
eq(R.RadialHit.angleOf(0, 0), 0, '15.5 圆心处不崩（返回 0）');

// 角度范围必须规范到 [0, 360)
let inRange = true;
for (let i = 0; i < 72; i++) {
  const a = R.RadialHit.angleOf(Math.cos(i / 72 * 6.283), Math.sin(i / 72 * 6.283));
  if (a < 0 || a >= 360) inRange = false;
}
ok(inRange, '15.6 ★ 任意方向的角度都归一化到 [0,360)');

// ★★ 四扇区：四个正方向必须命中四个不同扇区
const C4 = 4, RIN = 40, ROUT = 200;
eq(R.RadialHit.indexAt(0, -100, C4, RIN, ROUT), 0, '15.7 上方 → 扇区 0');
eq(R.RadialHit.indexAt(100, 0, C4, RIN, ROUT), 1, '15.8 右方 → 扇区 1');
eq(R.RadialHit.indexAt(0, 100, C4, RIN, ROUT), 2, '15.9 下方 → 扇区 2');
eq(R.RadialHit.indexAt(-100, 0, C4, RIN, ROUT), 3, '15.10 左方 → 扇区 3');

// ★ 环形约束：太靠内 / 太靠外都不响应
eq(R.RadialHit.indexAt(0, -10, C4, RIN, ROUT), -1, '15.11 ★ 半径 < innerR → 中心区，返回 -1');
eq(R.RadialHit.indexAt(0, -300, C4, RIN, ROUT), -1, '15.12 ★ 半径 > outerR → 不响应');
eq(R.RadialHit.indexAt(0, -RIN, C4, RIN, ROUT), 0, '15.13 正好在内环上 → 命中（闭区间）');
eq(R.RadialHit.indexAt(0, -ROUT, C4, RIN, ROUT), 0, '15.14 正好在外环上 → 命中（闭区间）');
eq(R.RadialHit.indexAt(0, -39.9, C4, RIN, ROUT), -1, '15.15 内环内 0.1px → 不命中');

// ★★ 判定与渲染互逆：拿到扇区中心角 → 反算坐标 → 必须命中同一扇区
//   这是「点哪儿选哪儿」的形式化保证。
let roundTripOk = true;
for (let count = 3; count <= 8; count++) {
  for (let i = 0; i < count; i++) {
    const ang = R.RadialHit.centerAngleOf(i, count);
    const off = R.RadialHit.offsetOf(ang, 100);
    const hit = R.RadialHit.indexAt(off[0], off[1], count, RIN, ROUT);
    if (hit !== i) roundTripOk = false;
  }
}
ok(roundTripOk, '15.16 ★★ 扇形中心角 → 坐标 → 命中回同一扇区（3~8 项全覆盖）');

// ★ 每个扇区都能被命中（不存在"死扇区"）
let allHit = true;
for (let i = 0; i < C4; i++) {
  const ang = R.RadialHit.centerAngleOf(i, C4);
  const off = R.RadialHit.offsetOf(ang, 120);
  if (R.RadialHit.indexAt(off[0], off[1], C4, RIN, ROUT) !== i) allHit = false;
}
ok(allHit, '15.17 ★ 四个扇区都可命中（无死区）');

// 边界归属：正好在分界线上归前一个扇区（左闭右开）
eq(R.RadialHit.indexAt(0, -100, C4, RIN, ROUT), 0, '15.18 0° 分界线 → 扇区 0');
const off45 = R.RadialHit.offsetOf(45, 100);
eq(R.RadialHit.indexAt(off45[0], off45[1], C4, RIN, ROUT), 0,
  '15.19 ★ 45° 分界线归前一扇区（左闭右开，确定行为）');

// 退化输入
eq(R.RadialHit.indexAt(0, -100, 0, RIN, ROUT), -1, '15.20 count=0 → -1');
eq(R.RadialHit.indexAt(0, -100, 1, RIN, ROUT), 0, '15.21 count=1 → 恒 0');
eq(R.RadialHit.indexAt(0, -100, 2, RIN, ROUT), 0, '15.22 count=2 上方 → 0');
eq(R.RadialHit.indexAt(0, 100, 2, RIN, ROUT), 1, '15.23 count=2 下方 → 1');

// 三扇区（最少的正常环形菜单）
eq(R.RadialHit.indexAt(0, -100, 3, RIN, ROUT), 0, '15.24 三扇区 上方 → 0');
const off120 = R.RadialHit.offsetOf(120, 100);
eq(R.RadialHit.indexAt(off120[0], off120[1], 3, RIN, ROUT), 1, '15.25 三扇区 120° → 1');
const off240 = R.RadialHit.offsetOf(240, 100);
eq(R.RadialHit.indexAt(off240[0], off240[1], 3, RIN, ROUT), 2, '15.26 三扇区 240° → 2');

// ---- 表冠驱动状态 ----

const rm = new R.RadialMenuState(4);
eq(rm.open, false, '15.27 初始未展开');
eq(rm.feed(1), false, '15.28 ★ 未展开时表冠不改变选中（避免误操作）');
rm.show();
eq(rm.open, true, '15.29 show() 展开');
eq(rm.index, 0, '15.30 展开时重置到第 0 项');
eq(rm.feed(1), true, '15.31 展开后表冠生效');
eq(rm.index, 1, '15.32 选中前进');
rm.feed(3);
eq(rm.index, 0, '15.33 ★ 环形一定循环（1+3=4 → 0）');
rm.feed(-1);
eq(rm.index, 3, '15.34 ★ 反向从 0 绕到末尾');
eq(rm.feed(0), false, '15.35 0 步无变化');
rm.hide();
eq(rm.feed(1), false, '15.36 收起后表冠不再生效');

eq(rm.select(2), true, '15.37 select 生效');
eq(rm.index, 2, '15.38 索引更新');
eq(rm.select(2), false, '15.39 选同一项无变化');
eq(rm.select(-1), false, '15.40 越界被拒');
eq(rm.select(9), false, '15.41 超上限被拒');
eq(rm.index, 2, '15.42 非法 select 不破坏状态');

const rm0 = new R.RadialMenuState(0);
rm0.show();
eq(rm0.feed(1), false, '15.43 空菜单 feed 无效果');

// ========================================================================
//  16. 人设切换与索引冗余 —— 会话列表要能不加载消息体就显示人设
// ========================================================================

group('【16】人设切换 / 索引冗余 / 换绑建议');

// ★ 索引里必须冗余存 personaId：否则列表页要把 30 条会话全读一遍
//
// ★★ 这段被注入测试抓出一个**假绿**（2026-10-03），值得记下来：
//
//   初版写法是 `create('p_idx')` → `__resetMem2()` → `save(sIdx)` → 查索引。
//   看起来在测「新增索引项」分支，实际不是：
//   `create()` 内部已经 `save()` 过一次，**索引缓存里已经有这条了**；
//   后面那次 `save()` 走的是**更新**分支（`e.personaId = s.personaId`）。
//   于是把 `idx.push` 里的 `personaId` 改成 `''`，测试**依然全绿** ——
//   因为 `idx.push` 那行根本没被执行过。
//
//   修法：**把两条分支分开测，各自用干净状态**。
//     · 新增分支：清空 kv **且** 让缓存失效，再 save 一条全新会话；
//     · 更新分支：见下面 16.6b/16.6c（换绑后索引要同步）。
//   ★ 纪律：`__resetMem2()` 清的是底层 kv，**清不掉 ChatStore 的内存缓存**；
//     凡是要测「首次写入」的用例，必须同时 `invalidate()`。
CS.__resetMem2();
CS.ChatStore.invalidate();
const sIdx = await CS.ChatStore.create('p_idx');
const idx16 = await CS.ChatStore.index();
let foundIdx = null;
for (const e of idx16) {
  if (e.id === sIdx.id) foundIdx = e;
}
ok(foundIdx !== null, '16.1 索引里能找到刚存的会话');
eq(foundIdx !== null ? foundIdx.personaId : 'X', 'p_idx',
  '16.2 ★★ 索引**新增**分支冗余存了 personaId（列表页不必加载消息体）');

// ★★ 老索引（升级前存的，没有 personaId 键）必须能读出来
//
// ★ 测试自身的坑（第一版踩了）：ChatStore.index() 有**内存缓存**
//   （`loaded` 标志），`__resetMem2()` 清的是底层 kv，
//   清不掉已经进 cache 的数组。所以第二次 index() 会直接返回上一次的缓存，
//   断言就永远测不到「老索引」这条路径。
//   用一个**全新进程内从未出现过的 id** 不行（cache 是整个数组）——
//   正确做法是用 ChatStore 的 `invalidate()` 明确让它重读。
CS.__resetMem2();
await CS.__putMem('session_index', JSON.stringify([
  { id: 's_old', title: '老对话', createdAt: 1, updatedAt: 2, count: 3 }
]));
CS.ChatStore.invalidate();
const legacyIdx = await CS.ChatStore.index();
ok(legacyIdx.length === 1, '16.3 ★ 老索引仍能读出（不因多字段而整条失败）');
eq(legacyIdx[0].personaId, '',
  '16.4 ★★ 老索引 personaId 自动补为空串（向前兼容）');
// 顺手把缓存恢复成干净状态，免得污染后面的用例
CS.__resetMem2();
CS.ChatStore.invalidate();

// ★ setPersona：换绑 + 落盘 + 索引同步
CS.__resetMem2();
const sSwap = await CS.ChatStore.create('p_a');
const changed = await CS.ChatStore.setPersona(sSwap.id, 'p_b');
eq(changed, true, '16.5 setPersona 换绑成功');
const sSwap2 = await CS.ChatStore.load(sSwap.id);
eq(sSwap2 !== null ? sSwap2.personaId : 'X', 'p_b', '16.6 ★ 换绑已落盘');

// ★★ 换绑后**索引**也必须跟着更新（注入测试抓出来的假绿，2026-10-03）
//
//   为什么这条一开始漏了：16.2 只覆盖了 `save()` 里「**新增**索引项」
//   那条分支（`idx.push({... personaId: s.personaId})`），
//   而换绑走的是「**更新**已有项」分支（`e.personaId = s.personaId`）——
//   把更新分支里的赋值删掉，16.2 依然全绿。
//   这正是注入测试存在的意义：**它发现了 16.2 只测了一半**。
//
//   症状类比：换完人设，历史列表里那条对话还显示旧人设名 ——
//   用户会以为"换了没用"。
CS.ChatStore.invalidate();
const idxSwap = await CS.ChatStore.index();
let swapEntry = null;
for (const e of idxSwap) {
  if (e.id === sSwap.id) swapEntry = e;
}
ok(swapEntry !== null, '16.6b 索引里仍能找到该会话');
eq(swapEntry !== null ? swapEntry.personaId : 'X', 'p_b',
  '16.6c ★★ 换绑后索引里的 personaId 同步更新（更新分支，不能只测新增分支）');

eq(await CS.ChatStore.setPersona(sSwap.id, 'p_b'), false,
  '16.7 ★ 换到同一个人设 → 返回 false（不做无谓写盘）');
eq(await CS.ChatStore.setPersona('不存在的会话', 'p_c'), false,
  '16.8 不存在的会话 → false，不抛');

// ★★ 换绑**不清空历史**（这是刻意的设计决定，见 setPersona 注释）
const sKeep = await CS.ChatStore.create('p_a');
const sKeepLoaded = await CS.ChatStore.load(sKeep.id);
if (sKeepLoaded !== null) {
  sKeepLoaded.messages.push({ role: 'user', content: '你好', ts: 1 });
  sKeepLoaded.messages.push({ role: 'assistant', content: '你好呀', ts: 2 });
  await CS.ChatStore.save(sKeepLoaded);
}
await CS.ChatStore.setPersona(sKeep.id, 'p_b');
const sKeepAfter = await CS.ChatStore.load(sKeep.id);
eq(sKeepAfter !== null ? sKeepAfter.messages.length : -1, 2,
  '16.9 ★★ 换人设**不清空历史**（换人设不该把聊天记录弄没）');
eq(sKeepAfter !== null ? sKeepAfter.personaId : 'X', 'p_b', '16.10 人设已更新');

// ---- 纯函数 ----

const pa = { id: 'a', name: '甲', personality: '沉稳', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false };
const pb = { id: 'b', name: '乙', personality: '活泼', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false };
const pBlank = { id: 'c', name: '空的', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false };

eq(CS.personaBadge(pa), '甲', '16.11 personaBadge 返回名称');
eq(CS.personaBadge(null), '', '16.12 ★ 未绑定 → 空串（调用方据此决定是否渲染）');
eq(CS.personaBadge({ id: 'x', name: '  ', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }),
  '未命名人设', '16.13 空白名字 → 兜底文案');

eq(CS.isBlankPersona(pa), false, '16.14 填了性格 → 非空白');
eq(CS.isBlankPersona(pBlank), true, '16.15 四字段全空 → 空白');
// ★ 16.16 的期望值修过一次（测试自己写错了）：
//   初版断言「只有名字 → isBlankPersona = false」，实际源码返回 true ——
//   因为 `isBlankPersona` 的语义是「**四个设定字段**是否全空」，
//   **不含名称**。这是刻意的设计（见源码注释）：
//   `needsFreshSession` 关心的是「有没有实质约束」，
//   只有名字的人设其实什么都没约束模型，所以应该算空白。
//   ★ 教训：断言与实现不符时，先读实现的注释确认语义，再决定改哪边 ——
//     这里源码是对的（有明确的设计理由），错的是我随手写的断言。
eq(CS.isBlankPersona({ id: 'x', name: '有名', personality: '', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }),
  true, '16.16 ★ 只有名字 → 仍算「无实质设定」（isBlank 只看四个设定字段）');
// 反过来：名称空但有设定 → 非空白
eq(CS.isBlankPersona({ id: 'x', name: '', personality: '沉稳', background: '', tone: '', replyStyle: '', createdAt: 0, builtin: false }),
  false, '16.16b 名称空但有性格 → 非空白（名称不参与判定）');

// ★★ needsFreshSession 的三条判据（这是「建议开新对话」的唯一依据）
eq(CS.needsFreshSession(null, pa), false,
  '16.17 ★ 原来没绑 → 现在绑上：不需要开新对话（是升级不是冲突）');
eq(CS.needsFreshSession(pa, null), false,
  '16.18 ★ 原来是 A → 换成未绑定：不需要（约束被解除，不冲突）');
eq(CS.needsFreshSession(pa, pa), false, '16.19 同一个人设 → 不需要');
eq(CS.needsFreshSession(pa, pBlank), false,
  '16.20 ★ A → 空白人设：不需要（新设定没内容，不会打架）');
eq(CS.needsFreshSession(pBlank, pa), false,
  '16.21 ★ 空白 → A：不需要');
eq(CS.needsFreshSession(pa, pb), true,
  '16.22 ★★ A → B 且两边都有设定：**需要**开新对话（历史里有旧口吻的回答）');
eq(CS.needsFreshSession(null, null), false, '16.23 两边都没绑 → 不需要');

// ========================================================================
//  汇总
// ========================================================================

console.log('\n' + '='.repeat(60));
if (FAIL === 0) {
  console.log('✅ 全部通过：' + PASS + ' 项');
  console.log('='.repeat(60));
  process.exit(0);
} else {
  console.log('❌ 失败 ' + FAIL + ' 项 / 通过 ' + PASS + ' 项');
  console.log('失败列表：');
  for (const f of FAILURES) console.log('   · ' + f);
  console.log('='.repeat(60));
  process.exit(1);
}
