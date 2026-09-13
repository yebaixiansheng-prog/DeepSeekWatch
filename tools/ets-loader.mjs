/**
 * 把工程的 .ets 源码加载成可在 Node 里执行的 JS
 *
 * 为什么需要这一层：
 *   之前我在 PC 上「手抄」了一份 PoW 算法来验证，结果抄错了 5 处高低 32 位顺序，
 *   得出了「工程算法有问题」的**错误结论**，白排查了很久。
 *   教训：验证必须跑**真源码**，不能跑复制品 —— 否则你验证的是复制品，不是产品。
 *
 * 做法：读 .ets 原文，只剥掉 TS 类型标注和 ArkTS 专有 API（hilog / util.TextEncoder），
 *      其余一字不改，然后当作 ES module 执行。
 */
import { readFileSync, writeFileSync } from 'fs';

const ROOT = 'D:/HarmonyBuild/DeepSeekWatch';

/** 剥类型标注的替换规则（顺序有讲究，别随意调整） */
const RULES = [
  [/^import[\s\S]*?;\s*$/gm, ''],                    // 去掉 import
  [/export class DeepSeekHash/, 'class DeepSeekHash'],
  [/\bprivate static\b/g, 'static'],
  [/\bprivate\b/g, ''],
  [/\bstatic readonly\b/g, 'static'],
  [/new Array<[^>]+>/g, 'new Array'],
  [/new Promise<[^>]*>/g, 'new Promise'],
  [/new util\.TextEncoder\(\)/g, 'new TextEncoder()'],
  [/new util\.TextDecoder\([^)]*\)/g, 'new TextDecoder()'],
  [/util\.TextEncoder/g, 'TextEncoder'],
  [/\bhilog\.(info|error|warn|debug)\(/g, 'noop('],
  [/(\w+)\?:/g, '$1:'],                             // onProgress?: → onProgress:
  // ⚠️ 只剥「已知类型名」，否则会把三元运算符的 `: h` 也当成类型标注删掉
  [/:\s*\([^)]*\)\s*=>\s*[A-Za-z_$][\w$.<>\[\]| ]*/g, ''],
  [/\)\s*:\s*Promise<[^>]+>\s*\{/g, ') {'],
  [/\)\s*:\s*(number|string|boolean|void|Uint8Array|Object|boolean\[\])\s*\{/g, ') {'],
  [/:\s*Promise<[^>]+>/g, ''],
  [/:\s*(number|string|boolean|void|Uint8Array|Int32Array|Object|TextEncoder)(\[\])?/g, ''],
];

/** 已被剥成 JS 的源码缓存（同一进程内只做一次） */
let cached = null;

/**
 * 加载工程的 DeepSeekHash（真源码）
 * @returns {Promise<{DeepSeekHash: any, js: string}>}
 */
export async function loadDeepSeekHash() {
  if (cached) {
    return cached;
  }
  const file = ROOT + '/entry/src/main/ets/common/DeepSeekHash.ets';
  const raw = readFileSync(file, 'utf8');

  // 只取「常量 + permute + DeepSeekHash 类」这一段
  const from = raw.indexOf('/** ι 常量的高/低 32 位 */');
  if (from < 0) {
    throw new Error('在 DeepSeekHash.ets 里找不到起始锚点，文件结构可能变了');
  }
  let js = raw.slice(from);
  for (const [re, to] of RULES) {
    js = js.replace(re, to);
  }
  js = 'function noop() {}\n' + js + '\nexport { DeepSeekHash };\n';

  writeFileSync(ROOT + '/tools/_ets_transformed.mjs', js);
  const mod = await import(
    'data:text/javascript;base64,' + Buffer.from(js).toString('base64')
  );
  cached = { DeepSeekHash: mod.DeepSeekHash, js };
  return cached;
}
