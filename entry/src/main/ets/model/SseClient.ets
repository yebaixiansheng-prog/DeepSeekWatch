import http from '@ohos.net.http';
import hilog from '@ohos.hilog';
import { util } from '@kit.ArkTS';
import { DsHeader, SseEvent, FragmentType } from '../common/Constants';

const TAG: string = 'SseClient';

/** SSE 回调 */
export interface SseCallbacks {
  onReady?: () => void;
  onSessionId?: (id: string) => void;
  /**
   * 服务端为本轮分配的 message_id（首帧的 response 对象里带）
   *
   * ⚠️ 它的唯一用途是 `stop_stream`：
   *    本地 `abort()` 只断 HTTP 连接，服务端那条流还在跑。
   *    这些「僵尸流」会让下一次请求被排队挂死 ——
   *    所以下一轮发送前要拿这个 id 去把上一条流停掉。
   */
  onMessageId?: (id: string) => void;
  onDelta?: (fragType: string, content: string, fragmentId: string) => void;
  onHint?: (text: string) => void;
  onToast?: (text: string) => void;
  onFinish?: () => void;
  onError?: (msg: string) => void;
}

/**
 * SSE 流式客户端
 *
 * DeepSeek 的 `/api/v0/chat/completion` 返回 `text/event-stream`。
 *
 * ⚠️ 真实格式（2026-09 对线上 bundle `main.d69e3d8c16.js` 逆向 + 抓包实测）：
 *
 *   1. 只有 `ready` / `update_session` / `hint` / `toast` / `finish` 这些
 *      **控制事件**带 `event:` 名；**正文增量帧没有 event 名**，形如：
 *
 *        data: {"v":{"response":{...}}}                                   ← 首帧（op=SET）
 *        data: {"p":"response/fragments","o":"APPEND","v":[{type,...}]}   ← 追加片段
 *        data: {"p":"response/fragments/0/content","o":"APPEND","v":"你好"} ← 正文增量
 *        data: {"v":"！"}                                                  ← 延续帧（沿用上帧 p/o）
 *        data: {"code":40301,"msg":"INVALID_POW_RESPONSE"}                 ← 服务端错误
 *
 *   2. 帧是 JSON-Patch 风格：`p`=路径、`o`=操作（只可能是 SET/BATCH/APPEND）、`v`=值。
 *      `p` 与 `o` 都**可以省略**，省略时沿用上一帧的值。
 *
 *   3. ⚠️ **正文路径里只有索引，没有类型**（`response/fragments/0/content`）。
 *      片段类型只在「追加片段」那一帧里出现。早期实现只看路径前缀，
 *      结果把「深度思考」的正文当成正文回答渲染出来。
 *      本类维护 `fragTypes[]`（索引 → 类型）后再分派。
 *
 *   4. ⚠️ SET 与 APPEND 语义不同：SET 是整段给出（例如首帧已带完整 content），
 *      APPEND 是追加。若不区分，遇到「首帧就带全文」的响应会把回答整段丢掉。
 *
 * 手表端用 requestInStream 边收边解析，避免一次性缓冲大响应。
 */
