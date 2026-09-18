import { DsApi, DsDevice, DsHeader, LoginBizCode } from '../common/Constants';
import { Http, DsResponse, DeviceIdCache } from './Http';
import { Store, Keys } from '../common/Store';

/** 用户信息 */
export interface DsUser {
  id: string;
  mobile: string;
  email: string;
  name: string;
}

/** 登录结果 */
export interface LoginResult {
  ok: boolean;
  /** 失败原因（本地化文案） */
  message: string;
  user: DsUser | null;
}

/**
 * 认证服务
 *
 * ⚠️ 关键实测结论（2026-09 抓包）：
 *    DeepSeek **密码登录不触发人机验证**，直接 POST /api/v0/users/login 返回 token。
 *    数美（Shumei）点选验证码只出现在「短信验证码登录」和「注册」流程。
 *
 *    因此本项目按用户要求 **只保留密码登录**，人机验证环节自然消失，
 *    手表端无需实现点选验证码 UI。
 */
export class AuthService {
  private static token: string = '';
  private static user: DsUser | null = null;

  /** 生成设备 ID（base64 随机 80 字节） */
  private static makeDeviceId(): string {
    const bytes: Uint8Array = new Uint8Array(80);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
    return AuthService.b64(bytes);
  }

  private static b64(bytes: Uint8Array): string {
    const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    const len: number = bytes.length;
    let i: number = 0;
    for (; i + 2 < len; i += 3) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + table[(n >> 6) & 63] + table[n & 63];
    }
    const rem: number = len - i;
    if (rem === 1) {
      const n: number = bytes[i] << 16;
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + '==';
    } else if (rem === 2) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + table[(n >> 6) & 63] + '=';
    }
    return out;
  }

  /**
   * 读取本地设备 ID（无则生成并持久化）
   *
   * ⚠️ **device_id 必须长期稳定**，理由见 `login()` 的注释：
   *    每次全新随机 = 风控眼里的「陌生设备」，直接拉高
   *    `RISK_DEVICE_DETECTED` 的概率。这里只在首次生成时落盘，
   *    之后（含重装前的同一次安装周期内）一直复用。
   */
  static async ensureDeviceId(): Promise<string> {
    let did: string = await Store.get(Keys.DEVICE_ID, '');
    if (did.length === 0) {
      did = AuthService.makeDeviceId();
      await Store.put(Keys.DEVICE_ID, did);
    }
    // 回填同步缓存，供 Http.buildHeaders 使用（避免每个请求都 await Preferences）
    DeviceIdCache.set(did);
    return did;
  }

  /**
   * 预热设备 ID 缓存
   *
   * 应用启动时调一次即可。否则「冷启动后第一个请求」会在
   * 缓存为空的状态下发出（不带 x-ds-device-id 头），
   * 在风控敏感的网络下这一次请求最容易被打回。
   */
  static async warmUp(): Promise<void> {
    await AuthService.ensureDeviceId();
  }

  /**
   * 密码登录
   * @param account 手机号（11 位）或邮箱
   * @param password 密码
   *
   * ⚠️ 关于 `RISK_DEVICE_DETECTED`（biz_code=11）—— 2026-09-18 定位
   *
   *   现象：用户走代理出口时 App 稳定报「当前网络环境有风险」，
   *        但**手表自带浏览器访问 chat.deepseek.com 完全正常，且登录态长期保持**。
   *
   *   结论：被拦的不是「网络」，是「这个请求看起来不像正常客户端」。两个原因：
   *     1. **登录体缺字段**。web 客户端会同时送
   *        `device_name` / `device_model` / `token` / `platform`，
   *        服务端据此给设备做可信度评分；本项目早期只发了 `device_id`，
   *        风控视角就是「自称 web 的客户端连设备名都报不出来」。
   *     2. **UA 不像任何真实浏览器**。旧 UA 自称 Mozilla/Safari 却没有版本号，
   *        与「脚本客户端」强相关。已改为结构完整的移动端 Chrome UA
   *        （见 `DsHeader.USER_AGENT`）。
   *
   *   为什么浏览器没事：浏览器有**长期稳定的设备指纹 + Cookie 会话**，
   *   是「可信设备」；而 App 每次全新安装都会生成一个**新的随机 device_id**，
   *   又没有 Cookie 可复用，风控眼里就是「陌生设备从可疑出口登录」。
   *   所以关键修法不是换网络，而是 **让 device_id 稳定、把设备字段补齐**。
   *   `ensureDeviceId()` 已做持久化，**不要**改成每次登录重新随机。
   */
  static async login(account: string, password: string): Promise<LoginResult> {
    const did: string = await AuthService.ensureDeviceId();
    const isEmail: boolean = account.indexOf('@') > 0;

    // ★ 设备字段必须与 device_id 一起给出（缺任一项都会拉低设备可信度）
    const payload: Record<string, string> = {
      'email': isEmail ? account : '',
      'mobile': isEmail ? '' : account,
      'password': password,
      'area_code': '+86',
      'device_id': did,
      'device_name': DsDevice.DEFAULT_NAME,
      'device_model': DsDevice.DEFAULT_MODEL,
      // 这个 token 是「人机验证 token」，密码登录流程没有验证码 → 空串
      'token': '',
      'platform': DsDevice.PLATFORM,
      'os': 'web'
    };

    // 请求头也带上设备/平台标识，与 body 保持同一套「自称」
    const extra: Record<string, string> = {};
    extra[DsHeader.DEVICE_ID] = did;
    extra[DsHeader.PLATFORM] = DsDevice.PLATFORM;

    const res: DsResponse = await Http.postJson(
      DsApi.ORIGIN + DsApi.LOGIN,
      JSON.stringify(payload),
      null,
      extra
    );

    if (res.code === -1) {
      return { ok: false, message: '网络连接失败，请检查手表网络', user: null };
    }
    if (res.code !== 0 || res.data === null) {
      return { ok: false, message: res.msg.length > 0 ? res.msg : '登录失败，请重试', user: null };
    }

    const bizCode: number = res.data.biz_code;
    if (bizCode === LoginBizCode.BAD_CREDENTIAL) {
      return { ok: false, message: '账号或密码错误', user: null };
    }
    if (bizCode === LoginBizCode.RISK_DEVICE) {
      // ★ 这条文案必须给出「下一步做什么」。
      //   风控是**出口 IP 不可信**与**设备字段不全**叠加的结果，
      //   光说「请切换网络」会让用户反复重试到崩溃，还以为是 App 坏了。
      //   实测最有效的解法是「先用手机/电脑浏览器在同一个出口登录一次」，
      //   服务端会把这个出口标记为可信，之后手表端再登录就通过了。
      return {
        ok: false,
        message: '当前网络出口被 DeepSeek 风控拦截。'
          + '请用手机或电脑浏览器在本网络下先登录一次 deepseek.com，再回到手表重试',
        user: null
      };
    }
    if (bizCode !== LoginBizCode.OK) {
      const bm: string = res.data.biz_msg;
      return { ok: false, message: bm.length > 0 ? bm : '登录失败', user: null };
    }

    if (res.data.biz_data === null) {
      return { ok: false, message: '登录返回数据异常', user: null };
    }

    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;

    // ★ token 提取（2026-09-12 实测抓取真实响应后确认的正确路径）
    //   真实返回结构：biz_data = { code, msg, user: { id, token, email, mobile_number, ... } }
    //   → token 在 biz_data.user.token，**不在** biz_data.token（旧代码据此必然拿到空串）
    //   为兼容潜在的结构变化，按优先级依次尝试：
    //     1) biz_data.user.token   （当前线上真实结构）
    //     2) biz_data.token        （历史/其他版本可能的结构）
    //     3) biz_data.user.token.value / biz_data.token.value （token 被包成对象时）
    let token: string = '';

    // 1) biz_data.user.token
    const uObj: Object | undefined = bd['user'];
    if (uObj !== undefined && uObj !== null) {
      token = AuthService.pickToken(uObj as Record<string, Object>);
    }
    // 2) biz_data.token（兜底）
    if (token.length === 0) {
      token = AuthService.pickToken(bd);
    }

    if (token.length === 0) {
      return { ok: false, message: '未能获取登录凭证', user: null };
    }

    const user: DsUser = AuthService.parseUser(bd);

    AuthService.token = token;
    AuthService.user = user;
    await Store.put(Keys.TOKEN, token);
    await Store.put(Keys.USER, JSON.stringify(user));

    return { ok: true, message: '登录成功', user: user };
  }

  /**
   * 从对象里取 token（兼容 3 种形态）
   *   - { token: "xxx" }                → 直接返回
   *   - { token: { value: "xxx" } }     → 取 value
   *   - 无 token                         → 返回空串
   */
  private static pickToken(o: Record<string, Object>): string {
    const tk: Object | undefined = o['token'];
    if (tk === undefined || tk === null) {
      return '';
    }
    if (typeof tk === 'string') {
      return tk as string;
    }
    const to: Record<string, Object> = tk as Record<string, Object>;
    const v: Object | undefined = to['value'];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  private static parseUser(bd: Record<string, Object>): DsUser {
    const u: Object | undefined = bd['user'];
    if (u === undefined || u === null) {
      return { id: '', mobile: '', email: '', name: '' };
    }
    const uo: Record<string, Object> = u as Record<string, Object>;

    // ★ 昵称位置（实测）：user.name 通常为空，真实昵称在 user.id_profile.name
    let name: string = AuthService.s(uo, 'name');
    if (name.length === 0) {
      const idp: Object | undefined = uo['id_profile'];
      if (idp !== undefined && idp !== null) {
        name = AuthService.s(idp as Record<string, Object>, 'name');
      }
    }

    return {
      id: AuthService.s(uo, 'id'),
      mobile: AuthService.s(uo, 'mobile_number'),
      email: AuthService.s(uo, 'email'),
      name: name
    };
  }

  private static s(o: Record<string, Object>, k: string): string {
    const v: Object | undefined = o[k];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  /** 恢复登录态 */
  static async restore(): Promise<boolean> {
    const token: string = await Store.get(Keys.TOKEN, '');
    if (token.length === 0) {
      return false;
    }
    AuthService.token = token;
    const uj: string = await Store.get(Keys.USER, '');
    if (uj.length > 0) {
      try {
        AuthService.user = JSON.parse(uj) as DsUser;
      } catch (e) {
        AuthService.user = null;
      }
    }
    return true;
  }

  /** 退出登录 */
  static async logout(): Promise<void> {
    if (AuthService.token.length > 0) {
      await Http.postRaw(DsApi.ORIGIN + DsApi.LOGOUT, '{}', AuthService.token, null);
    }
    AuthService.token = '';
    AuthService.user = null;
    await Store.remove(Keys.TOKEN);
    await Store.remove(Keys.USER);
  }

  static getToken(): string {
    return AuthService.token;
  }

  static getUser(): DsUser | null {
    return AuthService.user;
  }

  static isLoggedIn(): boolean {
    return AuthService.token.length > 0;
  }
}
