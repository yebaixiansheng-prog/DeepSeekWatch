/**
 * 官方 API 客户端（DeepSeek 开放平台，OpenAI 兼容协议）
 *
 * ★ 2026-09-30 新写。旧的 `SseClient.ets`（768 行，配 PoW + 私有帧格式 + 去重状态机）
 *   已删除 —— 官方 API 的流格式是标准 OpenAI 格式，不需要那些补丁。
 *
 * 设计要点：
 *   1. **纯净**：本文件只依赖 `@ohos.net.http`，不碰任何 UI 或存储，方便离线回归测试。
 *   2. **必有失败出口**：任何路径都必须 settle（resolve/reject），
 *      绝不允许出现「转圈没反应」（这是用户明确不接受的行为）。
 *   3. **SSE 解析独立成纯函数**（`SseDecoder`），可以在 Node 里直接跑测试。
 */

import http from '@ohos.net.http';
import { DsApi, DsHeader, ErrCode, ErrMsg, Role, Thinking, SearchCfg } from '../common/Constants';

/** 对话消息（同时用于本地历史与 API 请求体） */
export interface ChatMsg {
  role: string;
  content: string;
  /** 思考内容（仅思考模式有；本地保留但不回传给 API） */
  reasoning?: string;
  /** 工具调用（仅 assistant 消息可能有） */
  toolCalls?: ToolCall[];
  /** 工具结果消息对应的调用 id */
  toolCallId?: string;
  /** 时间戳（ms） */
  ts: number;
}

export interface ToolCall {
  id: string;
  name: string;
  /** 原始 JSON 字符串 */
  arguments: string;
}

/** 流式回调 */
export interface StreamSink {
  /** 正文增量 */
  onDelta: (text: string) => void;
  /** 思考增量（思考模式下） */
  onReasoning?: (text: string) => void;
  /** 模型要求调用工具 */
  onToolCalls?: (calls: ToolCall[]) => void;
  /** 正常结束 */
  onDone: () => void;
  /** 失败（必定被调用其中之一） */
  onError: (code: number, message: string) => void;
}

/** 一次请求的返回值 */
export interface ApiResult {
  code: number;
  message: string;
  /** 非流式时的完整正文 */
  content: string;
}

/** 请求参数 */
export interface ChatRequest {
  apiKey: string;
  model: string;
  messages: ChatMsg[];
  /** 是否流式 */
  stream: boolean;
  /** 思考模式 */
  thinking: boolean;
  /** 是否带联网搜索工具 */
  search: boolean;
  /** 搜索回调：由上层执行真实搜索，返回给模型的文本 */
  onSearch?: (query: string) => Promise<string>;
}

/**
 * ★ SSE 解码器（纯函数式，无副作用，可离线测试）
 *
 * 输入是**任意切分**的字节片段，输出是完整的事件列表。
 * 关键：HTTP 分块与 SSE 事件边界**不对齐** —— 一次读到半个 JSON 是常态，
 * 必须按 `\n\n` 缓冲。这是最容易写错的地方，所以单独抽出来并有专门测试。
 */
export class SseDecoder {
  private buf: string = '';

  /** 喂入一段文本，返回其中已完整的事件 data 负载列表 */
  feed(chunk: string): string[] {
    this.buf += chunk;
    const out: string[] = [];
    // SSE 事件以空行分隔。兼容 \r\n\r\n 与 \n\n
    let idx: number = this.findBoundary();
    while (idx >= 0) {
      const raw: string = this.buf.substring(0, idx);
      this.buf = this.buf.substring(this.nextIndex(idx));
      const payload: string = SseDecoder.extractData(raw);
      if (payload.length > 0) {
        out.push(payload);
      }
      idx = this.findBoundary();
    }
    return out;
  }

  /** 残留缓冲（用于诊断「流断了但没收到 [DONE]」） */
  rest(): string {
    return this.buf;
  }