export class SseClient {
  private request: http.HttpRequest | null = null;
  private buffer: string = '';
  private aborted: boolean = false;
  /** 是否已上报过结束（finish 事件与 dataEnd 都会触发，需去重） */
  private finished: boolean = false;
  /** 上一帧的 patch 路径（如 "response/fragments/0/content"），用于解析省略 p/o 的延续帧 */
  private lastPath: string = '';
  /** 上一帧的 patch 操作（如 "APPEND"） */
  private lastOp: string = '';
  /** 片段索引 → 类型（THINK / RESPONSE / TOOL_SEARCH …） */
  private fragTypes: string[] = [];
  /** 片段索引 → 正文是否已「整段」（SET）给出过；为真时忽略后续 APPEND，避免重复 */
  private fragFull: boolean[] = [];
  /** 最近一次出现的片段类型（索引不可用时的兜底） */
  private lastFragType: string = '';
  /**
   * 本实例已经上报过的 message_id（用于抑制同一轮内的重复回调）
   *
   * ★ 必须是**实例字段**，且每轮 `start()` 都要清空 ——
   *   早期它被写成 `static` 且从不重置，而服务端的 `message_id` 是
   *   **每个会话内自增的小整数**（首个助手回复通常是 `2`）。
   *   于是「上一个会话/上一轮上报过 2」会让本轮 `message_id=2` 被去重逻辑
   *   直接吞掉 → `onMessageId` 不触发 → `ChatService.rememberTurn()` 拿不到 id
   *   → 下一轮发不出 `stop_stream` → **僵尸流清不掉**，
   *   正好复现 Bug 16「聊几轮后彻底发不出去」。
   *   去重的本意只是「同一轮内别重复回调」，绝不能跨轮、跨会话生效。
   */
  private reportedMessageId: string = '';

  /** 诊断用：本次流收到的帧数 / 累计正文字数 / 见过的路径 */
  private frameCount: number = 0;
  private textLen: number = 0;
  private seenPaths: string = '';

  /**
   * 静默看门狗
   *
   * ★ 为什么必须有它（2026-09-18，「聊两轮就再也发不出去」的兜底）：
   *   服务端在 `preempt:false` 排队、或网关把请求挂住时，
   *   HTTP 连接是**建立成功**的，`requestInStream` 也返回了，
   *   但此后**一个字节都不来**，`dataEnd` 也永远不触发。
   *   客户端于是无限期停在「准备中…」，用户完全无法判断发生了什么 ——
   *   这就是他说的「反正就不能对话了」。
   *
   *   看门狗定时检查「距上次收到数据过了多久」：
   *     - 超过 STALL_MS 还是零帧 → 判定为被挂起，主动 abort 并报 stall
   *     - 超过 STALL_MS 且已经收过数据 → 只告警不打断（长思考的静默期可能很久）
   */
  private lastDataAt: number = 0;
  private watchdogTimer: number = -1;

  /** 无数据静默上限：超过就认定服务端把请求挂住了 */
  private static readonly STALL_MS: number = 45000;
  /** 看门狗检查间隔 */
  private static readonly WATCH_INTERVAL_MS: number = 5000;

  /** 发起流式对话 */
  async start(url: string, body: string, token: string,
    headers: Record<string, string>, cb: SseCallbacks): Promise<void> {
    const client: http.HttpRequest = http.createHttp();
    this.request = client;
    this.buffer = '';
    this.aborted = false;
    this.finished = false;
    this.lastPath = '';
    this.lastOp = '';
    this.fragTypes = [];
    this.fragFull = [];
    this.lastFragType = '';
    this.reportedMessageId = '';
    this.frameCount = 0;
    this.textLen = 0;
    this.seenPaths = '';
    this.lastDataAt = Date.now();
    this.startWatchdog(cb);

    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'User-Agent': DsHeader.USER_AGENT,
      'Authorization': 'Bearer ' + token
    };
    const extraKeys: string[] = Object.keys(headers);
    for (let i = 0; i < extraKeys.length; i++) {
      h[extraKeys[i]] = headers[extraKeys[i]];
    }

    client.on('dataReceive', (data: ArrayBuffer) => {
      if (this.aborted) {
        return;
      }
      this.lastDataAt = Date.now();
      const chunk: string = SseClient.decode(data);
      this.buffer += chunk;
      this.consume(cb);
    });

    client.on('dataEnd', () => {
      // 流结束：处理缓冲区残留（含未以空行结尾的最后一帧），再补一次 finish（去重）
      this.consume(cb);
      this.flushTail(cb);
      this.emitFinish(cb);
      this.dispose();
    });

