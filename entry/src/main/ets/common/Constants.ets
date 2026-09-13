/**
 * DeepSeek 服务端契约常量
 * 全部来自 2026-09 对 chat.deepseek.com 前端 bundle 的实测逆向，详见 docs/API_SPEC.md
 */

export class DsApi {
  // ---- 基础 ----
  static readonly ORIGIN: string = 'https://chat.deepseek.com';
  static readonly PREFIX: string = '/api/v0';

  // ---- 登录（仅密码登录，无验证码、无人机验证）----
  static readonly LOGIN: string = '/api/v0/users/login';
  static readonly LOGOUT: string = '/api/v0/users/logout_all_sessions';
  static readonly CURRENT_USER: string = '/api/v0/users/current';
  static readonly USER_SETTINGS: string = '/api/v0/users/settings';
  static readonly CLIENT_SETTINGS: string = '/api/v0/client/settings';

  // ---- 会话 ----
  static readonly SESSION_CREATE: string = '/api/v0/chat_session/create';
  static readonly SESSION_FETCH: string = '/api/v0/chat_session/fetch_page';
  static readonly SESSION_DELETE: string = '/api/v0/chat_session/delete';
  static readonly SESSION_TITLE: string = '/api/v0/chat_session/update_title';

  // ---- 对话 ----
  static readonly HISTORY: string = '/api/v0/chat/history_messages';
  static readonly COMPLETION: string = '/api/v0/chat/completion';
  static readonly STOP_STREAM: string = '/api/v0/chat/stop_stream';
  static readonly REGENERATE: string = '/api/v0/chat/regenerate';
  static readonly CONTINUE: string = '/api/v0/chat/continue';

  // ---- PoW ----
  static readonly POW_CHALLENGE: string = '/api/v0/chat/create_pow_challenge';
}

/** 请求头 */
export class DsHeader {
  static readonly AUTH: string = 'Authorization';
  static readonly CONTENT_TYPE: string = 'Content-Type';
  static readonly POW: string = 'X-DS-PoW-Response';
  static readonly GUEST_POW: string = 'X-DS-Guest-PoW-Response';
  static readonly DEVICE_ID: string = 'x-ds-device-id';
  static readonly TRACE_ID: string = 'x-ds-trace-id';
  static readonly USER_AGENT: string =
    'Mozilla/5.0 (Linux; HarmonyOS; HUAWEI WATCH) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';
}

/** 登录返回码（实测） */
export class LoginBizCode {
  static readonly OK: number = 0;
  static readonly BAD_CREDENTIAL: number = 2; // PASSWORD_OR_USER_NAME_IS_WRONG
  static readonly RISK_DEVICE: number = 11; // RISK_DEVICE_DETECTED
}

/**
 * 业务返回码（2026-09-13 用非法 token 实测 fetch_page 得到，见 tools/probe-auth.mjs）
 *
 * ⚠️ 关键结论：**HTTP 状态码恒为 200**，鉴权失败也返回 200，
 *    只能靠响应体里的 `code` 判断。因此任何「用 status 判 401」的写法都不成立。
 */
export class DsCode {
  static readonly OK: number = 0;
  /** 本地合成：网络层异常 / 响应不是 JSON */
  static readonly LOCAL_NETWORK: number = -1;
  /** 本地合成：HTTP 通了但响应体不是 JSON（通常是被网关/风控拦成了 HTML） */
  static readonly LOCAL_BAD_PAYLOAD: number = -2;
  /** 未携带 token */
  static readonly MISSING_TOKEN: number = 40002;
  /** token 失效（过期 / 被顶号 / 服务端注销） */
  static readonly AUTH_FAILED: number = 40003;
}

/** 判断某个返回码是否属于「需要重新登录」 */
export function isAuthCode(code: number): boolean {
  return code === DsCode.MISSING_TOKEN || code === DsCode.AUTH_FAILED;
}

/** SSE 事件名 */
export class SseEvent {
  static readonly READY: string = 'ready';
  static readonly UPDATE_SESSION: string = 'update_session';
  static readonly DELTA: string = 'delta';
  static readonly HINT: string = 'hint';
  static readonly TOAST: string = 'toast';
  static readonly FINISH: string = 'finish';
  static readonly CLOSE: string = 'close';
}

/**
 * 消息片段类型（fragment.type）
 *
 * 实测来源：bundle 内 `_COLLAPSIBLE_TYPES: ["THINK","SEARCH","TOOL_SEARCH","TOOL_OPEN","TOOL_FIND"]`
 *          以及 `RESPONSE_TYPES / REQUEST / FILE / TIP / TEMPLATE_RESPONSE`
 *
 * ⚠️ 注意区分两个同名前缀但语义不同的类型：
 *   - `SEARCH`        —— 属于 THINK 之后的「搜索素材整理」阶段，内容是可读文本
 *   - `TOOL_SEARCH`   —— 工具调用，内容是结构化 queries/results（不是纯文本）
 *   - `TOOL_OPEN`     —— 打开链接工具
 * 历史上官网也用过 `TOOL_SEARCH` 传达搜索过程文本，因此解析层对二者都兼容。
 */
export class FragmentType {
  static readonly THINK: string = 'THINK';
  static readonly RESPONSE: string = 'RESPONSE';
  static readonly TEMPLATE_RESPONSE: string = 'TEMPLATE_RESPONSE';
  /** 搜索素材整理阶段（可读文本） */
  static readonly SEARCH: string = 'SEARCH';
  /** 工具：联网搜索（结构化 queries/results） */
  static readonly TOOL_SEARCH: string = 'TOOL_SEARCH';
  /** 工具：打开网页 */
  static readonly TOOL_OPEN: string = 'TOOL_OPEN';
  /** 工具：查找 */
  static readonly TOOL_FIND: string = 'TOOL_FIND';
}

/**
 * 片段/消息状态（status）
 *
 * 实测来源：bundle 内 MessageStatus 枚举 —— OK 在序列化层映射为 "FINISHED"，
 * 另有 WIP / INCOMPLETE / CONTENT_FILTER / CONTEXT_LENGTH_EXCEEDED / TIMEOUT。
 * 搜索类片段另见 FAILED。
 */
export class FragStatus {
  static readonly WIP: string = 'WIP';
  static readonly FINISHED: string = 'FINISHED';
  static readonly FAILED: string = 'FAILED';
  static readonly INCOMPLETE: string = 'INCOMPLETE';
  static readonly CONTENT_FILTER: string = 'CONTENT_FILTER';
  static readonly CONTEXT_LENGTH_EXCEEDED: string = 'CONTEXT_LENGTH_EXCEEDED';
  static readonly TIMEOUT: string = 'TIMEOUT';
}

/** 角色（服务端用大写） */
export class Role {
  static readonly USER: string = 'USER';
  static readonly ASSISTANT: string = 'ASSISTANT';
}

/** 服务端模型类型（实测：当前仅 default 可用） */
export class ModelType {
  static readonly QUICK: string = 'default'; // 快速模式
  static readonly EXPERT: string = 'expert'; // 专家模式（当前账号 disabled）
  static readonly VISION: string = 'vision'; // 识图模式（当前账号 disabled）
}
