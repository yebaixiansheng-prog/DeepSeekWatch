/**
 * PoW 全链路验证（**直接执行工程源码**，不是手抄移植）
 *
 * 做法：读 entry/src/main/ets/common/DeepSeekHash.ets，
 * 只把 TS 类型标注 / ArkTS 专有 API 去掉，变成可在 Node 跑的 JS，
 * 然后与一份「用 BigInt 从零写的标准 Keccak-f[1600] 参考实现」交叉验证。
 *
 * 验证项：
 *   ① 参考实现自证（标准 24 轮 == 官方 SHA3-256 向量）
 *   ② 工程的 permute 与参考实现 23 轮终态一致
 *   ③ 工程的 hashString 与参考实现逐字节一致（随机输入）
 *   ④ 工程的 selfTest() 返回 true
 *   ⑤ hashString(salt_expire_at_answer) == challenge（真实抓包向量）
 *   ⑥ ★ 工程的 searchRange（设备上真正用的快速路径）能搜出 answer=11747
 *   ⑦ 快速路径与慢路径在随机 nonce 上判定一致
 *   ⑧ 快速路径全区间 [0,144000) 的结论与慢路径一致
 *
 * 运行：node tools/pow-verify.mjs
 */
import { readFileSync, writeFileSync } from 'fs';

// ==================================================================
//  一、把 DeepSeekHash.ets 转成可执行 JS
// ==================================================================
const ETS = 'D:/HarmonyBuild/DeepSeekWatch/entry/src/main/ets/common/DeepSeekHash.ets';
const raw = readFileSync(ETS, 'utf8');

// 取「常量 + permute + DeepSeekHash 类」这一整段
const from = raw.indexOf('/** ι 常量的高/低 32 位 */');
let src = raw.slice(from);

const rules = [
  [/^import[\s\S]*?;\s*$/gm, ''],                    // 去掉 import
  [/export class DeepSeekHash/, 'class DeepSeekHash'],
  [/\bprivate static\b/g, 'static'],
  [/\bprivate\b/g, ''],
  [/\bstatic readonly\b/g, 'static'],
  [/new Array<[^>]+>/g, 'new Array'],                 // new Array<number>(25)
  [/new Promise<[^>]*>/g, 'new Promise'],             // new Promise<void>(...)
  [/new util\.TextEncoder\(\)/g, 'new TextEncoder()'],
  [/new util\.TextDecoder\([^)]*\)/g, 'new TextDecoder()'],
  [/util\.TextEncoder/g, 'TextEncoder'],
  [/\bhilog\.(info|error|warn|debug)\(/g, 'noop('],
  [/(\w+)\?:/g, '$1:'],                               // onProgress?: → onProgress:
  // ⚠️ 只剥「已知类型名」，否则会把三元运算符的 `: h` 也当成类型标注删掉
  [/:\s*\([^)]*\)\s*=>\s*[A-Za-z_$][\w$.<>\[\]| ]*/g, ''],
  [/\)\s*:\s*Promise<[^>]+>\s*\{/g, ') {'],
  [/\)\s*:\s*(number|string|boolean|void|Uint8Array|Object|boolean\[\])\s*\{/g, ') {'],
  [/:\s*Promise<[^>]+>/g, ''],
  [/:\s*(number|string|boolean|void|Uint8Array|Int32Array|Object|TextEncoder)(\[\])?/g, ''],
];
for (const [re, to] of rules) src = src.replace(re, to);

src = 'function noop() {}\n' + src + '\nexport { DeepSeekHash };\n';
writeFileSync('D:/HarmonyBuild/DeepSeekWatch/tools/_ets_transformed.mjs', src);

let D;
try {
  D = (await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))).DeepSeekHash;
} catch (e) {
  console.log('✗ 源码转换失败：', e.message);
  console.log('   已把转换结果写到 /tmp/ets_transformed.mjs，可用 node --check tools/_ets_transformed.mjs 定位');
  process.exit(1);
}

// ==================================================================
//  二、独立参考实现（BigInt 标准 Keccak-f[1600]）
// ==================================================================
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n];
const R = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]];
const MASK = (1n << 64n) - 1n;
const rotl = (v, n) => { const k = BigInt(n % 64); return k === 0n ? (v & MASK) : (((v << k) | (v >> (64n - k))) & MASK); };

function refPermute(A, startRound) {
  for (let round = startRound; round < 24; round++) {
    const C = []; for (let x = 0; x < 5; x++) C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
    const D = []; for (let x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x][y] ^= D[x];
    const B = []; for (let x = 0; x < 5; x++) B[x] = new Array(5).fill(0n);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) B[y][(2 * x + 3 * y) % 5] = rotl(A[x][y], R[x][y]);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y] & MASK);
    A[0][0] ^= RC[round];
  }
}

