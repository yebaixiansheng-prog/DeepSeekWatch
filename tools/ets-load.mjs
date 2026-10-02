/**
 * 通用 .ets → 可在 Node 里执行的 JS 加载器
 *
 * 为什么需要：
 *   离线回归测试必须跑**真源码**，不能跑「手抄的复制品」——
 *   历史上我抄错过 5 处，得出了错误的结论白排查很久（见旧 ets-loader.mjs 注释）。
 *   但 .ets 含 TS 类型标注 / ArkTS 专有 API，Node 直接 import 会语法错误。
 *   这一层只做**机械剥离**，不改任何逻辑。
 *
 * ★★ 剥离规则的核心纪律（这份文件的第一版就栽在这里）：
 *   `:` 在 TS 里既是「类型标注」又是「三元运算符」，`?.` 既是可选链又是可选参数。
 *   **大范围的正则一定会把真代码吃掉**，而且吃掉后**报的是语法错**（还算幸运），
 *   更糟的情况是「侥幸还是合法 JS 但语义变了」——那就彻底测不出来了。
 *
 *   所以这里的策略是：
 *     ① **只在明确的前缀上下文里替换**（如 `const x:` / `) : T {` / `= value as T`）；
 *     ② 先做**有界的**替换（行内表达式），不做跨行贪婪匹配；
 *     ③ 剥完立刻**语法检查**（`new Function`），一旦非法就抛错并指出是哪条规则，
 *        绝不把坏代码喂给测试 —— 宁可报错也不要测一个变异过的副本。
 */

import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dir = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dir, '..');
const ETS = ROOT + '/entry/src/main/ets';

/**
 * 剥离规则（顺序敏感）
 *
 * 每条规则都必须能通过「它不会碰任何真代码」的人工审查。
 * 类型名统一用 `[A-Za-z_$][\w$.]*(<...>)?(\[\])?` 这个受限模式，
 * 避免跨语句贪婪。
 */