    client.on('dataReceiveProgress', () => {
      // 手表端不关心字节进度，忽略
    });

    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: h,
        extraData: body,
        connectTimeout: 30000,
        readTimeout: 120000,
        expectDataType: http.HttpDataType.STRING
      };
      await client.requestInStream(url, opt);
    } catch (e) {
      if (!this.aborted && cb.onError) {
        cb.onError('stream_error');
      }
      this.dispose();
    }
  }

  /**
   * 上报结束（幂等）
   *
   * SSE 里 `finish` / `close` 事件和底层 `dataEnd` 都可能到来，
   * 若不去重，UI 会收到两次 onFinish（表现为状态条闪一下、重复滚屏）。
   */
  private emitFinish(cb: SseCallbacks): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.stopWatchdog();
    // ★ 诊断：这条日志能一眼区分「服务端没回内容」和「回了但解析丢了」
    hilog.info(0x0001, TAG, 'sse DONE frames=%{public}d textLen=%{public}d paths=%{public}s',
      this.frameCount, this.textLen, this.seenPaths);
    if (!this.aborted && cb.onFinish) {
      cb.onFinish();
    }
  }

  // ==================================================================
  //   静默看门狗
  // ==================================================================

  private startWatchdog(cb: SseCallbacks): void {
    this.stopWatchdog();
    this.watchdogTimer = setInterval(() => {
      if (this.finished || this.aborted) {
        this.stopWatchdog();
        return;
      }
      const idle: number = Date.now() - this.lastDataAt;
      if (idle < SseClient.STALL_MS) {
        return;
      }
      if (this.frameCount === 0) {
        // 一帧都没来 → 服务端把请求挂住了（典型：preempt 排队 / 网关挂死）
        hilog.error(0x0001, TAG,
          'sse STALLED no frame in %{public}dms, aborting', idle);
        this.stopWatchdog();
        this.aborted = true;
        this.dispose();
        if (cb.onError) {
          cb.onError('stalled');
        }
        return;
      }
      // 已经收过数据，只是暂时安静（长思考）→ 只告警，不打断
      hilog.warn(0x0001, TAG,
        'sse quiet %{public}dms (frames=%{public}d) — still waiting', idle, this.frameCount);
    }, SseClient.WATCH_INTERVAL_MS);
  }

  private stopWatchdog(): void {
    if (this.watchdogTimer >= 0) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  /** 解析缓冲区里的完整 SSE 帧 */
  private consume(cb: SseCallbacks): void {
    let idx: number = this.buffer.indexOf('\n\n');
    while (idx >= 0) {
      const frame: string = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + 2);
      this.handleFrame(frame, cb);
      idx = this.buffer.indexOf('\n\n');
    }
  }

  /** 流末尾没有空行结尾的残帧（服务端不一定以 \n\n 收尾） */
  private flushTail(cb: SseCallbacks): void {
    const tail: string = this.buffer.trim();
    this.buffer = '';
    if (tail.length > 0) {
      this.handleFrame(tail, cb);
    }
  }

  /**
   * 处理单帧
   *
   * SSE 规范：`event:` 只对**紧随其后的**一帧生效。
   * 早期实现把它存在 currentEvent 里跨帧复用，会让后续缺省 event 的帧
   * 沿用上一个事件名，导致 delta 被当成 update_session 丢弃。
   * 这里改为每帧独立解析。
   *
   * ⚠️ 更重要的修正：缺省 event 的帧**不是「可丢弃的 message」**，
   *    在 DeepSeek 这里它们恰恰是正文增量，必须走 handlePatch。
   */
  private handleFrame(frame: string, cb: SseCallbacks): void {
    const lines: string[] = frame.split('\n');
    let eventName: string = '';
    let dataStr: string = '';

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        // 同一帧多条 data: 需换行拼接（SSE 规范），这里按原样续接
        dataStr += line.substring(5).trim();
      }
    }
    if (dataStr.length === 0) {
      return;
    }

    let obj: Record<string, Object> | null = null;
    try {
      obj = JSON.parse(dataStr) as Record<string, Object>;
    } catch (e) {
      return;
    }
    if (obj === null) {
      return;
    }

    this.frameCount++;
    if (eventName.length === 0) {
      // ★ 没有 event 名 → 是 patch 帧（正文增量 / 状态 / 错误），不是"可丢弃的 message"
      this.handlePatch(obj, cb);
    } else {
      this.dispatch(eventName, obj, cb);
    }
    // 每 25 帧打一次点，既能观察进度又不至于刷爆日志
    if (this.frameCount % 25 === 0) {
      hilog.info(0x0001, TAG, 'sse frames=%{public}d textLen=%{public}d paths=%{public}s',
        this.frameCount, this.textLen, this.seenPaths);
    }
  }

  // ==================================================================
  //   patch 帧处理
  // ==================================================================

  private handlePatch(obj: Record<string, Object>, cb: SseCallbacks): void {
    // ---- 1. 服务端错误帧 ----
    const codeObj: Object | undefined = obj['code'];
    if (codeObj !== undefined && codeObj !== null) {
      const c: string = SseClient.pickStr(obj, 'code');
      const m: string = SseClient.pickStr(obj, 'msg');
      hilog.error(0x0001, TAG, 'sse server error code=%{public}s msg=%{public}s', c, m);
      if (cb.onError) {
        cb.onError('srv_' + c);
      }
      return;
    }

    const p: string = SseClient.pickStr(obj, 'p');
    const op: string = SseClient.pickStr(obj, 'o');
    const v: Object | undefined = obj['v'];

    // ---- 2. 无路径 ----
    if (p.length === 0) {
      if (v !== undefined && v !== null && typeof v !== 'string') {
        // 首帧：整条助手消息（含 fragments），把类型表建起来
        this.absorbStructValue(v, 'SET', cb);
        return;
      }
      // 延续帧：沿用上一帧的 path / op
      if (v === undefined || v === null || typeof v !== 'string') {
        return;
      }
      this.emitContent(this.lastPath, v as string, this.lastOp === 'APPEND', cb);
      return;
    }

    // ---- 3. 片段结构帧（fragments 数组 / 单个片段对象）----
    if (SseClient.isFragmentsStructPath(p)) {
      if (v !== undefined && v !== null && typeof v !== 'string') {
        this.absorbStructValueAtPath(p, op, v, cb);
      }
      return;
    }

    // ---- 4. 其它路径：只认正文 ----
    if (!p.endsWith('/content')) {
      // token 统计 / 状态等：整帧忽略，不动 lastPath / lastOp，
      // 否则紧跟其后的「省略 p/o 的延续帧」会被归错类，正文莫名断掉。
      return;
    }
    this.lastPath = p;
    this.lastOp = op;
    if (v === undefined || v === null || typeof v !== 'string') {
      return;
    }
    this.emitContent(p, v as string, op === 'APPEND', cb);
  }

  /**
   * 处理「片段结构」的值
   *
   * @param op 'SET' 表示整段覆盖（例如首帧已带完整 content），'APPEND' 表示追加
   */
  private absorbStructValue(v: Object, op: string, cb: SseCallbacks): void {
    if (typeof v !== 'object') {
      return;
    }
    const vo: Record<string, Object> = v as Record<string, Object>;

    // ★ 顺带捞「服务端为这一轮分配的 message_id」。
    //   首帧的 response 对象里带 message_id，这是后续
    //   `stop_stream` 唯一能用的凭据（下一轮发送前用它清僵尸流）。
    this.pickMessageId(vo, cb);

    // 形态一：v 自己就是带 fragments 的对象
    const direct: Object | undefined = vo['fragments'];
    if (direct !== undefined && direct !== null && Array.isArray(direct)) {
      this.absorbFragmentArray(direct as Object[], op, cb);
      return;
    }
    // 形态二：多包一层 {response:{fragments:[...]}} / {thinking:{...}} / {search:{...}}
    const keys: string[] = ['response', 'thinking', 'search'];
    for (let i = 0; i < keys.length; i++) {
      const inner: Object | undefined = vo[keys[i]];
      if (inner === undefined || inner === null || typeof inner !== 'object') {
        continue;
      }
      const io: Record<string, Object> = inner as Record<string, Object>;
      this.pickMessageId(io, cb);
      const fs: Object | undefined = io['fragments'];
      if (fs !== undefined && fs !== null && Array.isArray(fs)) {
        this.absorbFragmentArray(fs as Object[], op, cb);
        return;
      }
    }
  }

  /**
   * 从 response 对象里取 message_id 并回调
   *
   * 兼容 `message_id` / `messageId` / `id` 三种命名（不同版本服务端用过不同键），
   * 且只在拿到非空值、且与**本实例本轮**已上报过的值不同时才回调
   * （避免每帧都触发；跨轮/跨会话的比较由 `reportedMessageId` 每轮重置来保证不误吞）。
   */
  private pickMessageId(o: Record<string, Object>, cb: SseCallbacks): void {
    if (cb.onMessageId === undefined) {
      return;
    }
    let mid: string = SseClient.pickStr(o, 'message_id');
    if (mid.length === 0) {
      mid = SseClient.pickStr(o, 'messageId');
    }
    if (mid.length === 0) {
      mid = SseClient.pickStr(o, 'id');
    }
    if (mid.length === 0 || mid === this.reportedMessageId) {
      return;
    }
    this.reportedMessageId = mid;
    cb.onMessageId(mid);
  }

  /** 处理带 fragments 路径的结构帧 */
  private absorbStructValueAtPath(path: string, op: string, v: Object, cb: SseCallbacks): void {
    if (Array.isArray(v)) {
      this.absorbFragmentArray(v as Object[], op, cb);
      return;
    }
    if (typeof v !== 'object') {
      return;
    }
    // 单个片段对象：写到它自己的索引上
    const idx: number = SseClient.resolveIndex(path, this.fragTypes.length);
    const o: Record<string, Object> = v as Record<string, Object>;
    const t: string = SseClient.pickStr(o, 'type');
    const content: string = SseClient.pickStr(o, 'content');
    if (t.length > 0) {
      this.lastFragType = t;
    }
    if (idx >= 0) {
      while (this.fragTypes.length <= idx) {
        this.fragTypes.push('');
        this.fragFull.push(false);
      }
      this.fragTypes[idx] = t;
      // SET = 整段给出：标记为已整段，后续 APPEND 忽略，避免重复
      this.fragFull[idx] = (op !== 'APPEND') && content.length > 0;
    }
    if (content.length > 0) {
      this.emitStructContent(idx, content, cb);
    }
  }

  /**
   * 处理片段数组
   *
   * ⚠️ 索引语义：数组帧的 v 是按顺序追加的片段，push 即对上下标。
   *    op=SET 表示整表替换，先清空。
   */
  private absorbFragmentArray(arr: Object[], op: string, cb: SseCallbacks): void {
    if (op === 'SET') {
      this.fragTypes = [];
      this.fragFull = [];
    }
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      let t: string = '';
      let content: string = '';
      if (item !== null && item !== undefined && typeof item === 'object') {
        const o: Record<string, Object> = item as Record<string, Object>;
        t = SseClient.pickStr(o, 'type');
        content = SseClient.pickStr(o, 'content');
      }
      if (t.length > 0) {
        this.lastFragType = t;
      }
      const idx: number = this.fragTypes.length;
      this.fragTypes.push(t);
      // APPEND 语义下即使带了 content 也只是「第一段」，后面还会追加，不能标成整段
      this.fragFull.push(op !== 'APPEND' && content.length > 0);
      if (content.length > 0) {
        this.emitStructContent(idx, content, cb);
      }
    }
  }

  /** 结构帧里自带的正文（首帧/SET 帧可能直接给全文） */
  private emitStructContent(idx: number, content: string, cb: SseCallbacks): void {
    if (content.length === 0) {
      return;
    }
    const t: string = SseClient.normalizeType(this.typeAt(idx));
    if (t.length === 0) {
      return;
    }
    this.pushDelta(t, content, cb);
  }

  /**
   * 正文增量分派
   *
   * @param isAppend 是否 APPEND 语义（SET 语义表示整段覆盖）
   */
  private emitContent(path: string, text: string, isAppend: boolean, cb: SseCallbacks): void {
    if (path.length === 0 || text.length === 0) {
      return;
    }
    if (!path.endsWith('/content')) {
      return;
    }
    const idx: number = SseClient.resolveIndex(path, this.fragTypes.length);
    let t: string = '';
    if (idx >= 0) {
      if (this.fragFull[idx] === true) {
        // 该片段正文已经整段给过（SET），再追加就是重复
        return;
      }
      if (!isAppend) {
        this.fragFull[idx] = true;
      }
      t = SseClient.normalizeType(this.typeAt(idx));
    } else {
      // 路径里没有可用的索引 → 退回「路径首段 / 最近片段类型」判断
      t = this.typeFromPathHead(path);
    }
    if (t.length === 0) {
      return;
    }
    this.notePath(path);
    this.pushDelta(t, text, cb);
  }

  /** 记录见过的路径（诊断用，出问题时 hilog 里能看到服务端到底用了什么路径） */
  private notePath(path: string): void {
    if (path.length > 0 && this.seenPaths.indexOf(path) < 0) {
      this.seenPaths = this.seenPaths.length === 0 ? path : this.seenPaths + ',' + path;
    }
  }

  private pushDelta(fragType: string, text: string, cb: SseCallbacks): void {
    if (text.length === 0) {
      return;
    }
    this.textLen += text.length;
    if (cb.onDelta) {
      cb.onDelta(fragType, text, '');
    }
  }

  /** 取索引 i 的类型（取不到用最近片段类型兜底） */
  private typeAt(idx: number): string {
    if (idx >= 0 && idx < this.fragTypes.length) {
      const t: string = this.fragTypes[idx];
      if (t.length > 0) {
        return t;
      }
    }
    return this.lastFragType;
  }

  /** 路径里没有 fragments 索引时的兜底：按首段映射（response / thinking / search） */
  private typeFromPathHead(path: string): string {
    const slash: number = path.indexOf('/');
    const head: string = slash > 0 ? path.substring(0, slash) : path;
    if (head === 'thinking') {
      return FragmentType.THINK;
    }
    if (head === 'search') {
      return FragmentType.TOOL_SEARCH;
    }
    if (head === 'response') {
      return FragmentType.RESPONSE;
    }
    // 认不出：宁可多显示，也不能把回答整段丢掉
    return FragmentType.RESPONSE;
  }

  /**
   * 路径是否指向片段结构（而非正文）
   *   - `response/fragments`            → 数组（追加/替换整批片段）
   *   - `response/fragments/0`          → 单个片段对象
   *   - `response/fragments/0/content`  → 正文，不算结构路径
   */
  private static isFragmentsStructPath(p: string): boolean {
    if (p.endsWith('/content')) {
      return false;
    }
    return p === 'fragments' || p.endsWith('/fragments') || p.indexOf('/fragments/') >= 0;
  }

  /**
   * 解析 `a/fragments/<idx>/...` 里的 idx 并归一化
   *   - 路径里没有 fragments 段 → -1（调用方走兜底逻辑）
   *   - idx 为负（-1 = 最后一个）→ 换算成 `last`
   */
  private static resolveIndex(path: string, last: number): number {
    const segs: string[] = path.split('/');
    for (let i = 0; i < segs.length; i++) {
      if (segs[i] === 'fragments' && i + 1 < segs.length) {
        const n: number = parseInt(segs[i + 1]);
        if (isNaN(n)) {
          return -1;
        }
        return n < 0 ? last - 1 : n;
      }
    }
    return -1;
  }

  /** 归一化片段类型；返回空串表示「不展示」 */
  private static normalizeType(t: string): string {
    if (t === FragmentType.THINK || t === FragmentType.SEARCH) {
      return FragmentType.THINK;
    }
    if (t === FragmentType.TOOL_SEARCH || t === FragmentType.TOOL_OPEN
      || t === FragmentType.TOOL_FIND) {
      return FragmentType.TOOL_SEARCH;
    }
    if (t === 'REQUEST' || t === 'FILE' || t === 'TIP') {
      return '';
    }
    // RESPONSE / TEMPLATE_RESPONSE / 未知类型 → 一律当正文展示
    return FragmentType.RESPONSE;
  }

  // ==================================================================
  //   带 event 名的控制事件
  // ==================================================================

  /** 分发带 event 名的事件 */
  private dispatch(name: string, obj: Record<string, Object>, cb: SseCallbacks): void {
    if (name === SseEvent.READY) {
      if (cb.onReady) {
        cb.onReady();
      }
      return;
    }
    if (name === SseEvent.FINISH || name === SseEvent.CLOSE) {
      this.emitFinish(cb);
      return;
    }

    if (name === SseEvent.UPDATE_SESSION) {
      const sid: string = SseClient.pickStr(obj, 'chat_session_id');
      if (sid.length > 0 && cb.onSessionId) {
        cb.onSessionId(sid);
      }
      return;
    }

    if (name === SseEvent.HINT) {
      const c: string = SseClient.pickStr(obj, 'content');
      if (c.length > 0 && cb.onHint) {
        cb.onHint(c);
      }
      return;
    }

    if (name === SseEvent.TOAST) {
      const c: string = SseClient.pickStr(obj, 'content');
      if (c.length > 0 && cb.onToast) {
        cb.onToast(c);
      }
      return;
    }

    if (name === SseEvent.DELTA) {
      this.handleDelta(obj, cb);
    }
  }

  /**
   * delta 事件解析（兼容老版本「带 event: delta + 结构化 content」的形态）
   * 结构：{"type":"RESPONSE|THINK|TOOL_SEARCH","content":"...","id":"...","index":0}
   * 也兼容嵌套 {"value": "..."} 形式
   */
  private handleDelta(obj: Record<string, Object>, cb: SseCallbacks): void {
    let fragType: string = SseClient.pickStr(obj, 'type');
    let content: string = SseClient.pickStr(obj, 'content');
    const fid: string = SseClient.pickStr(obj, 'id');

    // 兼容 value 包装
    if (content.length === 0) {
      const v: Object | undefined = obj['value'];
      if (typeof v === 'string') {
        content = v as string;
      } else if (v !== undefined && v !== null && typeof v === 'object') {
        const inner: Record<string, Object> = v as Record<string, Object>;
        if (fragType.length === 0) {
          fragType = SseClient.pickStr(inner, 'type');
        }
        content = SseClient.pickStr(inner, 'content');
      }
    }

    if (fragType.length === 0) {
      fragType = FragmentType.RESPONSE;
    }
    if (content.length > 0 && cb.onDelta) {
      this.textLen += content.length;
      cb.onDelta(fragType, content, fid);
    }
  }

  private static pickStr(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
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

  /**
   * ArrayBuffer → UTF-8 字符串
   *
   * ⚠️ 统一换行符：服务端可能用 \r\n 分帧，
   *    而 consume() 只按 \n\n 切帧，不归一化会一帧都切不出来。
   */
  private static decode(buf: ArrayBuffer): string {
    const s: string = new util.TextDecoder('utf-8').decode(new Uint8Array(buf));
    return s.indexOf('\r') < 0 ? s : s.split('\r\n').join('\n').split('\r').join('\n');
  }

  /** 中断 */
  abort(): void {
    this.aborted = true;
    this.dispose();
  }

  isAborted(): boolean {
    return this.aborted;
  }

  private dispose(): void {
    this.stopWatchdog();
    if (this.request !== null) {
      try {
        this.request.destroy();
      } catch (e) {
        // ignore
      }
      this.request = null;
    }
  }
}
