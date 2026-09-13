import { DsApi, LoginBizCode } from '../common/Constants';
import { Http, DsResponse } from './Http';
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

  /** 读取本地设备 ID（无则生成并持久化） */
  static async ensureDeviceId(): Promise<string> {
    let did: string = await Store.get(Keys.DEVICE_ID, '');
    if (did.length === 0) {
      did = AuthService.makeDeviceId();
      await Store.put(Keys.DEVICE_ID, did);
    }
    return did;
  }

  /**
   * 密码登录
   * @param account 手机号（11 位）或邮箱
   * @param password 密码
   */
  static async login(account: string, password: string): Promise<LoginResult> {
    const did: string = await AuthService.ensureDeviceId();
    const isEmail: boolean = account.indexOf('@') > 0;

    const payload: Record<string, string> = {
      'email': isEmail ? account : '',
      'mobile': isEmail ? '' : account,
      'password': password,
      'area_code': '+86',
      'device_id': did,
      'os': 'web'
    };

    const res: DsResponse = await Http.postJson(
      DsApi.ORIGIN + DsApi.LOGIN,
      JSON.stringify(payload),
      null,
      null
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
      return { ok: false, message: '当前网络环境有风险，请切换网络后重试', user: null };
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
