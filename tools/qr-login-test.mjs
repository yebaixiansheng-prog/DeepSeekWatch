/**
 * 回归测试：把 ArkTS 版 QrLoginService 的「设备码流程」状态机
 * 1:1 移植到 JS，喂入各种服务端响应，断言状态迁移与失败出口正确。
 *
 * 覆盖 10 组用例：
 *   A. start() 成功 → 拿到 user_code / verify_url / expiresAt（含秒→毫秒换算）
 *   B. ★ 中继未配置（RELAY_BASE 为空）→ 必须**提前**返回可操作原因，
 *      且**不得发出任何请求**（这是「未配置 ≠ 网络失败」的最低要求）
 *   C. 状态机：pending → scanned → ok（正常路径，token 必须取出）
 *   D. 状态机：expired → 停轮询 + onExpired
 *   E. 状态机：denied → 停轮询 + onError
 *   F. 网络失败 → 指数退避 + onNetworkRetry（不得直接判死）
 *   G. ★ 本地过期判定（不依赖服务端）→ 到点必须停
 *   H. ★ 所有终止路径必须清掉定时器，并带一条 pending 对照组
 *      （没有对照组的"恒真"断言等于没有断言）
 *   I. ★ 未知 status 必须当 pending 处理（服务端加新状态时不得崩）
 *   J. ★ 离页竞态：请求在飞行中用户离开页面 → 回来后不得再安排轮询
 *
 * ⚠️ 数据形态纪律（Bug 18 的教训）：
 *   本测试用**真实数据形态** —— status 用服务端实际的字符串
 *   （`pending`/`scanned`/`ok`/`expired`/`denied`），expires_in 用**秒数整数**。
 *   不要为了"好写好认"改成唯一字符串：唯一值掩盖不了形态错误，反而会把
 *   "把秒当毫秒"这类真实 Bug 藏成假绿。
 *
 * ⚠️ 注入测试（本工程的硬纪律）：
 *   写完必须故意改错、确认能变红、再还原。见文件末尾「注入测试指引」。
 *
 * 运行：node tools/qr-login-test.mjs
 */

// ---------------- 被测逻辑（从 QrLoginService.ets 移植） ----------------
const DEFAULT_INTERVAL_MS = 3000;
const MAX_BACKOFF_MS = 20000;
const HARD_LIMIT_MS = 300000;

/** 与 DsCode 对齐 */
const CODE_OK = 0;
const CODE_LOCAL_NETWORK = -1;
const CODE_LOCAL_BAD_PAYLOAD = -2;

class MiniQr {
  /** 中继基址：测试里可注入（对应 RELAY_BASE） */
  static relayBase = 'https://relay.test';

  /** ★ 记录所有"真实发出"的请求，用于断言"未配置时不得发请求" */
  static requests = [];

  constructor(nowFn) {
    this.deviceCode = '';
    this.userCode = '';
    this.verifyUrl = '';
    this.expiresAt = 0;
    this.intervalMs = DEFAULT_INTERVAL_MS;
    this.pollTimer = -1;
    this.stopped = false;
    this.failStreak = 0;
    /** 注入的时钟（测试可控） */
    this.now = nowFn || (() => Date.now());
    /** 捕获被安排的定时回调（不真跑 setTimeout，测试手动推进） */
    this.pending = null;
  }

  static isConfigured() {
    return MiniQr.relayBase.length > 0;
  }