const RULES = [
  // ---- 0. 注释与 import ----
  [/^import[\s\S]*?from\s+'[^']*';\s*$/gm, ''],

  // ---- 1. 修饰符（这些词在 ArkTS 里只作修饰符，安全） ----
  [/\bprivate\s+static\b/g, 'static'],
  [/\bpublic\s+static\b/g, 'static'],
  [/\bprivate\b/g, ''],
  [/\bpublic\b/g, ''],
  [/\bprotected\b/g, ''],
  [/\breadonly\s+/g, ''],

  // ---- 2. 泛型 new（`new Map<...>()` → `new Map()`） ----
  [/new\s+([A-Z]\w*)<[^<>()]*>\(/g, 'new $1('],

  // ---- 3. 泛型调用 foo<T>(...) → foo(...)  仅限单层尖括号 ----
  [/\b([a-z]\w*)<[A-Z]\w*(?:,\s*[A-Z]\w*)*>\(/g, '$1('],

  // ---- 4. 变量声明处的类型标注：`const x: T =` / `let x: T =` ----
  //    用「前置关键字」锁定上下文，不会碰到三元。
  //    ★ 必须支持联合类型 `T | null`（本工程大量使用），否则会残留。
  [/\b(const|let|var)\s+([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=/g,
    '$1 $2 ='],

  // ---- 5. 函数参数类型标注：`(a: T, b: U)` 与 `(a: T)` ----
  //    只在 **参数列表** 内替换：匹配 `( ... )` 且内部没有 `=>` 和 `?`（排除三元）
  //    这里用两轮：先处理最常见的「标识符: 类型」后跟 , 或 ) 或 = 的形式
  [/([\(,]\s*)([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*(?=[,\)])/g,
    '$1$2'],

  // ---- 6. 带默认值的参数：`a: T = v` ----
  [/([\(,]\s*)([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=/g,
    '$1$2 ='],

  // ---- 7. 可选参数 `a?: T` → `a` ----
  [/([\(,]\s*)([A-Za-z_$][\w$]*)\s*\?\s*:/g, '$1$2'],

  // ---- 8. 函数返回类型：`) : T {` （支持联合类型） ----
  [/\)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*\{/g,
    ') {'],

  // ---- 9. 箭头函数返回类型：`) : T =>` ----
  [/\)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=>/g,
    ') =>'],

  // ---- 10. 属性声明：类字段 `name: T = v;` / `name: T;` ----
  [/^(\s*)([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*;/gm,
    '$1$2;'],
  [/^(\s*)([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=/gm,
    '$1$2 ='],

  // ---- 11. 类型断言 `as T`（含联合与泛型） ----
  [/\s+as\s+[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*/g,
    ''],

  // ---- 11b. 剩余的函数返回类型（行尾 `): T {` 已被规则 8 处理；
  //      这里处理「方法签名跨行」的残留 `): T` 紧跟 `{` 之外的写法） ----
  [/\)\s*:\s*(?:Promise\s*<[^;{}()]*>|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?)*)\s*$/gm,
    ')'],

  // ---- 11c. 局部变量残留：`const x: T;`（无初始化，如 `let resp: http.HttpResponse;`） ----
  //    ★ 注意要在规则 12/13 之前，且必须允许带点的类型名（http.HttpResponse）
  [/^(\s*)(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?)*\s*;/gm,
    '$1let $2;'],

  // ---- 12. 接口/类型别名声明（整块删掉，运行时不需要） ----
  [/^export\s+interface\s+\w+[\s\S]*?\n\}/gm, ''],
  [/^interface\s+\w+[\s\S]*?\n\}/gm, ''],
  [/^export\s+type\s+\w+\s*=[\s\S]*?;\s*$/gm, ''],

  // ---- 13. export 关键字（统一在末尾手动导出） ----
  [/^export\s+/gm, ''],
];

/** ArkTS 专有 API 的替身化 */
function neutralizeArkApis(s) {
  return s
    .replace(/\bhilog\.(info|error|warn|debug)\(/g, 'noop(')
    .replace(/\bconsole\.(info|warn|error|log)\(/g, 'noop(');
}

/**
 * 从 .ets 原文里摘出一个顶层声明块，用大括号配平
 *
 * ★★ 关键细节（第一版栽在这）：**必须先剔除注释**再做括号配平。
 *   本工程的 JSDoc 里大量出现 `{ ... }`（例如「`{code, data:{...}}`」），
 *   如果直接把注释里的 `{` 计入深度，配平会**提前结束**，
 *   摘出来的函数只剩签名 —— 而且**语法仍然合法**（空函数体），
 *   于是测试会在「函数永远返回 undefined」的情况下跑绿。这是最危险的失败模式。
 */
export function extractBlock(src, header) {
  const at = src.indexOf(header);
  if (at < 0) {
    throw new Error('未找到锚点: ' + header);
  }
  const braceAt = src.indexOf('{', at);
  const head = src.substring(at, braceAt < 0 ? src.length : braceAt);
  // 无大括号的声明（const / type 别名）：取到行尾。
  // ⚠️ 判据只认「声明关键字 + 没有左大括号」，
  //    绝不能靠 `head.includes('=')` —— 函数签名里的**默认参数**
  //    （`max: number = 24`）也会命中，会把整个函数体丢掉。
  const isConstLike = /^\s*(export\s+)?(const|type|enum)\b/.test(head);
  if (braceAt < 0 || isConstLike) {
    const eol = src.indexOf('\n', at);
    return stripLineComments(src.substring(at, eol < 0 ? src.length : eol));
  }

  // 扫一遍，遇到注释就跳过（不参与括号计数）
  let depth = 0;
  let i = braceAt;
  let inBlock = false;   // /* ... */
  let inLine = false;    // // ...
  let inStr = '';        // 当前字符串定界符
  for (; i < src.length; i++) {
    const c = src[i];
    const n = src[i + 1];

    if (inLine) {
      if (c === '\n') inLine = false;
      continue;
    }
    if (inBlock) {
      if (c === '*' && n === '/') { inBlock = false; i++; }
      continue;
    }
    if (inStr !== '') {
      if (c === '\\') { i++; continue; }
      if (c === inStr) inStr = '';
      continue;
    }

    if (c === '/' && n === '/') { inLine = true; i++; continue; }
    if (c === '/' && n === '*') { inBlock = true; i++; continue; }
    if (c === '"' || c === '\'' || c === '`') { inStr = c; continue; }

    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) {
        let end = i + 1;
        if (src[end] === ';') end++;
        return src.substring(at, end);
      }
    }
  }
  throw new Error('括号不配平: ' + header);
}

function stripLineComments(s) {
  return s.replace(/\/\/.*$/gm, '');
}

/**
 * 加载一个 .ets 文件的若干块
 *
 * @param {string} relPath        相对 entry/src/main/ets 的路径
 * @param {string[]} blocks       要摘的声明头
 * @param {string} prelude        注入的替身代码
 * @param {string[]} extraExports 额外导出名
 */
export async function loadEts(relPath, blocks, prelude = '', extraExports = []) {
  const raw = readFileSync(path.join(ETS, relPath), 'utf8');

  // interface 运行时不存在，摘了会语法错 → 跳过
  const usable = blocks.filter(b => !b.startsWith('export interface') && !b.startsWith('interface'));

  let js = prelude + '\n';
  for (const b of usable) {
    js += extractBlock(raw, b) + '\n';
  }

  js = neutralizeArkApis(js);
  for (const [re, to] of RULES) {
    js = js.replace(re, to);
  }

  const names = [];
  for (const b of usable) {
    if (b.startsWith('export class ')) names.push(b.substring(13).split(/[\s{]/)[0].trim());
    else if (b.startsWith('export function ')) names.push(b.substring(16).split('(')[0].trim());
    else if (b.startsWith('export const ')) names.push(b.substring(13).split(/[=:]/)[0].trim());
  }
  for (const e of extraExports) names.push(e);

  const full = js + '\nexport { ' + names.join(', ') + ' };\n';

  // ★ 语法自检：剥离错了必须**立刻报错**，绝不把变异过的副本喂给测试
  try {
    // eslint-disable-next-line no-new-func
    new Function(full.replace(/^\s*(export|import)\s.*$/gm, ''));
  } catch (e) {
    const lines = full.split('\n');
    const bad = lines.findIndex(l => l.trim().length > 0);
    throw new Error('类型剥离后语法非法（说明剥离规则吃掉了真代码）:\n'
      + e.message + '\n--- 生成源码前 20 行 ---\n'
      + lines.slice(0, 20).join('\n'));
  }

  return await import('data:text/javascript;base64,' + Buffer.from(full, 'utf8').toString('base64'));
}

/** 调试用：把剥离后的源码写出来看 */
export function renderEts(relPath, blocks, prelude = '') {
  const raw = readFileSync(path.join(ETS, relPath), 'utf8');
  const usable = blocks.filter(b => !b.startsWith('export interface') && !b.startsWith('interface'));
  let js = prelude + '\n';
  for (const b of usable) {
    js += extractBlock(raw, b) + '\n';
  }
  js = neutralizeArkApis(js);
  for (const [re, to] of RULES) {
    js = js.replace(re, to);
  }
  return js;
}