  private findBoundary(): number {
    const a: number = this.buf.indexOf('\n\n');
    const b: number = this.buf.indexOf('\r\n\r\n');
    if (a < 0) {
      return b;
    }
    if (b < 0) {
      return a;
    }
    return Math.min(a, b);
  }

  private nextIndex(idx: number): number {
    // 判断命中的是 \r\n\r\n（4 字符）还是 \n\n（2 字符）
    if (this.buf.startsWith('\r\n\r\n', idx)) {
      return idx + 4;
    }
    return idx + 2;
  }

  /**
   * 从一段原始事件文本里取出 `data:` 负载（允许多行 data，按 SSE 规范用换行拼接）
   * 返回空串表示这不是一个数据事件（例如注释行、event: 行）。
   */
  static extractData(raw: string): string {
    const lines: string[] = raw.split('\n');
    const parts: string[] = [];
    for (const line of lines) {
      const l: string = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
      if (l.startsWith('data:')) {
        let v: string = l.substring(5);
        if (v.startsWith(' ')) {
          v = v.substring(1);
        }
        parts.push(v);
      }
    }
    return parts.join('\n');
  }
}

/**
 * 从单个 SSE 数据负载里抽出增量文本
 *
 * 兼容两种形态：
 *   · 正文增量：`choices[0].delta.content`
 *   · 思考增量：`choices[0].delta.reasoning_content`
 *
 * 返回 null 表示这个块没有可用内容（例如首个 role 块、或 usage 尾块）。
 */
export interface SseDelta {
  content: string;
  reasoning: string;
  /** 是否出现 finish_reason（非 null） */
  finished: boolean;
}

export class SseChunk {
  /**
   * 解析一个 data 负载。
   * ★ 用宽松解析：任何异常都返回 null（由调用方决定是忽略还是报错），
   *   绝不在这里 throw —— 单个坏块不该毁掉整个流。
   */
  static parse(payload: string): SseDelta | null {
    if (payload === '[DONE]') {
      return null;
    }
    let obj: Record<string, Object> | null = null;
    try {
      obj = JSON.parse(payload) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (obj === null) {
      return null;
    }
    const choices: Object = obj['choices'] as Object;
    if (choices === undefined || choices === null) {
      return null;
    }
    const arr: Object[] = choices as Object[];
    if (!Array.isArray(arr) || arr.length === 0) {
      return null;
    }
    const c0: Record<string, Object> = arr[0] as Record<string, Object>;
    const delta: Record<string, Object> = c0['delta'] as Record<string, Object>;
    let content: string = '';
    let reasoning: string = '';
    if (delta !== undefined && delta !== null) {
      const ct: Object = delta['content'];
      if (typeof ct === 'string') {
        content = ct as string;
      }
      const rc: Object = delta['reasoning_content'];
      if (typeof rc === 'string') {
        reasoning = rc as string;
      }
    }
    const fr: Object = c0['finish_reason'];
    const finished: boolean = fr !== undefined && fr !== null;
    return { content: content, reasoning: reasoning, finished: finished };
  }

  /**
   * 从非流式响应体里抽出完整结果
   */
  static parseFull(body: string): string {
    const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    const choices: Object[] = obj['choices'] as Object[];
    if (!Array.isArray(choices) || choices.length === 0) {
      return '';
    }
    const c0: Record<string, Object> = choices[0] as Record<string, Object>;
    const msg: Record<string, Object> = c0['message'] as Record<string, Object>;
    const ct: Object = msg['content'];
    return typeof ct === 'string' ? (ct as string) : '';
  }
}

/**
 * 从一段流式响应的正文里抽出 tool_calls
 *
 * ★ 工具的 delta 是**分片**下发的：`tool_calls[0].function.arguments` 会
 *   被切成若干段（`{"que` + `ry": "` + `xxx"}`），必须按 index 累积拼接。
 *   实测确认这是 OpenAI 标准行为，写错了会得到残缺的 JSON。
 */
export class ToolCallAccum {
  private map: Map<number, ToolCall> = new Map<number, ToolCall>();
  private order: number[] = [];