  /** 对应 start() */
  async start(fetchImpl) {
    this.stop();
    this.stopped = false;
    this.failStreak = 0;

    // ★ 失败出口零：未配置时提前返回，且**不发请求**
    if (!MiniQr.isConfigured()) {
      return { ok: false, message: '微信登录服务端尚未部署，请先用密码登录',
               userCode: '', verifyUrl: '' };
    }

    MiniQr.requests.push({ path: '/device/start' });
    const res = await fetchImpl('start', {});

    if (res.code === CODE_LOCAL_NETWORK) {
      return { ok: false, message: '网络连接失败，请检查手表网络', userCode: '', verifyUrl: '' };
    }
    if (res.code !== CODE_OK || !res.data || !res.data.biz_data) {
      return { ok: false, message: '无法开始扫码登录，请稍后重试', userCode: '', verifyUrl: '' };
    }

    const bd = res.data.biz_data;
    const dc = MiniQr.str(bd, 'device_code');
    const uc = MiniQr.str(bd, 'user_code');
    const vu = MiniQr.str(bd, 'verify_url');
    if (dc.length === 0 || uc.length === 0) {
      return { ok: false, message: '服务端返回数据异常，请稍后重试', userCode: '', verifyUrl: '' };
    }

    this.deviceCode = dc;
    this.userCode = uc;
    this.verifyUrl = vu;

    // ★ 秒 → 毫秒（这里错了会导致所有会话 3 秒就过期，是很常见的真实 Bug）
    const expSec = MiniQr.num(bd, 'expires_in');
    const expMs = expSec > 0 ? expSec * 1000 : HARD_LIMIT_MS;
    this.expiresAt = this.now() + Math.min(expMs, HARD_LIMIT_MS);

    const ivSec = MiniQr.num(bd, 'interval');
    if (ivSec > 0) {
      this.intervalMs = Math.max(DEFAULT_INTERVAL_MS,
        Math.min(ivSec * 1000, MAX_BACKOFF_MS));
    } else {
      this.intervalMs = DEFAULT_INTERVAL_MS;
    }

    return { ok: true, message: '', userCode: this.userCode, verifyUrl: this.verifyUrl };
  }

  startPolling(cb) {
    this.clearPollTimer();
    this.stopped = false;
    this.scheduleNext(cb, this.intervalMs);
  }

  stop() {
    this.stopped = true;
    this.clearPollTimer();
  }

  clearPollTimer() {
    if (this.pollTimer >= 0) {
      this.pollTimer = -1;
    }
    this.pending = null;
  }

  scheduleNext(cb, delayMs) {
    if (this.stopped) return;
    this.clearPollTimer();
    this.pollTimer = 1;
    // 不真跑定时器，把回调存起来等测试推进
    this.pending = { cb, delayMs };
  }

  /** 手动推进一次轮询（等价于定时器到点） */
  async advance(fetchImpl) {
    const p = this.pending;
    if (!p) return null;
    this.pending = null;
    this.pollTimer = -1;
    return await this.tick(p.cb, fetchImpl);
  }

  /**
   * ★ 推进一次并返回「tick 结束后」的真实定时器状态。
   *
   * 为什么需要它：`advance()` 在调用 `tick()` **之前**就把
   * `pending`/`pollTimer` 清掉了（模拟"定时器已触发"）。
   * 所以 tick 之后再去看这两个字段，只能看到 tick 自己有没有重新安排 ——
   * 这正是"该停的时候没停"要检查的东西。
   * 但若 tick 内部**不**重新安排，字段自然就是 null，
   * 断言照样通过 —— 于是"漏调 stop()"这类 Bug 被藏住（本测试初版就踩了这个坑）。
   *
   * 因此这里额外暴露 `stopped`：stop() 会把 stopped 置 true，
   * 而漏调 stop() 时 stopped 仍是 false。**这才是能区分两者的判据。**
   */
  async advanceAndProbe(fetchImpl) {
    const s = await this.advance(fetchImpl);
    return {
      status: s,
      pending: this.pending,
      pollTimer: this.pollTimer,
      stopped: this.stopped,
      /** 是否真的被停掉（唯一可靠的判据） */
      halted: this.stopped === true && this.pending === null && this.pollTimer === -1
    };
  }

