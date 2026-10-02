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
  //
  //    ★★ 这段的空白处理是本文件最微妙的地方（2026-10-03 反复踩了三次）：
  //
  //    ① **不允许跨行**（全用 `[ \t]*`）→ 多行参数列表里
  //       `round: number, handle: http.HttpRequest` 这种**换行续写**的参数
  //       匹配不到，类型残留 → `Unexpected token ':'`。
  //    ② **允许跨行**（用 `\s*`）→ `([\(,]\s*)` 会越过换行去抓
  //       **上一行末尾的逗号**，把下一行整行吃掉（规则 6 的坑）。
  //
  //    真正的分界是**「冒号后面跟的是什么」**：
  //    · 参数列表里，冒号后面一定是**类型名**（大写开头的标识符/泛型/数组）；
  //    · 被误伤时，冒号后面是**表达式的值**（小写变量、字符串、三元）。
  //    所以这里把「类型」约束成 **必须大写字母开头**，同时允许跨行。
  //    这样既认得出多行参数，又不会把 `name: key === A ? v : p.name` 吃掉
  //    （`key` 是小写，不匹配）。
  //
  //    ★ 为什么敢用「大写开头 = 类型」这个约定：
  //      这是 TypeScript 社区的通行写法，本工程也全程遵守；
  //      而且**万一认错了也只是漏剥一个类型**，会立刻被语法自检拦下，
  //      不会静默生成错误代码（宁可报错不可静默出错）。
  [/([\(,])\s*([A-Za-z_$][\w$]*)\s*:\s*[A-Z][\w$.]*(?:<[^;{}()<>]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Z][\w$.]*(?:<[^;{}()<>]*>)?(?:\[\])?))*\s*(?=[,\)])/g,
    '$1$2'],

  // ---- 5b. 参数列表里的**其他常见类型**也要剥 ----
  //    上面那条为防误伤要求类型名大写开头，但下面两类不满足：
  //      · 内置基本类型：`n: number` / `s: string` / `b: boolean` / `: void`
  //      · **命名空间限定的平台类型**：`h: http.HttpRequest`（小写开头！）
  //        —— 这是 HarmonyOS 的写法，`http` 是模块名不是类型名。
  //    所以这里显式枚举这些形态，**仍然只在紧跟 `,` 或 `)` 的上下文**生效。
  //
  //    ★ 为什么不会被 `name: key === A ? v : p.name,` 误伤：
  //      这条规则的「类型」部分必须是**枚举里列出的那几种字面形态**
  //      （number/string/... 或 `http.X`/`util.X` 这样的限定名），
  //      `key` 不在枚举里，`===` 也不在，所以匹配不上。
  //      也就是说：**白名单比黑名单安全** —— 宁可漏剥（会被语法自检拦下），
  //      也不要用一个宽泛的 `[A-Za-z_$][\w$.]*` 去猜（会吃真代码）。
  //
  //    ★ 数组后缀 `[]` 必须支持：`out: string[]` —— 漏了它就会残留
  //      `function appendSeg(out: string[], label, value)`（真实踩过）。
  [/([\(,])\s*([A-Za-z_$][\w$]*)\s*:\s*(?:number|string|boolean|void|any|unknown|never|object|Object|Function|symbol|bigint|http\.[A-Za-z_$][\w$]*|util\.[A-Za-z_$][\w$]*|window\.[A-Za-z_$][\w$]*)(?:\[\])*\s*(?=[,\)])/g,
    '$1$2'],

  // ---- 6. 带默认值的参数：`a: T = v` ----
  //    ★★ 这条规则是最容易误伤的一条，出过一个极隐蔽的错（2026-10-03）：
  //       对象字面量属性写成 `name: key === A ? v : p.name,` 时，
  //       `([\(,]\s*)` 匹配了**上一行末尾的逗号 + 换行缩进**，
  //       `[A-Za-z_$][\w$.]*` 匹配到 `key`，`\s*=` 匹配了 `===` 的**第一个等号**，
  //       于是整段被吃成 `name =`，剩下 `== A ? ...` → 生成非法代码
  //       `name === ...`（报错信息是 `Unexpected token '==='`，看着像别处的问题）。
  //       修法：`=` 后面必须**不是** `=` / `>`。
  //    ★★ 同样的坑在规则 10 的第二条里也有，一并加了同样的保护。
  [/([\(,])[ \t]*([A-Za-z_$][\w$]*)[ \t]*:[ \t]*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:[ \t]*\|[ \t]*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*[ \t]*=(?!=|>)/g,
    '$1$2 ='],

  // ---- 6b. 带修饰符的类字段 `static NAME: string = 'x';` / `static x: T;` ----
  //    ★ 原有规则 10 的 `^(\s*)([A-Za-z_$]\w*)` 只能匹配「行首就是字段名」，
  //      加了 `static`（或规则 1 删除 private/public 后残留的 static）就匹配不到，
  //      于是 `static NAME: string = 'name';` 原样留下 → Node 报
  //      `Unexpected strict mode reserved word`（看着像 static 的问题，其实是类型没剥掉）。
  //      这里补一条显式处理「修饰符 + 字段名 + 类型」的规则。
  [/^([ \t]*)static[ \t]+([A-Za-z_$][\w$]*)[ \t]*:[ \t]*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:[ \t]*\|[ \t]*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*[ \t]*(=|;)/gm,
    '$1static $2 $3'],

  // ---- 7. 可选参数 `a?: T` → `a` ----
  [/([\(,]\s*)([A-Za-z_$][\w$]*)\s*\?\s*:/g, '$1$2'],

  // ---- 8. 函数返回类型：`) : T {` （支持联合类型） ----
  [/\)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*\{/g,
    ') {'],

  // ---- 9. 箭头函数返回类型：`) : T =>` ----
  [/\)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=>/g,
    ') =>'],

  // ---- 10. 属性声明：类字段 `name: T = v;` / `name: T;` ----
  //    ★★ 这里有个极隐蔽的坑（2026-10-03）：末尾用 `\s*;` 会**跨行**匹配 ——
  //       `\s` 包含换行，于是对象字面量里 `createdAt: p.createdAt,` 会因为
  //       后面某行有 `};` 而被整段吃掉（从 `createdAt:` 一路吞到那个分号），
  //       生成 `createdAt,` 这种「看着像简写属性、实际变量未定义」的代码。
  //       它**语法合法**，所以能通过自检，只在运行时炸 `ReferenceError`。
  //       修法：行内空白用 `[ \t]*`，绝不用 `\s*`。
  [/^([ \t]*)([A-Za-z_$][\w$]*)[ \t]*:[ \t]*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:[ \t]*\|[ \t]*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*[ \t]*;[ \t]*$/gm,
    '$1$2;'],
  //    ★★ 这条规则出过一个很隐蔽的错（2026-10-03）：
  //       对象字面量属性 `name: key === A ? v : p.name,`
  //       里，类型部分 `[A-Za-z_$][\w$.]*` 匹配到 `key`，
  //       接着 `\s*=` 匹配了 `===` 的**第一个等号**，于是整段被替换成 `name =`，
  //       剩下 `== A ? ...` —— 生成 `name === ... ? ` 这种非法代码。
  //       表面报错是 `Unexpected token '==='`，但真凶是这条规则。
  //       修法：`=` 后面必须**不是** `=`（排除 == / ===），也不是 `>`（排除 =>）。
  [/^(\s*)([A-Za-z_$][\w$]*)\s*:\s*[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?(?:\s*\|\s*(?:null|undefined|[A-Za-z_$][\w$.]*(?:<[^;{}()]*>)?(?:\[\])?))*\s*=(?!=|>)/gm,
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

  // ---- 12b. enum → 对象字面量 ----
  //    ★ `enum` 在严格模式 / `new Function` 里是非法的（不是标准 JS），
  //      所以必须转掉。这里只处理「数值成员」这种本工程实际用到的形态，
  //      用 TS 的**双向映射**语义（既 X.A = 0，也 X[0] = 'A'）。
  //      不支持的写法（字符串成员、计算成员）会保持原样，
  //      随后被规则 13 的语法自检拦下 —— 宁可报错也不静默测错东西。
  [/^(\s*)(?:export\s+)?enum\s+(\w+)\s*\{([^}]*)\}/gm, (m, indent, name, body) => {
    const members = [];
    const rev = [];
    let auto = 0;
    for (const raw of body.split(',')) {
      const t = raw.trim();
      if (t.length === 0) continue;
      const mm = /^([A-Za-z_$][\w$]*)\s*(?:=\s*(-?\d+))?$/.exec(t);
      if (!mm) return m;   // 不认识的写法：原样保留，交给语法自检报错
      const key = mm[1];
      const val = mm[2] !== undefined ? parseInt(mm[2], 10) : auto;
      auto = val + 1;
      members.push(key + ': ' + val);
      rev.push(val + ": '" + key + "'");
    }
    return indent + 'const ' + name + ' = { ' + members.concat(rev).join(', ') + ' };';
  }],

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
  // ★ enum 有**块结构**，不能像 const/type 那样只取到行尾
  //   （截断会得到 `enum X {` 这种半截代码）。它在规则 12b 里会被
  //   转成等价的对象字面量，所以这里要按大括号配平摘完整。
  const isEnum = /^\s*(export\s+)?enum\b/.test(head);
  if (braceAt < 0 || (isConstLike && !isEnum)) {
    // ★ 数组/对象字面量的常量会跨多行（如 `const PERSONA_FIELDS = [ {...}, ... ];`）。
    //   只取到行尾会截出一个语法非法的片段。所以：
    //   若等号后紧跟 `[` 或 `{`，按方括号/大括号配平取到配平的右括号。
    const eq = src.indexOf('=', at);
    if (eq >= 0 && eq < braceAt) {
      let j = eq + 1;
      while (j < src.length && /\s/.test(src[j])) j++;
      if (src[j] === '[') {
        return src.substring(at, matchBracket(src, j, '[', ']') + 1);
      }
    }
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
 * 从 src[start]（应为 open 字符）起做配平，返回匹配的闭合字符下标
 *
 * ★ 同样必须跳过注释与字符串 —— 否则数组字面量里的
 *   `'['`（提示语、正则、示例文本里很常见）会让配平走偏。
 */
function matchBracket(src, start, open, close) {
  let depth = 0;
  let inBlock = false;
  let inLine = false;
  let inStr = '';
  for (let i = start; i < src.length; i++) {
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

    if (c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  throw new Error('方括号配平失败（起点 ' + start + '）');
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
    else if (b.startsWith('export enum ')) names.push(b.substring(12).split(/[\s{]/)[0].trim());
  }
  for (const e of extraExports) names.push(e);

  // ★ 去重：extraExports 里常常会把已在 blocks 里的名字再写一遍
  //   （比如为了拿到 enum 的运行时值），重复导出会让模块直接语法非法。
  const uniq = [];
  for (const n of names) {
    if (n.length > 0 && !uniq.includes(n)) uniq.push(n);
  }

  const full = js + '\nexport { ' + uniq.join(', ') + ' };\n';

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