  ingest(payload: string): void {
    let obj: Record<string, Object> | null = null;
    try {
      obj = JSON.parse(payload) as Record<string, Object>;
    } catch (e) {
      return;
    }
    if (obj === null) {
      return;
    }
    const choices: Object = obj['choices'];
    if (!Array.isArray(choices) || (choices as Object[]).length === 0) {
      return;
    }
    const c0: Record<string, Object> = (choices as Object[])[0] as Record<string, Object>;
    const delta: Record<string, Object> = c0['delta'] as Record<string, Object>;
    if (delta === undefined || delta === null) {
      return;
    }
    const tcs: Object = delta['tool_calls'];
    if (!Array.isArray(tcs)) {
      return;
    }
    for (const t of (tcs as Object[])) {
      const tc: Record<string, Object> = t as Record<string, Object>;
      const idx: Object = tc['index'];
      const i: number = typeof idx === 'number' ? (idx as number) : 0;
      if (!this.map.has(i)) {
        this.map.set(i, { id: '', name: '', arguments: '' });
        this.order.push(i);
      }
      const cur: ToolCall = this.map.get(i) as ToolCall;
      const idv: Object = tc['id'];
      if (typeof idv === 'string' && (idv as string).length > 0) {
        cur.id = idv as string;
      }
      const fn: Record<string, Object> = tc['function'] as Record<string, Object>;
      if (fn !== undefined && fn !== null) {
        const nm: Object = fn['name'];
        if (typeof nm === 'string' && (nm as string).length > 0) {
          cur.name = nm as string;
        }
        const ar: Object = fn['arguments'];
        if (typeof ar === 'string') {
          cur.arguments += (ar as string);
        }
      }
    }
  }

  list(): ToolCall[] {
    const out: ToolCall[] = [];
    for (const i of this.order) {
      const c: ToolCall = this.map.get(i) as ToolCall;
      out.push(c);
    }
    return out;
  }

  get size(): number {
    return this.order.length;
  }
}

/** 错误映射结果（★ ArkTS 不允许 number[] 混装字符串，必须用接口） */
export interface ErrInfo {
  code: number;
  message: string;
}

/** 从 HTTP 状态码/响应体推断错误（纯函数，可测试） */
export class ErrMapper {
  /**
   * @param status HTTP 状态码（0 表示网络层失败）
   * @param body 响应体
   *
   * ★ 关键：官方 API 的失败是**明确的 HTTP 状态码**（401/402/429/5xx），
   *   不像网页版那样把鉴权失败藏成 HTTP 200 —— 所以这里可以直接按码分流，
   *   这是改用官方 API 后省掉的一整类坑。
   */
  static from(status: number, body: string): ErrInfo {
    if (status === 401 || status === 403) {
      return { code: ErrCode.AUTH, message: ErrMsg.AUTH };
    }
    if (status === 402) {
      return { code: ErrCode.NO_BALANCE, message: ErrMsg.NO_BALANCE };
    }
    if (status === 429) {
      return { code: ErrCode.RATE_LIMIT, message: ErrMsg.RATE_LIMIT };
    }
    if (status >= 500) {
      return { code: ErrCode.SERVER, message: ErrMsg.SERVER };
    }
    if (status === 0) {
      return { code: ErrCode.NETWORK, message: ErrMsg.NETWORK };
    }
    // 其它 4xx：优先用服务端给的 message（更具体）
    const biz: string = ErrMapper.bizMessage(body);
    if (biz.length > 0) {
      return { code: ErrCode.BIZ, message: biz };
    }
    return {
      code: ErrCode.SERVER,
      message: '请求失败（HTTP ' + status.toString() + '）'
    };
  }

