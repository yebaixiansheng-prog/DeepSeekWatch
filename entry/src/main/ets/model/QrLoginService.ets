import { DsApi, DsDevice, DsHeader, LoginBizCode, OAuthProvider, OAuthBizCode, isAuthCode } from '../common/Constants';
import { Http, DsResponse, DeviceIdCache } from './Http';
import { Store, Keys, StoreRead } from '../common/Store';
import { DsUser } from './AuthService';

/**
 * 微信扫码登录 —— 设备码（Device Code）流程
 *
 * ============================================================================
 *  ★ 为什么不用「直接抓微信二维码」这条路（已实测否决，别再试）
 * ============================================================================
 *
 *  DeepSeek web 端的微信登录用的是微信官方 `WxLogin` 组件
 *  （`https://res.wx.qq.com/connect/zh_CN/htmledition/js/wxLogin.js`，仅 1563 字节）。
 *  该组件**本身不生成二维码**，它只做三件事：
 *      拼 `open.weixin.qq.com/connect/qrconnect?...` URL → 塞进 iframe
 *      → `window.addEventListener('message')` 监听 `wxQRcodeReady` 等状态。
 *
 *  于是有两个死结：
 *    1. **二维码字节拿不到**：二维码是微信服务器在 iframe 内部渲染的，
 *       `qrconnect` 返回的是「壳页面」，没有图片 URL 可下载。
 *    2. **非浏览器来源被拒**：用普通 HTTP 客户端请求 `qrconnect`
 *       （即便补齐 `Referer` / `login_type=jssdk` / 完整 UA），
 *       实测恒返回 **892 字节错误页**（错误码 `qqBS_a089916-0`）——
 *       微信要求请求真正来自开放平台登记过、域名绑定的浏览器页面。
 *
 *  结论：**手表端不可能自己渲染出这个二维码**。
 *  详见 `docs/微信扫码登录_设计与可行性.md` 第 3 节（含实测命令与证据）。
 *
 * ============================================================================
 *  ★ 本实现采用：设备码流程（对齐 RFC 8628 Device Authorization Grant）
 * ============================================================================
 *
 *   手表                             中继服务                     手机
 *    │ ① start()                       │                          │
 *    │────────────────────────────────▶│                          │
 *    │ ◀── deviceCode / userCode /     │                          │
 *    │      verifyUrl / expiresIn      │                          │
 *    │                                 │                          │
 *    │ ② 显示大号 userCode              │  ③ 打开 verifyUrl         │
 *    │                                 │ ◀────────────────────────│
 *    │ ④ poll() 轮询                    │  ⑤ 在网页内完成微信扫码     │
 *    │────────────────────────────────▶│     （那里才是 WxLogin     │
 *    │ ◀── {status, token?}            │      能正常工作的环境）     │
 *    │ ⑥ 落盘 token → 进主页面           │                          │
 *
 *  为什么把二维码放到**手机网页**上：
 *    - 466px 圆屏扫二维码体验极差（反光、曲率、要拿手机对准手表）；
 *    - 手表最擅长显示**大号数字**，配对码正合适；
 *    - 手机浏览器才是微信 OAuth 的合法环境（第 3 节的死结自然消解）。
 *
 * ============================================================================
 *  ★ 设计纪律（继承本项目 Bug 16/17 的血泪教训）
 * ============================================================================
 *   - **任何网络操作都必须有失败出口**：轮询必须有总时长硬上限，
 *     到上限必须停止定时器并给明确 UI 反馈，**绝不出现「永久转圈」**。
 *   - **设备字段必须与密码登录完全一致**：复用 `DeviceIdCache`（长期稳定的
 *     device_id）与同一套请求头，否则会重蹈 Bug 15 的风控覆辙。
 *   - **token 落盘出口只有一个**：本类只负责「拿到 token」，
 *     真正的落盘交给 `AuthService`，保证两种登录方式的登录态语义完全等价。
 */