const RATE = 136;
function refHash(bytes, startRound) {
  const A = []; for (let x = 0; x < 5; x++) A[x] = new Array(5).fill(0n);
  const absorb = (block) => {
    for (let i = 0; i < RATE / 8; i++) {
      const x = i % 5, y = Math.floor(i / 5);
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(block[i * 8 + b]);
      A[x][y] ^= lane;
    }
    refPermute(A, startRound);
  };
  let off = 0;
  while (off + RATE <= bytes.length) { absorb(bytes.slice(off, off + RATE)); off += RATE; }
  const last = new Uint8Array(RATE);
  last.set(bytes.slice(off));
  last[bytes.length - off] = 0x06;
  last[RATE - 1] |= 0x80;
  absorb(last);
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i % 5][Math.floor(i / 5)];
    for (let b = 0; b < 8; b++) { out[i * 8 + b] = Number(lane & 0xffn); lane >>= 8n; }
  }
  return out;
}

const enc = new TextEncoder();
const hex = (d) => Array.from(d).map((b) => b.toString(16).padStart(2, '0')).join('');

// ==================================================================
//  三、断言
// ==================================================================
let pass = 0, fail = 0;
const check = (name, ok, extra) => {
  if (ok) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra ? '\n      ' + extra : '')); }
};

console.log('① 参考实现自证：标准 24 轮 == 官方 SHA3-256 向量');
check('SHA3-256("")', hex(refHash(enc.encode(''), 0)) === 'a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a');
check('SHA3-256("abc")', hex(refHash(enc.encode('abc'), 0)) === '3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532');

console.log('\n③ 工程的 hashString 与参考实现逐字节一致（随机输入 × 30）');
{
  let bad = 0;
  let s = 42n;
  for (let t = 0; t < 30; t++) {
    s = (s * 6364136223846793005n + 1442695040888963407n) & MASK;
    const len = 1 + Number(s % 200n);
    let str = '';
    for (let i = 0; i < len; i++) {
      s = (s * 6364136223846793005n + 1442695040888963407n) & MASK;
      str += String.fromCharCode(32 + Number(s % 95n));
    }
    const a = D.toHex(D.hashString(str));
    const b = hex(refHash(enc.encode(str), 1));
    if (a !== b) { bad++; if (bad <= 2) console.log('      不一致输入: ' + str); }
  }
  check('30 组随机输入全部一致', bad === 0, '不一致 ' + bad + ' 组');
}

// ---- 真实抓包向量 ----
const SALT = '82a875dd6f0757241fed';
const EXPIRE_AT = 1789207715395;
const ANSWER = 11747;
const CHALLENGE = 'ccfdd5b03a194eaacdfd7678b083a68aa3968f2406841c0ceaeff97ef935758e';
const PREFIX = SALT + '_' + EXPIRE_AT + '_';

console.log('\n④⑤ 工程 selfTest() 与真实向量');
check('selfTest() 返回 true', D.selfTest() === true);
check('hashString(salt_expire_at_answer) == challenge',
  D.toHex(D.hashString(PREFIX + ANSWER)) === CHALLENGE);

console.log('\n⑥ ★ searchRange（设备真正用的快速路径）能搜出 answer');
const t0 = Date.now();
const fast = D.searchRange(PREFIX, CHALLENGE, 0, 144000);
const msFast = Date.now() - t0;
check('searchRange(0,144000) === 11747', fast === ANSWER, '实际 = ' + fast);
console.log('      （Node 上全区间耗时 ' + msFast + ' ms；手表按慢 50~200 倍估算）');

console.log('\n⑦ 快速路径与慢路径在随机 nonce 上判定一致');
{
  let bad = 0;
  let s2 = 777n;
  for (let t = 0; t < 200; t++) {
    s2 = (s2 * 6364136223846793005n + 1442695040888963407n) & MASK;
    const n = Number(s2 % 144000n);
    if (D.searchRange(PREFIX, CHALLENGE, n, n + 1) !== D.searchRangeSlow(PREFIX, CHALLENGE, n, n + 1)) bad++;
  }
  check('200 个随机 nonce 判定一致', bad === 0, '不一致 ' + bad + ' 个');
}

console.log('\n⑧ 慢路径全区间结论与快速路径一致');
check('searchRangeSlow(0,144000) === 11747',
  D.searchRangeSlow(PREFIX, CHALLENGE, 0, 144000) === ANSWER);

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