  /** 从响应体里取 `error.message`，取不到返回空串 */
  static bizMessage(body: string): string {
    if (body.length === 0) {
      return '';
    }
    try {
      const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const err: Record<string, Object> = obj['error'] as Record<string, Object>;
      if (err !== undefined && err !== null) {
        const m: Object = err['message'];
        if (typeof m === 'string' && (m as string).length > 0) {
          return m as string;
        }
      }
    } catch (e) {
      return '';
    }
    return '';
  }
}

/**
 * API 客户端
 */
export class ApiClient {
  /** 当前请求句柄，用于中止 */
  private handle: http.HttpRequest | null = null;
  private aborted: boolean = false;

  /** 中止当前请求 */
  abort(): void {
    this.aborted = true;
    if (this.handle !== null) {
      try {
        this.handle.destroy();
      } catch (e) {
        // 忽略：destroy 已经销毁过会抛，无所谓
      }
      this.handle = null;
    }
  }

  /** 本次是否被主动中止 */
  isAborted(): boolean {
    return this.aborted;
  }

  /**
   * 构造请求体（★ 抽成 public static，方便离线测试断言字段正确性）
   */
  static buildBody(req: ChatRequest, msgs: ChatMsg[]): string {
    const out: string[] = [];

    // messages
    const msgParts: string[] = [];
    for (const m of msgs) {
      msgParts.push(ApiClient.encodeMsg(m));
    }
    out.push('"messages":[' + msgParts.join(',') + ']');

    out.push('"model":' + JSON.stringify(req.model));
    out.push('"stream":' + (req.stream ? 'true' : 'false'));

    // ★ 必须显式关闭思考模式，不能靠省略（省略=默认开启，实测）
    out.push('"thinking":{"type":"' + (req.thinking ? Thinking.ON : Thinking.OFF) + '"}');

    if (req.thinking) {
      out.push('"reasoning_effort":"high"');
      out.push('"max_tokens":8192');
    } else {
      out.push('"max_tokens":4096');
    }

    if (req.search) {
      out.push(SearchTools.declarationJson());
      out.push('"tool_choice":"auto"');
    }

    return '{' + out.join(',') + '}';
  }

  /**
   * 编码单条消息
   *
   * ⚠️ `reasoning` **不回传** —— 官方 API 只接受 role/content，
   *    把 reasoning 塞回去会 400。它只用于本地展示。
   */
  private static encodeMsg(m: ChatMsg): string {
    const parts: string[] = [];
    parts.push('"role":' + JSON.stringify(m.role));

    if (m.role === Role.TOOL) {
      parts.push('"content":' + JSON.stringify(m.content));
      if (m.toolCallId !== undefined) {
        parts.push('"tool_call_id":' + JSON.stringify(m.toolCallId));
      }
      return '{' + parts.join(',') + '}';
    }

    if (m.toolCalls !== undefined && m.toolCalls.length > 0) {
      // assistant 要求调用工具的消息
      if (m.content.length > 0) {
        parts.push('"content":' + JSON.stringify(m.content));
      } else {
        parts.push('"content":null');
      }
      const tcs: string[] = [];
      for (const t of m.toolCalls) {
        tcs.push('{"id":' + JSON.stringify(t.id)
          + ',"type":"function","function":{"name":' + JSON.stringify(t.name)
          + ',"arguments":' + JSON.stringify(t.arguments) + '}}');
      }
      parts.push('"tool_calls":[' + tcs.join(',') + ']');
      return '{' + parts.join(',') + '}';
    }

    parts.push('"content":' + JSON.stringify(m.content));
    return '{' + parts.join(',') + '}';
  }

  /**
   * 发起对话请求
   *
   * ★ 带工具的完整循环（最多 SearchCfg.MAX_ROUNDS 轮）：
   *     请求 → 若模型要调工具 → 执行搜索 → 回灌 → 再请求 → ...
   *   所有路径都保证 sink 最终被调用一次（onDone 或 onError）。
   */
  async chat(req: ChatRequest, sink: StreamSink): Promise<void> {
    this.aborted = false;
    try {
      await this.chatInner(req, sink, 0);
    } catch (e) {
      if (this.aborted) {
        sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      } else {
        sink.onError(ErrCode.NETWORK, ErrMsg.NETWORK);
      }
    }
  }

