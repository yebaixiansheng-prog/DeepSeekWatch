/**
 * 一致性自检：PC 端验证脚本的设备指纹必须与 App 完全一致
 *
 * 为什么要有它：
 *   风控（RISK_DEVICE_DETECTED）是**看请求长得像不像正常客户端**判的，
 *   UA / x-ds-platform / device_id 任何一项不一致，都可能让服务端给出不同结论。
 *   如果 tools/*.mjs 用的是跟 App 不同的指纹，那么「PC 上跑通了」就
 *   **不能代表 App 也能跑通** —— 这会让人误以为真机没问题。
 *
 *   历史上就踩过：App 换了 UA，但 live-e2e.mjs / probe-auth.mjs 还留着旧的
 *   伪造 UA，于是协议层验证全部是在验证一个"不存在的客户端"。
 *
 * 用法：node tools/fingerprint-check.mjs
 */
import { readFileSync, readdirSync } from 'fs';

const APP_CONST = 'entry/src/main/ets/common/Constants.ets';
const TOOLS = ['tools/live-e2e.mjs', 'tools/probe-auth.mjs'];

const ok = (s) => `\x1b[32m✓\x1b[0m ${s}`;
const bad = (s) => `\x1b[31m✗\x1b[0m ${s}`;

let failures = 0;
function check(name, pass, extra = '') {
  if (pass) { console.log(ok(name + (extra ? '  ' + extra : ''))); }
  else { console.log(bad(name + (extra ? '  ' + extra : ''))); failures++; }
}

// ---- 从 App 源码里抽出权威值 ----
const appSrc = readFileSync(APP_CONST, 'utf8');

/**
 * 从某个 class 块里取 `static readonly NAME: string = '...'`
 * ⚠️ 不能用全局正则：DsHeader.PLATFORM 是**请求头名字**（'x-ds-platform'），
 *    DsDevice.PLATFORM 才是**要发送的值**（'web'），两者同名但含义不同。
 *    先定位 class 作用域再取值，才不会张冠李戴。
 */
function pickClassConst(className, name) {
  const clsRe = new RegExp(`export\\s+class\\s+${className}\\s*\\{`);
  const cm = clsRe.exec(appSrc);
  if (!cm) { return ''; }
  // 从 class 开头往后截到下一个 export（粗略但足够，本文件一个 class 一段）
  const rest = appSrc.slice(cm.index);
  const next = rest.indexOf('\nexport ');
  const block = next > 0 ? rest.slice(0, next) : rest;
  const re = new RegExp(`static\\s+readonly\\s+${name}\\s*:\\s*string\\s*=\\s*\\n?\\s*'([^']*)'`);
  const m = re.exec(block);
  return m ? m[1] : '';
}

const appUA = pickClassConst('DsHeader', 'USER_AGENT');
const appPlatform = pickClassConst('DsDevice', 'PLATFORM');

console.log('【基准】App 侧（Constants.ets）');
check('取到 DsHeader.USER_AGENT', appUA.length > 0, appUA ? `"${appUA.slice(0, 60)}…"` : '');
check('取到 DsDevice.PLATFORM（要发送的值）', appPlatform.length > 0, `"${appPlatform}"`);
check('PLATFORM 不是请求头名字（防张冠李戴）', appPlatform !== 'x-ds-platform',
  appPlatform === 'x-ds-platform' ? '取到的是 DsHeader.PLATFORM，写错了' : '');
console.log('');

if (appUA.length === 0) {
  console.log(bad('基准值提取失败，后面的比对没有意义。'));
  process.exit(1);
}

// ---- UA 结构健全性 ----
console.log('【健全性】UA 是否像一个真实浏览器');
{
  const hasMozilla = appUA.indexOf('Mozilla/5.0') === 0;
  const hasWebKit = appUA.indexOf('AppleWebKit/') >= 0;
  // 关键：自称 Mozilla 就必须带引擎版本号，否则是"编的"
  const hasEngineVer = /(Chrome|Firefox|Version)\/\d+\.\d+/.test(appUA);
  check('以 Mozilla/5.0 开头', hasMozilla);
  check('含 AppleWebKit', hasWebKit);
  check('★ 含引擎版本号（Chrome/x.y 等）—— 缺失会被风控当脚本客户端', hasEngineVer);
}
console.log('');

// ---- 逐工具比对 ----
for (const f of TOOLS) {
  console.log(`【比对】${f}`);
  let src;
  try { src = readFileSync(f, 'utf8'); }
  catch (e) { check(`${f} 可读`, false, String(e)); console.log(''); continue; }

  const uaM = /const\s+UA\s*=\s*'([^']*)'/.exec(src);
  const platM = /const\s+PLATFORM\s*=\s*'([^']*)'/.exec(src);

  check(`${f} 定义了 UA`, !!uaM);
  if (uaM) {
    check('UA 与 App 完全一致', uaM[1] === appUA,
      uaM[1] === appUA ? '' : `\n      脚本: ${uaM[1]}\n      App : ${appUA}`);
  }
  check(`${f} 声明了 PLATFORM 常量`, !!platM);
  if (platM) {
    check('PLATFORM 与 App 一致', platM[1] === appPlatform,
      platM[1] === appPlatform ? '' : `脚本=${platM[1]} App=${appPlatform}`);
  }
  check(`${f} 请求头带 x-ds-platform`, /x-ds-platform/.test(src));
  console.log('');
}

// ---- 全局：不该再有旧指纹残留 ----
console.log('【残留扫描】是否还有地方在**真正使用**旧的伪造 UA');
{
  const OLD = 'HarmonyOS; HUAWEI WATCH';
  const hits = [];
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.name === 'node_modules' || e.name === 'build' || e.name === '.git') { continue; }
      const p = dir + '/' + e.name;
      if (e.isDirectory()) { walk(p); continue; }
      if (!/\.(mjs|js|ets|ts)$/.test(e.name)) { continue; }
      // 本脚本自身必须包含这个模式串才能做检测，跳过
      if (p === './tools/fingerprint-check.mjs' || e.name === 'fingerprint-check.mjs') { continue; }
      const t = readFileSync(p, 'utf8');
      if (t.indexOf(OLD) < 0) { continue; }

      // 逐行判定：出现在**注释里**属于正常说明（如 Constants.ets 解释为何换掉它），
      // 出现在字符串字面量/赋值里才是真残留。
      const live = t.split('\n').filter((ln) => {
        if (ln.indexOf(OLD) < 0) { return false; }
        const s = ln.trim();
        // 注释行
        if (s.startsWith('//') || s.startsWith('*') || s.startsWith('/*')) { return false; }
        // 行尾注释之前的代码部分
        const code = ln.split('//')[0];
        if (code.indexOf(OLD) < 0) { return false; }
        return true;
      });
      if (live.length > 0) { hits.push({ p, n: live.length }); }
    }
  };
  walk('.');
  check('无仍在使用的旧 UA', hits.length === 0,
    hits.length ? '\n      ' + hits.map(h => `${h.p} (${h.n} 处)`).join('\n      ') : '');
}

console.log('');
if (failures === 0) {
  console.log('\x1b[32m结果：全部一致\x1b[0m');
  process.exit(0);
} else {
  console.log(`\x1b[31m结果：${failures} 项不一致 —— PC 验证结论不可代表真机\x1b[0m`);
  process.exit(1);
}
