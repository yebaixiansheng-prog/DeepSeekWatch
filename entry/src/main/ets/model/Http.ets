import http from '@ohos.net.http';
import { DsDevice, DsHeader, DsCode } from '../common/Constants';

/** 统一响应包 */
export interface DsResponse {
  code: number;
  msg: string;
  data: DsData | null;
}

export interface DsData {
  biz_code: number;
  biz_msg: string;
  biz_data: object | null;
}

/**
 * 设备 ID 的**同步**缓存
 *
 * 为什么需要它：`buildHeaders()` 是同步函数，而读取 device_id 要走
 * Preferences（异步）。为了不在每个请求里 await，这里维护一份内存缓存，
 * 由 `AuthService.ensureDeviceId()` 在首次落盘时回填。
 * 缓存为空时**不发这个头**（发空串比不发更可疑）。
 */
export class DeviceIdCache {
  private static value: string = '';

  static set(id: string): void {
    DeviceIdCache.value = id;
  }

  static get(): string {
    return DeviceIdCache.value;
  }
}

/**
 * HTTP 封装（普通请求）
 *
 * 手表端注意事项：
 * - 单例实例复用连接，省电
 * - 超时放宽（手表网络较差）
 * - SSE 流式请求单独走 SseClient
 */
export class Http {
  private static client: http.HttpRequest | null = null;

  private static get(): http.HttpRequest {
    if (Http.client === null) {
      Http.client = http.createHttp();
    }
    return Http.client;
  }

  private static buildHeaders(token: string | null, extra: Record<string, string> | null): Record<string, string> {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': '*/*',
      'User-Agent': DsHeader.USER_AGENT
    };
    // ★ 所有请求都带设备/平台标识（不再只有登录请求带）。
    //   风控是按「会话+设备」维度累计评分的：只在登录时自称是 web、
    //   后续请求却什么都不带，反而更像脚本。这里保持全程一致。
    //   注意 ensureDeviceId 是异步的，这里用同步读取的缓存值（见 DeviceIdCache）。
    const did: string = DeviceIdCache.get();
    if (did.length > 0) {
      h[DsHeader.DEVICE_ID] = did;
    }
    h[DsHeader.PLATFORM] = DsDevice.PLATFORM;
    if (token !== null && token.length > 0) {
      h[DsHeader.AUTH] = 'Bearer ' + token;
    }
    if (extra !== null) {
      const keys: string[] = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        h[keys[i]] = extra[keys[i]];
      }
    }
    return h;
  }

  /**
   * 统一解析响应体
   *
   * ⚠️ 实测（2026-09-13）：DeepSeek 的网关在「未知路径 / 被风控拦截」时
   *    会返回 **HTTP 200 + 一整个 HTML 落地页**，而不是 JSON。
   *    旧代码把这种情况和真正的网络不通都归成 code=-1，
   *    用户在手表上只会看到「网络连接失败」，实际是服务端根本没认这个请求。
   *    这里拆成两个码，便于上层给出正确的排查方向。
   */
  private static parse(text: string): DsResponse {
    const t: string = text.trim();
    if (t.length === 0) {
      return { code: DsCode.LOCAL_BAD_PAYLOAD, msg: 'empty_body', data: null };
    }
    if (t.charAt(0) !== '{') {
      return { code: DsCode.LOCAL_BAD_PAYLOAD, msg: 'non_json_body', data: null };
    }
    try {
      return JSON.parse(t) as DsResponse;
    } catch (e) {
      return { code: DsCode.LOCAL_BAD_PAYLOAD, msg: 'bad_json', data: null };
    }
  }

  /** POST JSON */
  static async postJson(url: string, body: string, token: string | null,
    extra: Record<string, string> | null): Promise<DsResponse> {
    let text: string = '';
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: Http.buildHeaders(token, extra),
        extraData: body,
        connectTimeout: 30000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.STRING
      };
      const resp: http.HttpResponse = await Http.get().request(url, opt);
      text = resp.result as string;
    } catch (e) {
      return { code: DsCode.LOCAL_NETWORK, msg: 'network_error', data: null };
    }
    return Http.parse(text);
  }

  /** GET */
  static async getJson(url: string, token: string | null): Promise<DsResponse> {
    let text: string = '';
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: Http.buildHeaders(token, null),
        connectTimeout: 30000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.STRING
      };
      const resp: http.HttpResponse = await Http.get().request(url, opt);
      text = resp.result as string;
    } catch (e) {
      return { code: DsCode.LOCAL_NETWORK, msg: 'network_error', data: null };
    }
    return Http.parse(text);
  }

  /** POST 不解析响应体（stop_stream / delete 等） */
  static async postRaw(url: string, body: string, token: string | null,
    extra: Record<string, string> | null): Promise<boolean> {
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: Http.buildHeaders(token, extra),
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      };
      await Http.get().request(url, opt);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 释放连接（退出应用时调用） */
  static destroy(): void {
    if (Http.client !== null) {
      Http.client.destroy();
      Http.client = null;
    }
  }
}