  private async chatInner(req: ChatRequest, sink: StreamSink, round: number): Promise<void> {
    if (this.aborted) {
      sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      return;
    }

    const handle: http.HttpRequest = http.createHttp();
    this.handle = handle;

    const body: string = ApiClient.buildBody(req, req.messages);
    const headers: Record<string, string> = {};
    headers[DsHeader.CONTENT_TYPE] = 'application/json';
    headers[DsHeader.ACCEPT] = 'text/event-stream';
    headers[DsHeader.AUTH] = DsHeader.BEARER + req.apiKey;

    let resp: http.HttpResponse;
    try {
      resp = await handle.request(DsApi.ORIGIN + DsApi.CHAT, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: 30000,
        readTimeout: 180000,
        expectDataType: http.HttpDataType.STRING
      });
    } catch (e) {
      this.destroyHandle(handle);
      if (this.aborted) {
        sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      } else {
        sink.onError(ErrCode.NETWORK, ErrMsg.NETWORK);
      }
      return;
    }

    if (this.aborted) {
      this.destroyHandle(handle);
      sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      return;
    }

    const status: number = resp.responseCode;
    let text: string = typeof resp.result === 'string' ? (resp.result as string) : '';

    // 非 200：交给 ErrMapper（鉴权失败也是明确的 HTTP 码，不像网页版那样藏成 200）
    if (status !== 200) {
      this.destroyHandle(handle);
      const em: ErrInfo = ErrMapper.from(status, text);
      sink.onError(em.code, em.message);
      return;
    }

    if (text.length === 0) {
      this.destroyHandle(handle);
      sink.onError(ErrCode.BAD_PAYLOAD, ErrMsg.BAD_PAYLOAD);
      return;
    }

    // 非流式：直接解析完整响应
    if (!req.stream) {
      this.destroyHandle(handle);
      try {
        const content: string = SseChunk.parseFull(text);
        const acc: ToolCallAccum = ToolCallAccum_FromFull(text);
        if (acc.size > 0 && req.onSearch !== undefined) {
          await this.runTools(req, sink, acc.list(), round);
          return;
        }
        sink.onDelta(content);
        sink.onDone();
      } catch (e) {
        sink.onError(ErrCode.BAD_PAYLOAD, ErrMsg.BAD_PAYLOAD);
      }
      return;
    }

    // 流式
    await this.consumeStream(req, sink, text, round, handle);
  }

  /** 解析流式正文 */
  private async consumeStream(req: ChatRequest, sink: StreamSink, text: string,
                              round: number, handle: http.HttpRequest): Promise<void> {
    const dec: SseDecoder = new SseDecoder();
    const acc: ToolCallAccum = new ToolCallAccum();
    let sawDone: boolean = false;
    let produced: boolean = false;

    const payloads: string[] = dec.feed(text);

    // 注意：ArkTS 的 http 默认一次性返回完整 body（非逐块）。
    // 这里按「可能一次性到达」处理，同时保留增量帧的解析能力。
    for (const p of payloads) {
      if (p === '[DONE]') {
        sawDone = true;
        break;
      }
      acc.ingest(p);
      const d: SseDelta | null = SseChunk.parse(p);
      if (d === null) {
        continue;
      }
      if (d.reasoning.length > 0 && sink.onReasoning !== undefined) {
        sink.onReasoning(d.reasoning);
        produced = true;
      }
      if (d.content.length > 0) {
        sink.onDelta(d.content);
        produced = true;
      }
    }

    this.destroyHandle(handle);

    if (this.aborted) {
      sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      return;
    }

    // 模型要求调用工具
    if (acc.size > 0) {
      if (req.onSearch !== undefined && round < SearchCfg.MAX_ROUNDS && sink.onToolCalls !== undefined) {
        sink.onToolCalls(acc.list());
        await this.runTools(req, sink, acc.list(), round);
        return;
      }
      // 不允许工具 / 超过轮数：明确告知，避免用户看到「空回复」
      sink.onError(ErrCode.BIZ, '模型请求联网搜索，但搜索不可用或已达上限');
      return;
    }

    // 空响应（既无正文也无工具）→ 必须报错，不能让 UI 停在「转圈」
    if (!produced && !sawDone) {
      const rest: string = dec.rest();
      if (rest.length === 0) {
        sink.onError(ErrCode.BAD_PAYLOAD, ErrMsg.BAD_PAYLOAD);
        return;
      }
    }
    if (!produced) {
      sink.onError(ErrCode.BAD_PAYLOAD, '模型没有返回任何内容');
      return;
    }

    sink.onDone();
  }