export class QrLoginService {
  /** 本次扫码会话的凭据（只给设备，不给用户看） */
  private deviceCode: string = '';
  /** 人类可读配对码（给用户看 / 输在手机上） */
  private userCode: string = '';
  /** 手机侧要打开的地址 */
  private verifyUrl: string = '';
  /** 会话过期时刻（毫秒时间戳） */
  private expiresAt: number = 0;
  /** 服务端建议的轮询间隔（毫秒） */
  private intervalMs: number = QrLoginService.DEFAULT_INTERVAL_MS;

  /** 轮询定时器（必须在所有结束路径上清理） */
  private pollTimer: number = -1;
  /** 已停止（避免回调重入 / 重复上报） */
  private stopped: boolean = false;
  /** 连续网络失败次数（用于指数退避） */
  private failStreak: number = 0;

  /** 默认轮询间隔 3s（对齐 RFC 8628 的常见下限，也不至于打爆服务端） */
  private static readonly DEFAULT_INTERVAL_MS: number = 3000;
  /** 退避上限 20s（网络抖动时不要退到用户以为死掉了） */
  private static readonly MAX_BACKOFF_MS: number = 20000;
  /**
   * 会话总时长硬上限 5 分钟
   *
   * ★ 这是「失败出口」的兜底：即使服务端不给 expiresIn（或给了异常值），
   *   也必须有一个确定的终止点，否则界面会永久停在「等待扫码…」。
   */
  private static readonly HARD_LIMIT_MS: number = 300000;

  // ==========================================================================
  //   回调
  // ==========================================================================

  /**
   * 启动扫码会话
   *
   * @returns 成功时给出配对码与展示所需信息；失败给出可操作的原因
   */
  async start(): Promise<QrStartResult> {
    this.stop();          // 清掉可能残留的上一轮会话
    this.stopped = false;
    this.failStreak = 0;

    // ★ 失败出口零：中继尚未配置时**直接返回可操作的原因**，不要发注定失败的请求。
    //   为什么单独判这一条：请求一个空/非法 URL 会走到 `code === -1`，
    //   而那里的文案是「请检查手表网络」—— 用户会去折腾 WiFi，实际是部署缺失，
    //   属于「错误信息误导用户」，比不报错更糟。
    if (QrLoginService.RELAY_BASE.length === 0) {
      return {
        ok: false,
        message: '微信登录服务端尚未部署，请先用密码登录',
        userCode: '',
        verifyUrl: ''
      };
    }

    const res: DsResponse = await Http.postJson(
      QrLoginService.relay('/device/start'),
      JSON.stringify({
        'client_id': 'dswatch',
        'device_name': DsDevice.DEFAULT_NAME,
        'device_model': DsDevice.DEFAULT_MODEL
      }),
      null,
      QrLoginService.deviceHeaders()
    );

    if (res.code === -1) {
      return { ok: false, message: '网络连接失败，请检查手表网络', userCode: '', verifyUrl: '' };
    }
    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      return { ok: false, message: '无法开始扫码登录，请稍后重试', userCode: '', verifyUrl: '' };
    }

    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
    const dc: string = QrLoginService.str(bd, 'device_code');
    const uc: string = QrLoginService.str(bd, 'user_code');
    const vu: string = QrLoginService.str(bd, 'verify_url');
    if (dc.length === 0 || uc.length === 0) {
      return { ok: false, message: '服务端返回数据异常，请稍后重试', userCode: '', verifyUrl: '' };
    }

    this.deviceCode = dc;
    this.userCode = uc;
    this.verifyUrl = vu;

    // 过期时间：优先用服务端给的，异常/缺失时退回硬上限
    const expSec: number = QrLoginService.num(bd, 'expires_in');
    const expMs: number = expSec > 0 ? expSec * 1000 : QrLoginService.HARD_LIMIT_MS;
    this.expiresAt = Date.now() + Math.min(expMs, QrLoginService.HARD_LIMIT_MS);