  /** 对应 tick() */
  async tick(cb, fetchImpl) {
    if (this.stopped) return 'stopped';

    // ★ 失败出口一：本地过期判定
    if (this.now() >= this.expiresAt) {
      this.stop();
      if (cb.onExpired) cb.onExpired();
      return 'expired';
    }

    MiniQr.requests.push({ path: '/device/poll', deviceCode: this.deviceCode });
    const res = await fetchImpl('poll', { deviceCode: this.deviceCode });

    if (this.stopped) return 'stopped';

    // 网络失败 → 退避
    if (res.code === CODE_LOCAL_NETWORK || res.code === CODE_LOCAL_BAD_PAYLOAD) {
      this.failStreak++;
      const backoff = Math.min(this.intervalMs * Math.pow(2, this.failStreak), MAX_BACKOFF_MS);
      if (cb.onNetworkRetry) cb.onNetworkRetry(this.failStreak, Math.round(backoff / 1000));
      this.scheduleNext(cb, backoff);
      return 'retry';
    }

    this.failStreak = 0;

    if (res.code !== CODE_OK || !res.data || !res.data.biz_data) {
      this.stop();
      if (cb.onError) cb.onError('服务端响应异常，请重试');
      return 'error';
    }

    const bd = res.data.biz_data;
    const status = MiniQr.str(bd, 'status');

    if (status === 'scanned') {
      if (cb.onScanned) cb.onScanned();
      this.scheduleNext(cb, this.intervalMs);
      return 'scanned';
    }

    if (status === 'ok') {
      const token = MiniQr.pickToken(bd);
      if (token.length === 0) {
        this.stop();
        if (cb.onError) cb.onError('登录凭证获取失败，请重试');
        return 'error';
      }
      this.stop();
      if (cb.onSuccess) cb.onSuccess(token, MiniQr.parseUser(bd));
      return 'ok';
    }

    if (status === 'expired') {
      this.stop();
      if (cb.onExpired) cb.onExpired();
      return 'expired';
    }

    if (status === 'denied') {
      this.stop();
      if (cb.onError) cb.onError('已在手机上取消授权');
      return 'error';
    }

    // pending 或未知状态
    this.scheduleNext(cb, this.intervalMs);
    return 'pending';
  }

  static str(o, k) {
    const v = o[k];
    if (v === undefined || v === null) return '';
    if (typeof v === 'string') return v;
    if (typeof v === 'number') return v.toString();
    return '';
  }

  static num(o, k) {
    const v = o[k];
    if (typeof v === 'number') return v;
    if (typeof v === 'string') {
      const n = parseInt(v);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  /** 取 token：兼容 token 字符串与 token.value 两种形态 */
  static pickToken(o) {
    const direct = MiniQr.str(o, 'token');
    if (direct.length > 0) return direct;
    const tk = o['token'];
    if (tk !== undefined && tk !== null && typeof tk === 'object') {
      return MiniQr.str(tk, 'value');
    }
    return '';
  }

  static parseUser(bd) {
    const u = bd['user'];
    if (u === undefined || u === null) {
      return { id: '', mobile: '', email: '', name: '' };
    }
    let name = MiniQr.str(u, 'name');
    if (name.length === 0) {
      const idp = u['id_profile'];
      if (idp !== undefined && idp !== null) name = MiniQr.str(idp, 'name');
    }
    let mobile = MiniQr.str(u, 'mobile_number');
    if (mobile.length === 0) mobile = MiniQr.str(u, 'mobile');
    return { id: MiniQr.str(u, 'id'), mobile, email: MiniQr.str(u, 'email'), name };
  }
}

// ---------------- 测试框架 ----------------
let pass = 0, fail = 0;
function check(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.log(`  ✗ ${name}\n      期望 ${w}\n      实际 ${g}`); }
}

/** 构造一个服务端响应 */
function ok(bizData) {
  return { code: 0, msg: '', data: { biz_code: 0, biz_msg: '', biz_data: bizData } };
}
function netFail() {
  return { code: CODE_LOCAL_NETWORK, msg: 'network_error', data: null };
}

// ---------------- 用例 A：start 成功 ----------------
console.log('用例 A：start() 成功');
{
  MiniQr.relayBase = 'https://relay.test';
  MiniQr.requests = [];
  const now = () => 1_000_000;
  const q = new MiniQr(now);
  const r = await q.start(async () => ok({
    device_code: 'dc-abc', user_code: 'K7-2913',
    verify_url: 'https://relay.test/go', expires_in: 300, interval: 5
  }));
  check('ok', r.ok, true);
  check('配对码', r.userCode, 'K7-2913');
  check('verifyUrl', r.verifyUrl, 'https://relay.test/go');
  // expires_in 是**秒**，必须换算成毫秒：300s → 300000ms，且被硬上限夹住
  check('expiresAt 按秒换算并夹在上限内', q.expiresAt, 1_000_000 + 300000);
  // interval=5s，在 [3s, 20s] 之间 → 5000
  check('interval 按秒换算', q.intervalMs, 5000);

  // 若把秒当毫秒，expiresAt 会变成 +300ms → 立刻过期。反证：
  const q2 = new MiniQr(now);
  await q2.start(async () => ok({
    device_code: 'dc', user_code: 'UC', verify_url: 'u',
    expires_in: 300, interval: 5
  }));
  check('★ 未把 300 秒当成 300 毫秒', q2.expiresAt - 1_000_000 > 3000, true);
}

// ---------------- 用例 B：中继未配置（★ 本轮新增的失败出口） ----------------
console.log('用例 B：中继未配置时必须提前降级，且不发请求');
{
  MiniQr.relayBase = '';            // 模拟 RELAY_BASE 为空占位符
  MiniQr.requests = [];
  const q = new MiniQr();
  // ★ 这里不能直接 throw：那样会让本组之后的用例全部不执行，
  //   注入测试时只能看到一次崩溃，看不出到底哪条断言失效。
  //   改成置标志位，让断言自己报红，后面的用例照常跑完。
  let wronglyCalled = false;
  const r = await q.start(async () => {
    wronglyCalled = true;
    return ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 });
  });
  check('ok=false', r.ok, false);
  check('★ 文案指向部署缺失，而非网络', r.message.indexOf('尚未部署') >= 0, true);
  check('★ 文案不得误导成网络问题', r.message.indexOf('网络') < 0, true);
  check('★ 确实一个请求都没发', MiniQr.requests.length, 0);
  check('★ 未配置时完全没走到网络层', wronglyCalled, false);
  check('isConfigured()=false', MiniQr.isConfigured(), false);
  MiniQr.relayBase = 'https://relay.test';   // 还原
}