  /**
   * 执行工具调用：跑搜索 → 把结果追加进 messages → 再请求一轮
   */
  private async runTools(req: ChatRequest, sink: StreamSink,
                         calls: ToolCall[], round: number): Promise<void> {
    if (req.onSearch === undefined) {
      sink.onError(ErrCode.BIZ, '搜索功能不可用');
      return;
    }

    // ① assistant 的工具调用消息入历史
    const assistantMsg: ChatMsg = {
      role: Role.ASSISTANT,
      content: '',
      toolCalls: calls,
      ts: Date.now()
    };
    req.messages.push(assistantMsg);

    // ② 逐个执行，结果作为 tool 消息入历史
    for (const c of calls) {
      const q: string = parseQuery(c.arguments);
      let resultText: string = '';
      try {
        resultText = await req.onSearch(q);
      } catch (e) {
        // ★ 搜索失败**不中断对话**：把失败原因告诉模型，让它诚实作答
        resultText = '【搜索失败】未能获取"' + q + '"的搜索结果。';
      }
      req.messages.push({
        role: Role.TOOL,
        content: resultText,
        toolCallId: c.id,
        ts: Date.now()
      });
    }

    // ③ 再请求一轮（round+1）
    if (this.aborted) {
      sink.onError(ErrCode.ABORTED, ErrMsg.ABORTED);
      return;
    }
    await this.chatInner(req, sink, round + 1);
  }

  private destroyHandle(handle: http.HttpRequest): void {
    try {
      handle.destroy();
    } catch (e) {
      // 忽略
    }
    if (this.handle === handle) {
      this.handle = null;
    }
  }
}

/** 从非流式响应体累积 tool_calls（复用 ToolCallAccum 的逻辑） */
function ToolCallAccum_FromFull(body: string): ToolCallAccum {
  const acc: ToolCallAccum = new ToolCallAccum();
  acc.ingest(body);
  return acc;
}

/**
 * 从工具参数 JSON 里取出 query（纯函数，可测试）
 * 容错：字段缺失/JSON 坏 → 返回空串，由调用方兜底
 */
export function parseQuery(args: string): string {
  try {
    const obj: Record<string, Object> = JSON.parse(args) as Record<string, Object>;
    const q: Object = obj['query'];
    if (typeof q === 'string') {
      return q as string;
    }
  } catch (e) {
    return '';
  }
  return '';
}

/** 联网搜索工具的声明（发给模型） */
export class SearchTools {
  static declarationJson(): string {
    return '"tools":[{"type":"function","function":{'
      + '"name":"web_search",'
      + '"description":"通过搜索引擎获取实时信息。当问题涉及新闻、时事、天气、'
      + '价格、最新版本、近期发生的事件，或任何你不知道的实时信息时使用。",'
      + '"parameters":{"type":"object","properties":{'
      + '"query":{"type":"string","description":"搜索关键词，用简洁的查询词"}},'
      + '"required":["query"]}}}]';
  }
}