    // 轮询间隔：尊重服务端建议，但夹在 [默认值, 退避上限] 之间
    const ivSec: number = QrLoginService.num(bd, 'interval');
    if (ivSec > 0) {
      this.intervalMs = Math.max(QrLoginService.DEFAULT_INTERVAL_MS,
        Math.min(ivSec * 1000, QrLoginService.MAX_BACKOFF_MS));
    } else {
      this.intervalMs = QrLoginService.DEFAULT_INTERVAL_MS;
    }

    return { ok: true, message: '', userCode: this.userCode, verifyUrl: this.verifyUrl };
  }

  /**
   * 开始轮询扫码状态
   *
   * ★ 定时器纪律：所有结束路径（成功 / 过期 / 出错 / 用户取消 / 页面销毁）
   *   都必须走到 `stop()` 或 `clearPollTimer()`，否则离开页面后回调仍会触发。
   */
  startPolling(cb: QrPollCallbacks): void {
    this.clearPollTimer();
    this.stopped = false;
    this.scheduleNext(cb, this.intervalMs);
  }

  /** 手动刷新：重新开一个会话 */
  async refresh(): Promise<QrStartResult> {
    this.stop();
    return await this.start();
  }

  /**
   * 停止轮询与清理
   *
   * 幂等，可安全重复调用。**页面 `aboutToDisappear` 必须调它。**
   */
  stop(): void {
    this.stopped = true;
    this.clearPollTimer();
  }

  private clearPollTimer(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 安排下一次轮询（带退避） */
  private scheduleNext(cb: QrPollCallbacks, delayMs: number): void {
    if (this.stopped) {
      return;
    }
    this.clearPollTimer();
    this.pollTimer = setTimeout(() => {
      this.pollTimer = -1;
      this.tick(cb);
    }, delayMs);
  }

  /**
   * 一次轮询
   *
   * 状态机（见文档 6.2 节）：
   *   pending  → 继续轮询，显示「等待扫码」
   *   scanned  → 已扫码待确认，继续轮询
   *   ok       → 拿到 token，交给上层落盘
   *   expired  → 停止，提示重新生成
   *   denied   → 停止，展示原因
   */
  private async tick(cb: QrPollCallbacks): Promise<void> {
    if (this.stopped) {
      return;
    }

    // ★ 失败出口一：本地也做一次过期判定，不依赖服务端
    if (Date.now() >= this.expiresAt) {
      this.stop();
      if (cb.onExpired) {
        cb.onExpired();
      }
      return;
    }

    const url: string = QrLoginService.relay('/device/poll')
      + '?device_code=' + encodeURIComponent(this.deviceCode);

    const res: DsResponse = await Http.getJson(url, null);

    if (this.stopped) {
      return;   // 请求返回时用户可能已经离开页面
    }

    // 网络失败 → 指数退避后重试（不要把偶发抖动直接判死）
    if (res.code === -1 || res.code === -2) {
      this.failStreak++;
      const backoff: number = Math.min(
        this.intervalMs * Math.pow(2, this.failStreak), QrLoginService.MAX_BACKOFF_MS);
      if (cb.onNetworkRetry) {
        cb.onNetworkRetry(this.failStreak, Math.round(backoff / 1000));
      }
      this.scheduleNext(cb, backoff);
      return;
    }

    this.failStreak = 0;

    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      this.stop();
      if (cb.onError) {
        cb.onError('服务端响应异常，请重试');
      }
      return;
    }

    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
    const status: string = QrLoginService.str(bd, 'status');

    if (status === 'scanned') {
      if (cb.onScanned) {
        cb.onScanned();
      }
      this.scheduleNext(cb, this.intervalMs);
      return;
    }

    if (status === 'ok') {
      const token: string = QrLoginService.pickToken(bd);
      if (token.length === 0) {
        this.stop();
        if (cb.onError) {
          cb.onError('登录凭证获取失败，请重试');
        }
        return;
      }
      this.stop();
      if (cb.onSuccess) {
        cb.onSuccess(token, QrLoginService.parseUser(bd));
      }
      return;
    }

    if (status === 'expired') {
      this.stop();
      if (cb.onExpired) {
        cb.onExpired();
      }
      return;
    }

    if (status === 'denied') {
      this.stop();
      if (cb.onError) {
        cb.onError('已在手机上取消授权');
      }
      return;
    }

    // pending 或未知状态 → 继续等
    this.scheduleNext(cb, this.intervalMs);
  }

  // ==========================================================================
  //   会话信息（供 UI 展示）
  // ==========================================================================

  getUserCode(): string {
    return this.userCode;
  }

  getVerifyUrl(): string {
    return this.verifyUrl;
  }

  /** 剩余秒数（UI 可显示倒计时；到 0 由 tick 判定过期） */
  getRemainSeconds(): number {
    const left: number = this.expiresAt - Date.now();
    return left > 0 ? Math.floor(left / 1000) : 0;
  }

  // ==========================================================================
  //   OAuth 码换 token（微信回调链路，供中继或未来直连使用）
  // ==========================================================================

  /**
   * 用 OAuth 授权码换 DeepSeek userToken
   *
   * 契约实测（bundle `main.7d19d7e901.js`）：
   *   POST /oauth/get_token   body {nonce, provider:"WECHAT"}
   *   → {code, data:{biz_code, biz_data:{token}}}
   *
   * ⚠️ `nonce` 由服务端在 OAuth 回调跳转时下发，**客户端无法自行构造**。
   *    因此本方法只有在「确实拿到了 nonce」时才可用。
   *    这也是为什么手表端不直接走这条路，而是走设备码流程。
   */
  static async swapOAuthCode(nonce: string, provider: string): Promise<QrTokenResult> {
    if (nonce.length === 0) {
      return { ok: false, message: '缺少授权凭据', token: '', user: null };
    }
    const res: DsResponse = await Http.postJson(
      DsApi.ORIGIN + DsApi.OAUTH_GET_TOKEN,
      JSON.stringify({ 'nonce': nonce, 'provider': provider }),
      null,
      QrLoginService.deviceHeaders()
    );

    if (res.code === -1) {
      return { ok: false, message: '网络连接失败，请重试', token: '', user: null };
    }
    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      return { ok: false, message: '微信登录请求未成功，请稍后再试', token: '', user: null };
    }

    const bizCode: number = res.data.biz_code;
    if (bizCode === OAuthBizCode.SWAP_CODE_INVALID) {
      return { ok: false, message: '二维码已失效，请重新扫码', token: '', user: null };
    }
    if (bizCode === OAuthBizCode.ACCOUNT_BANNED) {
      return { ok: false, message: '该账号已被封禁', token: '', user: null };
    }
    if (bizCode === OAuthBizCode.TEMP_DISABLED) {
      return { ok: false, message: '微信登录暂时不可用，请改用密码登录', token: '', user: null };
    }
    if (bizCode === LoginBizCode.RISK_DEVICE) {
      // ★ 与密码登录**复用同一份可操作文案**（Bug 15 的结论），
      //   不要为扫码路径另写一套说法，否则用户会困惑。
      return {
        ok: false,
        message: '当前网络出口被风控拦截。请用手机或电脑浏览器在本网络下先登录一次 deepseek.com，再回到手表重试',
        token: '', user: null
      };
    }
    if (bizCode !== OAuthBizCode.OK) {
      const bm: string = res.data.biz_msg;
      return { ok: false, message: bm.length > 0 ? bm : '微信登录失败', token: '', user: null };
    }

    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
    // ★ 注意：get_token 的 token 在 `biz_data.token`，
    //   与密码登录的 `biz_data.user.token` **位置不同**（实测）。
    const token: string = QrLoginService.pickToken(bd);
    if (token.length === 0) {
      return { ok: false, message: '未能获取登录凭证', token: '', user: null };
    }
    return { ok: true, message: '', token: token, user: QrLoginService.parseUser(bd) };
  }

  // ==========================================================================
  //   内部工具
  // ==========================================================================

  /**
   * 设备请求头
   *
   * ★ 必须与密码登录用**同一套**设备标识：
   *   `DeviceIdCache` 里的 device_id 是持久化的（Bug 15 的成果），
   *   换成新的随机 id 会被风控当成「陌生设备」。
   */
  private static deviceHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    h[DsHeader.DEVICE_ID] = DeviceIdCache.get();
    h[DsHeader.PLATFORM] = DsDevice.PLATFORM;
    return h;
  }

  /**
   * 中继服务基址
   *
   * ⚠️ 占位符：设备码流程需要一个「能替手表跑 OAuth 并转发 token」的中继。
   *    在把真实域名填进来之前，本模块的 start()/poll() 会失败并给出
   *    「无法开始扫码登录」的提示 —— 这是**预期行为**，不是 bug。
   *    真机联调前请替换为实际部署地址（并在 docs 中登记）。
   */
  private static relay(path: string): string {
    return QrLoginService.RELAY_BASE + path;
  }

  /** 中继基址（部署后替换；留空表示尚未配置） */
  private static readonly RELAY_BASE: string = '';

  /**
   * 中继是否已配置
   *
   * 供 UI 层判断「微信登录这个入口现在能不能用」。
   * ★ 有它才能让登录页**提前**把按钮置灰并给出说明，
   *   而不是等用户点进去、等一圈网络超时、再看一句「无法开始扫码登录」。
   */
  static isConfigured(): boolean {
    return QrLoginService.RELAY_BASE.length > 0;
  }

  /** 取 token：兼容 `token` 字符串与 `token.value` 两种形态 */
  private static pickToken(o: Record<string, Object>): string {
    const direct: string = QrLoginService.str(o, 'token');
    if (direct.length > 0) {
      return direct;
    }
    const tk: Object | undefined = o['token'];
    if (tk !== undefined && tk !== null && typeof tk === 'object') {
      return QrLoginService.str(tk as Record<string, Object>, 'value');
    }
    return '';
  }

  private static parseUser(bd: Record<string, Object>): DsUser {
    const u: Object | undefined = bd['user'];
    if (u === undefined || u === null) {
      return { id: '', mobile: '', email: '', name: '' };
    }
    const uo: Record<string, Object> = u as Record<string, Object>;
    let name: string = QrLoginService.str(uo, 'name');
    if (name.length === 0) {
      const idp: Object | undefined = uo['id_profile'];
      if (idp !== undefined && idp !== null) {
        name = QrLoginService.str(idp as Record<string, Object>, 'name');
      }
    }
    let mobile: string = QrLoginService.str(uo, 'mobile_number');
    if (mobile.length === 0) {
      mobile = QrLoginService.str(uo, 'mobile');
    }
    return {
      id: QrLoginService.str(uo, 'id'),
      mobile: mobile,
      email: QrLoginService.str(uo, 'email'),
      name: name
    };
  }

  private static str(o: Record<string, Object>, k: string): string {
    const v: Object | undefined = o[k];
    if (v === undefined || v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return '';
  }

  private static num(o: Record<string, Object>, k: string): number {
    const v: Object | undefined = o[k];
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n: number = parseInt(v as string);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }
}

// ============================================================================
//   对外数据结构
// ============================================================================

/** 启动扫码会话的结果 */
export interface QrStartResult {
  ok: boolean;
  /** 失败原因（本地化文案） */
  message: string;
  /** 人类可读配对码（ok=true 时有值） */
  userCode: string;
  /** 手机侧打开的地址（ok=true 时有值） */
  verifyUrl: string;
}

/** OAuth 码换 token 的结果 */
export interface QrTokenResult {
  ok: boolean;
  message: string;
  token: string;
  user: DsUser | null;
}

/** 轮询状态回调 */
export interface QrPollCallbacks {
  /** 已扫码，等待用户在手机上确认 */
  onScanned?: () => void;
  /** 成功：拿到 token（由上层落盘） */
  onSuccess?: (token: string, user: DsUser | null) => void;
  /** 会话过期，需用户点刷新 */
  onExpired?: () => void;
  /** 网络抖动重试中（第 n 次，约 n 秒后重试） */
  onNetworkRetry?: (attempt: number, nextRetrySec: number) => void;
  /** 终态错误（已停止轮询） */
  onError?: (message: string) => void;
}