// ---------------- 用例 C：pending → scanned → ok ----------------
console.log('用例 C：正常路径 pending → scanned → ok');
{
  const q = new MiniQr(() => 1_000_000);
  const got = { scanned: 0, token: '', user: null, statuses: [] };
  const cb = {
    onScanned: () => { got.scanned++; },
    onSuccess: (t, u) => { got.token = t; got.user = u; },
    onExpired: () => got.statuses.push('expired'),
    onError: (m) => got.statuses.push('err:' + m)
  };

  await q.start(async () => ok({
    device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300
  }));
  q.startPolling(cb);

  // 第 1 次：pending
  let s = await q.advance(async () => ok({ status: 'pending' }));
  check('pending', s, 'pending');
  check('pending 时不报错也不成功', got.statuses.length + got.token.length, 0);

  // 第 2 次：scanned
  s = await q.advance(async () => ok({ status: 'scanned' }));
  check('scanned', s, 'scanned');
  check('onScanned 触发一次', got.scanned, 1);

  // 第 3 次：ok + token（真实形态：token 在 biz_data.token）
  const probe = await q.advanceAndProbe(async () => ok({
    status: 'ok', token: 'ut-real-token',
    user: { id: 'u1', mobile_number: '138****8888', id_profile: { name: '用户A' } }
  }));
  s = probe.status;
  check('ok', s, 'ok');
  check('★ 取到 token', got.token, 'ut-real-token');
  check('★ 解析出用户名（走 id_profile.name）', got.user && got.user.name, '用户A');
  check('解析出手机号', got.user && got.user.mobile, '138****8888');
  check('成功后再无待轮询', probe.pending, null);
  check('成功时定时器已清', probe.pollTimer, -1);
  // ★ 关键断言：必须是被 stop() 主动停掉，而不是"恰好没安排下一次"。
  //   只看 pending===null 是分不出来的（漏调 stop 时它也是 null）。
  check('★ 成功时确实调用了 stop()（stopped=true）', probe.stopped, true);
}

// ---------------- 用例 D/E：expired 与 denied ----------------
console.log('用例 D/E：expired 与 denied 都要停轮询');
{
  const run = async (status) => {
    const q = new MiniQr(() => 1_000_000);
    const got = { expired: 0, err: '' };
    const cb = {
      onExpired: () => { got.expired++; },
      onError: (m) => { got.err = m; }
    };
    await q.start(async () => ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 }));
    q.startPolling(cb);
    const probe = await q.advanceAndProbe(async () => ok({ status }));
    return { s: probe.status, got, q, probe };
  };

  const d = await run('expired');
  check('expired 状态返回', d.s, 'expired');
  check('onExpired 触发', d.got.expired, 1);
  check('expired 后停轮询', d.q.stopped, true);
  check('expired 后定时器已清', d.q.pollTimer, -1);
  check('★ expired 后确实 halted', d.probe.halted, true);

  const e = await run('denied');
  check('denied 落到 error 分支', e.s, 'error');
  check('denied 文案可读', e.got.err.indexOf('取消授权') >= 0, true);
  check('denied 后停轮询', e.q.stopped, true);
  check('denied 后定时器已清', e.q.pollTimer, -1);
  check('★ denied 后确实 halted', e.probe.halted, true);
}

// ---------------- 用例 F：网络失败 → 指数退避 ----------------
console.log('用例 F：网络失败要退避，不能直接判死');
{
  const q = new MiniQr(() => 1_000_000);
  const retries = [];
  const cb = {
    onNetworkRetry: (n, sec) => retries.push([n, sec]),
    onError: (m) => retries.push(['ERR', m])
  };
  await q.start(async () => ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 }));
  q.startPolling(cb);

  await q.advance(async () => netFail());
  await q.advance(async () => netFail());
  await q.advance(async () => netFail());

  check('连续 3 次网络失败都走重试而非判死', retries.length, 3);
  check('重试次数递增', retries.map(r => r[0]), [1, 2, 3]);
  check('★ 退避延迟递增（首次 >= 3s）', retries[0][1] >= 3, true);
  check('★ 退避不超上限 20s', retries[2][1] <= 20, true);
  check('★ 仍在轮询（未停止）', q.stopped, false);

  // 恢复后应清零失败计数
  await q.advance(async () => ok({ status: 'pending' }));
  check('★ 网络恢复后失败计数清零', q.failStreak, 0);
}

// ---------------- 用例 G：本地过期判定（不依赖服务端） ----------------
console.log('用例 G：本地过期判定必须独立生效');
{
  let clock = 1_000_000;
  const q = new MiniQr(() => clock);
  const got = { expired: 0, polls: 0 };
  const cb = {
    onExpired: () => { got.expired++; },
    onError: () => {}
  };
  await q.start(async () => ok({
    device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 10
  }));
  q.startPolling(cb);

  // 把时钟推过过期点（服务端此时仍回 pending —— 模拟服务端不给过期状态）
  clock += 11_000;
  const s = await q.advance(async () => { got.polls++; return ok({ status: 'pending' }); });

  check('★ 本地判定过期', s, 'expired');
  check('onExpired 触发', got.expired, 1);
  check('★ 过期后不再发轮询请求', got.polls, 0);
  check('过期后停轮询', q.stopped, true);
}

// ---------------- 用例 H：所有终止路径都要清定时器 ----------------
console.log('用例 H：终止路径必须清掉定时器（否则离页后仍回调）');
{
  const paths = [
    ['stop() 手动停止', async (q, cb) => { q.stop(); return 'stopped'; }, true],
    ['服务端 expired', async (q, cb) => await q.advance(async () => ok({ status: 'expired' })), true],
    ['服务端 denied', async (q, cb) => await q.advance(async () => ok({ status: 'denied' })), true],
    ['响应体异常', async (q, cb) => await q.advance(async () => ({ code: 500, msg: 'x', data: null })), true],
    ['ok 但缺 token', async (q, cb) => await q.advance(async () => ok({ status: 'ok' })), true],
    ['本地超时', async (q, cb) => { q.expiresAt = 0; return await q.advance(async () => ok({ status: 'pending' })); }, true],
    // ★ 反例（对照组）：pending 是**不应该**停止的路径。
    //   没有这条对照，上面的断言可能"恒真"而无人察觉。
    ['pending（对照，不应停止）', async (q, cb) => await q.advance(async () => ok({ status: 'pending' })), false]
  ];
  for (const [name, act, shouldHalt] of paths) {
    const q = new MiniQr(() => 1_000_000);
    const cb = { onExpired: () => {}, onError: () => {}, onSuccess: () => {} };
    await q.start(async () => ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 }));
    q.startPolling(cb);
    await act(q, cb);
    if (shouldHalt) {
      check(`${name} → 已 stopped`, q.stopped, true);
      check(`${name} → 定时器已清`, q.pending === null && q.pollTimer === -1, true);
    } else {
      // 对照组：必须还在轮询，否则说明"判据恒真"
      check(`${name} → 仍在 stopped=false`, q.stopped, false);
      check(`${name} → 已安排下一次`, q.pending !== null, true);
    }
  }
}

// ---------------- 用例 I：未知 status 当 pending ----------------
console.log('用例 I：未知 status 不得崩，按 pending 处理');
{
  const q = new MiniQr(() => 1_000_000);
  let errored = false;
  const cb = { onError: () => { errored = true; } };
  await q.start(async () => ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 }));
  q.startPolling(cb);

  // 模拟服务端将来加了个新状态
  const s = await q.advance(async () => ok({ status: 'awaiting_confirm' }));
  check('★ 未知状态 → pending（继续等）', s, 'pending');
  check('★ 未知状态不得报错', errored, false);
  check('★ 未知状态仍在轮询', q.stopped, false);

  // 缺 status 字段同理
  const s2 = await q.advance(async () => ok({}));
  check('缺 status 字段 → pending', s2, 'pending');
}

// ---------------- 用例 J：离页竞态（★ 生产环境真实风险） ----------------
console.log('用例 J：请求在飞行中，用户离开页面 → 不得再安排轮询');
{
  // 场景：tick() 已经把 /device/poll 发出去，用户此刻按返回键离开登录页，
  //       aboutToDisappear 调 stop()；随后请求才返回 pending。
  //       若 scheduleNext 不检查 stopped，就会**又安排一次轮询**，
  //       页面已销毁 → 定时器永远没人清 → 后台持续打接口 + 耗电。
  const q = new MiniQr(() => 1_000_000);
  const cb = { onExpired: () => {}, onError: () => {}, onSuccess: () => {} };
  await q.start(async () => ok({ device_code: 'dc', user_code: 'UC', verify_url: 'u', expires_in: 300 }));
  q.startPolling(cb);

  // 让 poll 请求"卡住"，在它 resolve 之前调 stop()
  const slowFetch = async () => {
    q.stop();                              // ← 等价于 aboutToDisappear
    return ok({ status: 'pending' });      // ← 请求此时才回来
  };
  const s = await q.advance(slowFetch);

  check('请求返回后 tick 直接退出（返回 stopped）', s, 'stopped');
  check('★ 不得再安排下一次轮询', q.pending, null);
  check('★ 仍处于 stopped', q.stopped, true);
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
if (fail > 0) process.exit(1);

// ============================================================================
//   注入测试指引（★ 本工程硬纪律：从没红过的检查等于没有检查）
// ============================================================================
//
// 改完 QrLoginService.ets 后，用下列「故意改错」逐条确认本测试能变红：
// （下列注入均已实测：确认能变红后才写下对应的"应失败"项；
//   做不到变红的项已注明原因，不留假护栏。）
//
//   1. 把 tick() 里的 `this.now() >= this.expiresAt` 改成 `false`
//      → 用例 G 应失败（实测 6 条红线）✅ 已实测
//   2. 把 start() 里的 `expSec * 1000` 改成 `expSec`
//      → 用例 A 的「未把 300 秒当成 300 毫秒」应失败（实测 2 条红线）✅ 已实测
//   3. 把 start() 开头的 isConfigured() 提前返回**删掉**
//      → 用例 B 的「确实一个请求都没发」应失败（实测 4 条红线）✅ 已实测
//   4. 把 `status === 'ok'` 分支里的 `this.stop()` 删掉
//      → 用例 C 的「确实调用了 stop()」应失败（实测 1 条红线）✅ 已实测
//        ⚠️ 注意：断言必须用 `probe.stopped`，
//           只看 `pending === null` 是**分不出来**的 ——
//           漏调 stop 时 tick 不安排下一次，pending 同样是 null。
//           本测试初版就踩了这个坑（注入 4 当时没变红，已修）。
//   5. 把 denied 分支改成走 pending
//      → 用例 D/E 的 denied 断言应失败（实测 7 条红线）✅ 已实测
//   6. 把 tick() 里请求返回后的 `if (this.stopped) return 'stopped';` 删掉
//      → 用例 J「请求返回后 tick 直接退出」应失败（实测 1 条红线）✅ 已实测
//
//   ✗ **做不到变红的一项**：`scheduleNext()` 开头的 `if (this.stopped) return;`
//     删掉它，本测试**不会**变红（已实测）。
//     原因：tick() 在 `await` 前后各有一道 stopped 检查，任何已停止的状态
//     都到不了 scheduleNext，所以这道守卫在当前控制流下是**冗余的纵深防御**。
//     保留它是为了"以后有人在中间加分支"时不至于漏 —— 但**不要**声称它被测试覆盖了。
//
// 还原后必须全绿再提交。
