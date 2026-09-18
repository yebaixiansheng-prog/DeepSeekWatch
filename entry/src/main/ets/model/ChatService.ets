import { DsApi, DsHeader, FragmentType, FragStatus, Role, DsCode, isAuthCode } from '../common/Constants';
import { Http, DsResponse } from './Http';
import { SseClient, SseCallbacks } from './SseClient';
import { PowSolver } from './PowSolver';

/**
 * 消息片段
 *
 * ⚠️ status 字段很重要：
 *   服务端 fragment 会带 `status`（WIP / FINISHED / FAILED / CONTENT_FILTER / TIMEOUT…）。
 *   UI 需要据此区分「思考中」与「已完成」，以及「被内容过滤」这类异常结束。
 */
export interface Fragment {
  id: string;
  type: string;      // THINK / RESPONSE / SEARCH / TOOL_SEARCH / TOOL_OPEN
  content: string;
  /** 片段状态（WIP / FINISHED / FAILED…），历史消息可能缺失，缺省视为 FINISHED */
  status: string;
  /** 搜索来源（TOOL_SEARCH 用） */
  results?: string[];
}

/** 一条消息 */
export interface ChatMessage {
  id: string;
  /** 'USER' | 'ASSISTANT'（统一使用服务端大写形式，避免大小写不一致） */
  role: string;
  fragments: Fragment[];
  /** 流式状态 */
  streaming: boolean;
  /** 已结束 */
  done: boolean;
  /**
   * ★ 修订号：每次内容变化 +1，**必须参与 ForEach 的 key**
   *
   * 为什么需要它（真机实测踩到的坑）：
   *   ArkUI 的 `ForEach(arr, item, key)` 按 key 做 diff，
   *   **key 不变时该项会被直接跳过、不重新渲染**（日志里是
   *   `AceForEach: ForEachNode skip mark dirty`）。
   *   流式回复的消息 id 是固定的（`a-xxx`），如果 key 只用 id，
   *   那么 SSE 增量虽然解析成功、`textLen` 也在涨，气泡却永远是空的 ——
   *   表现为「消息发出去了但没有任何回应」。
   *   把 rev 拼进 key，内容一变 key 就变，ForEach 才会重建这一项。
   */
  rev: number;
}

/** 会话摘要（历史对话列表项） */
export interface SessionInfo {
  id: string;
  title: string;
  /** 最后更新时间（毫秒，已由服务端秒级时间戳换算） */
  updatedAt: number;
  /** 是否置顶 */
  pinned: boolean;
}

/** 会话列表结果（把「空列表」和「请求失败」区分开，UI 才能给出对的提示） */
export interface SessionListResult {
  ok: boolean;
  sessions: SessionInfo[];
  /** 失败原因（本地化文案），ok=true 时为空串 */
  message: string;
  /** 需要重新登录（token 失效），UI 据此给出「重新登录」入口 */
  needRelogin?: boolean;
}

/** 对话参数 */
export interface ChatParams {
  sessionId: string;
  parentMessageId: string | null;
  prompt: string;
  thinkingEnabled: boolean;
  searchEnabled: boolean;
  modelType: string;
}

/** 对话状态回调 */
export interface ChatCallbacks {
  onSessionCreated?: (sessionId: string) => void;
  onThinkingDelta?: (text: string) => void;
  onResponseDelta?: (text: string) => void;
  onSearchResult?: (text: string) => void;
  onPowProgress?: (tried: number, total: number) => void;
  onHint?: (text: string) => void;
  onFinish?: () => void;
  onError?: (msg: string) => void;
}

/**
 * DeepSeek 对话服务
 *
 * 完整流程：
 *   1. PoW：POST create_pow_challenge → 求解 → X-DS-PoW-Response 头
 *   2. POST /api/v0/chat/completion （SSE 流式）
 *   3. 解析 delta 事件，按 fragment 类型分派给 UI
 */
export class ChatService {
  private sse: SseClient | null = null;

  /**
   * 上一次对话的 session / message id
   *
   * 用途：下一轮发送前主动给服务端发 `stop_stream`，
   *      清掉可能还在跑的「僵尸流」（本地断了、服务端没断）。
   *      这是 `preempt:true` 之外的第二道保险。
   */
  private lastSessionId: string = '';
  private lastMessageId: string = '';

  /** 记录本轮请求在服务端产生的 message_id（供 stop 使用） */
  private rememberTurn(sessionId: string, messageId: string): void {
    if (messageId.length > 0) {
      this.lastSessionId = sessionId;
      this.lastMessageId = messageId;
    }
  }

  /** 清掉记录的僵尸流信息（会话已经干净结束时调用） */
  private clearTurn(): void {
    this.lastSessionId = '';
    this.lastMessageId = '';
  }

  /** 发起一次对话 */
  async send(token: string, p: ChatParams, targetPath: string, cb: ChatCallbacks): Promise<void> {
    // 0. 先清掉可能还挂着的旧流，避免重试时两条流同时往 UI 灌内容
    this.abortStream();

    // 0.5 ★ 服务端「僵尸流」清场
    //     本地 abort() 只是断开 HTTP 连接，**服务端那条流还在跑**。
    //     如果再叠加 `preempt:false`，新请求会被排队挂死
    //     （这就是「聊两轮之后再也发不出去」的成因，详见下方 preempt 注释）。
    //     现在双保险：① preempt:true 由服务端抢占；② 主动通知上一轮停流。
    //     这里用 fire-and-forget：停流失败不影响新请求（preempt 已经兜住了）。
    if (this.lastSessionId.length > 0 && this.lastMessageId.length > 0) {
      this.stop(token, this.lastSessionId, this.lastMessageId).catch(() => {
      });
    }

    // 1. 准备 PoW
    let powHeader: string | null = null;
    try {
      powHeader = await PowSolver.prepare(token, targetPath, cb.onPowProgress);
    } catch (e) {
      powHeader = null;
    }
    if (powHeader === null) {
      if (cb.onError) {
        // ★ 把 PoW 的具体病因透出去，而不是笼统的 'pow_failed'。
        //   「没拿到挑战」（网络/风控，重试有意义）与
        //   「求解超时」（算力不足，重试大概率还超时）对用户是两回事，
        //   给同一句"请重试"会让人陷入无效重试。
        const why: string = PowSolver.getLastFail();
        cb.onError(why.length > 0 ? why : 'pow_failed');
      }
      return;
    }

    // 2. 构造请求体
    //
    // ★★★ preempt 必须是 **true** —— 这是「聊两轮就再也发不出去」的真凶 ★★★
    //
    //   实测 + 线上 bundle 行为对照（2026-09-18）：
    //     `preempt:false` = **排队**语义。服务端发现这个 session 上还有一条
    //     未结束的流（哪怕是上一轮「网络抖动后本地已放弃、服务端还在跑」的僵尸流），
    //     就会把新请求**挂在队列里**，既不回 SSE 数据、也不报错。
    //     → 客户端表现为：连接建立（HTTP 200）、一直空等、`onFinish` 永不到达、
    //       状态永远停在「准备中…」，用户看到的就是「它不能对话了」。
    //     `preempt:true` = **抢占**语义：服务端先终止该 session 上的旧流，
    //     再开始新一轮。这正是官方 web 客户端「发送」按钮的行为。
    //
    //   为什么偏偏「两次之后」中招：
    //     第 1 轮正常结束 → 干净；第 2 轮如果用户中途退出页面 / 掉网 / 息屏，
    //     服务端那条流并不会立刻结束，于是第 3 轮开始就撞上排队。
    //     只要有一轮没干净收尾，之后就**永远**好不了 —— 与用户描述完全一致。
    //
    //   ⚠️ ArkTS 无法表达 JSON null，`parent_message_id` 只在非 null 时写入。
    const bodyObj: Record<string, Object> = {
      'chat_session_id': p.sessionId,
      'prompt': p.prompt,
      'ref_file_ids': [],
      'thinking_enabled': p.thinkingEnabled,
      'search_enabled': p.searchEnabled,
      'preempt': true,
      'model_type': p.modelType
    };
    if (p.parentMessageId !== null) {
      bodyObj['parent_message_id'] = p.parentMessageId;
    }

    const extra: Record<string, string> = {};
    extra[DsHeader.POW] = powHeader;

    // 3. 流式请求
    const client: SseClient = new SseClient();
    this.sse = client;

    const sseCb: SseCallbacks = {
      onReady: () => {
      },
      onSessionId: (id: string) => {
        if (cb.onSessionCreated) {
          cb.onSessionCreated(id);
        }
      },
      onMessageId: (id: string) => {
        // 记下服务端为这一轮分配的 message_id：下一轮发送前要靠它停掉僵尸流
        this.rememberTurn(p.sessionId, id);
      },
      onDelta: (fragType: string, content: string, fragmentId: string) => {
        if (fragType === FragmentType.THINK) {
          if (cb.onThinkingDelta) {
            cb.onThinkingDelta(content);
          }
        } else if (fragType === FragmentType.TOOL_SEARCH) {
          if (cb.onSearchResult) {
            cb.onSearchResult(content);
          }
        } else {
          if (cb.onResponseDelta) {
            cb.onResponseDelta(content);
          }
        }
      },
      onHint: (text: string) => {
        if (cb.onHint) {
          cb.onHint(text);
        }
      },
      onToast: (text: string) => {
        if (cb.onHint) {
          cb.onHint(text);
        }
      },
      onFinish: () => {
        // 这一轮干净结束了 → 不需要再向服务端停流
        this.clearTurn();
        if (cb.onFinish) {
          cb.onFinish();
        }
      },
      onError: (msg: string) => {
        if (cb.onError) {
          cb.onError(msg);
        }
      }
    };

    await client.start(DsApi.ORIGIN + targetPath, JSON.stringify(bodyObj), token, extra, sseCb);
  }

  /**
   * 停止生成
   *
   * ⚠️ `messageId` **不能留空**（2026-09-18 修正）：
   *    旧调用方传的是 `''`，服务端收到空 id 会直接忽略这个请求，
   *    结果是「本地以为停了、服务端还在跑」——
   *    这些残留流会在下一轮把新请求排队挂死，
   *    正是「聊两轮之后再也发不出去」的链条起点。
   *
   *    现在传空时自动回退到最近一次记录的 message_id；
   *    两者都没有才放弃（此时通常本来就没有流在跑）。
   */
  async stop(token: string, sessionId: string, messageId: string): Promise<void> {
    this.abortStream();
    const sid: string = sessionId.length > 0 ? sessionId : this.lastSessionId;
    let mid: string = messageId;
    if (mid.length === 0) {
      mid = this.lastMessageId;
    }
    if (sid.length === 0 || mid.length === 0) {
      // 没有可停的目标：不浪费一次请求
      return;
    }
    const body: string = JSON.stringify({
      'chat_session_id': sid,
      'message_id': mid
    });
    await Http.postRaw(DsApi.ORIGIN + DsApi.STOP_STREAM, body, token, null);
    this.clearTurn();
  }

  /**
   * 仅中断本地 SSE（**不**通知服务端停流）
   *
   * 用于「重试前先清场」：旧流的回调仍指向同一个 UI 回调对象，
   * 不断开的话重试期间会出现两条流同时灌内容（正文重复/错乱）。
   */
  abortStream(): void {
    if (this.sse !== null) {
      this.sse.abort();
      this.sse = null;
    }
  }

  /** 新建会话 */
  static async createSession(token: string): Promise<string> {
    const body: string = JSON.stringify({});
    const res: DsResponse = await Http.postJson(DsApi.ORIGIN + DsApi.SESSION_CREATE, body, token, null);
    if (res.code === 0 && res.data !== null && res.data.biz_data !== null) {
      const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
      const v: Object | undefined = bd['chat_session'];
      if (v !== undefined && v !== null) {
        const s: Record<string, Object> = v as Record<string, Object>;
        const id: Object | undefined = s['id'];
        if (typeof id === 'string') {
          return id as string;
        }
      }
      const id2: Object | undefined = bd['id'];
      if (typeof id2 === 'string') {
        return id2 as string;
      }
    }
    return '';
  }

  /**
   * 拉取「历史对话」列表（会话分页）
   *
   * ⚠️ 实测（2026-09 对 chat.deepseek.com 线上 bundle `main.*.js` 逆向）：
   *    这个接口是 **GET**，游标走 **URL query**，**不是** POST body：
   *
   *      GET /api/v0/chat_session/fetch_page
   *          ?lte_cursor.pinned=false&lte_cursor.updated_at=<秒>&count=50
   *
   *    线上客户端首屏用的是 `lte_cursor.pinned=false`（`updated_at` 为 null），
   *    即「从最新往前翻一页」；`gte_cursor.*` 用于下拉刷新。
   *
   *    响应字段（biz_data）：
   *      chat_sessions: [{ id, title, title_type, updated_at(秒), pinned, model_type }]
   *      has_more: boolean
   *
   *    注意 `updated_at` 是**秒**，展示前要 ×1000。
   */
  static async listSessions(token: string, count: number = 50): Promise<SessionListResult> {
    const out: SessionInfo[] = [];
    if (token.length === 0) {
      return { ok: false, sessions: out, message: '登录已失效，请重新登录', needRelogin: true };
    }
    const base: string = DsApi.ORIGIN + DsApi.SESSION_FETCH;
    const cnt: string = count.toString();

    // 首选：与线上客户端首屏完全一致的形态（不带 updated_at 游标）
    let res: DsResponse = await Http.getJson(
      base + '?lte_cursor.pinned=false&count=' + cnt, token);

    // 兜底：少数版本要求显式给出游标时间，缺失会直接报错 → 用「当前秒」当上界重试
    if (res.code !== 0 || res.data === null) {
      const nowSec: number = Math.floor(Date.now() / 1000);
      res = await Http.getJson(
        base + '?lte_cursor.pinned=false&lte_cursor.updated_at='
          + nowSec.toString() + '&count=' + cnt, token);
    }

    if (res.code === DsCode.LOCAL_NETWORK) {
      return { ok: false, sessions: out, message: '网络连接失败，请重试' };
    }
    // ★ token 过期 / 被顶号：服务端返回 40002/40003，且 **HTTP 状态码仍是 200**
    //   旧代码会把它归成「获取会话列表失败」并让用户反复重试，永远好不了。
    if (isAuthCode(res.code)) {
      return { ok: false, sessions: out, message: '登录已失效，请重新登录', needRelogin: true };
    }
    if (res.code === DsCode.LOCAL_BAD_PAYLOAD) {
      return { ok: false, sessions: out, message: '服务端返回异常，请稍后重试' };
    }
    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      return { ok: false, sessions: out, message: '获取会话列表失败，请重试' };
    }
    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
    const arr: Object | undefined = bd['chat_sessions'];
    if (arr === undefined || arr === null || !Array.isArray(arr)) {
      return { ok: false, sessions: out, message: '会话数据格式异常' };
    }
    const list: Object[] = arr as Object[];
    for (let i = 0; i < list.length; i++) {
      const s: Record<string, Object> = list[i] as Record<string, Object>;
      const id: string = ChatService.str(s, 'id');
      if (id.length === 0) {
        continue;
      }
      let title: string = ChatService.str(s, 'title');
      if (title.length === 0) {
        title = '未命名对话';
      }
      const sec: number = ChatService.num(s, 'updated_at');
      const pinRaw: Object | undefined = s['pinned'];
      out.push({
        id: id,
        title: title,
        updatedAt: sec > 0 ? sec * 1000 : 0,
        pinned: pinRaw === true
      });
    }
    // 置顶优先、其余按最近更新倒序（服务端已排好，这里再兜一层，防止分页拼接后错序）
    out.sort((a: SessionInfo, b: SessionInfo): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updatedAt - a.updatedAt;
    });
    return { ok: true, sessions: out, message: '' };
  }

  /**
   * 拉取历史消息
   *
   * ⚠️ 实测（bundle 逆向）：`/api/v0/chat/history_messages` 是 **GET**，
   *    且查询参数走 **URL query string**（不是 POST body）：
   *      GET /api/v0/chat/history_messages?chat_session_id=xxx
   *    客户端内部把 `{query:{...}}` 合并进最终 URL，再用
   *    `url.split("?")[0]` 反推 path 用于埋点 —— 证明 query 确实在 URL 上。
   *
   *    另：可信缓存版本参数 `cache_version` / `cache_reset_at` 传 null 即可，
   *    首次拉取时服务端会直接返回全量。
   */
  static async history(token: string, sessionId: string): Promise<ChatMessage[]> {
    const out: ChatMessage[] = [];
    if (sessionId.length === 0) {
      return out;
    }
    const url: string = DsApi.ORIGIN + DsApi.HISTORY
      + '?chat_session_id=' + encodeURIComponent(sessionId);
    const res: DsResponse = await Http.getJson(url, token);
    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      return out;
    }
    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;

    // ⚠️ 实测：历史消息在 `chat_messages`；部分版本会包一层 `chat_session`
    const direct: Object | undefined = bd['chat_messages'];
    let list: Object[] | null = null;
    if (direct !== undefined && direct !== null && Array.isArray(direct)) {
      list = direct as Object[];
    } else {
      const sess: Object | undefined = bd['chat_session'];
      if (sess !== undefined && sess !== null) {
        const so: Record<string, Object> = sess as Record<string, Object>;
        const inner: Object | undefined = so['chat_messages'];
        if (inner !== undefined && inner !== null && Array.isArray(inner)) {
          list = inner as Object[];
        }
      }
    }
    if (list === null) {
      return out;
    }

    // ⚠️ 实测：服务端 `chat_messages` 是**扁平数组**，靠 `parent_id` 串成树，
    //    不是天然的线性对话。这里按 parent_id 链还原出正确的展示顺序，
    //    否则历史消息会出现「顺序错乱 / 同一分支重复」的问题。
    const parsed: ChatMessage[] = [];
    const parents: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const m: Record<string, Object> = list[i] as Record<string, Object>;
      const cm: ChatMessage = ChatService.parseMessage(m);
      parsed.push(cm);
      parents.push(ChatService.str(m, 'parent_id'));
    }
    return ChatService.linearize(parsed, parents);
  }

  /**
   * 把 parent_id 树还原成一条线性对话
   *
   * 策略：从「没有子节点的末端」沿 parent_id 一路回溯到根，
   *       得到主链后反转。若链路过短（字段缺失），退回原顺序。
   */
  private static linearize(msgs: ChatMessage[], parents: string[]): ChatMessage[] {
    if (msgs.length <= 1) {
      return msgs;
    }
    // 建 id → 下标 索引
    const idToIdx: Record<string, number> = {};
    for (let i = 0; i < msgs.length; i++) {
      if (msgs[i].id.length > 0) {
        idToIdx[msgs[i].id] = i;
      }
    }
    // 找「不是任何消息的 parent」的那些消息 → 叶子节点
    const hasChild: Record<string, boolean> = {};
    for (let i = 0; i < parents.length; i++) {
      const p: string = parents[i];
      if (p.length > 0) {
        hasChild[p] = true;
      }
    }
    let leafIdx: number = -1;
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (hasChild[msgs[i].id] !== true) {
        leafIdx = i;
        break;
      }
    }
    if (leafIdx < 0) {
      return msgs;
    }
    // 沿 parent 回溯
    const chain: ChatMessage[] = [];
    let cur: number = leafIdx;
    let guard: number = 0;
    while (cur >= 0 && guard < msgs.length + 2) {
      chain.push(msgs[cur]);
      const pid: string = parents[cur];
      if (pid.length === 0) {
        break;
      }
      const ni: number | undefined = idToIdx[pid];
      if (ni === undefined) {
        break;
      }
      cur = ni;
      guard++;
    }
    // 链路不完整（字段缺失/无 parent_id）→ 退回原顺序
    if (chain.length < 2) {
      return msgs;
    }
    chain.reverse();
    return chain;
  }

  /**
   * 解析服务端消息 → 本地结构
   *
   * ⚠️ 服务端 `role` 是**大写**（USER / ASSISTANT），早期版本曾按小写比较导致
   *    用户消息被误判为助手消息、气泡对齐全错。此处统一归一化为大写。
   */
  static parseMessage(m: Record<string, Object>): ChatMessage {
    const id: string = ChatService.str(m, 'id');
    const roleRaw: string = ChatService.str(m, 'role');
    // 归一化：服务端走大写，历史兼容小写
    const role: string = roleRaw.toUpperCase() === Role.USER ? Role.USER : Role.ASSISTANT;

    const statusRaw: string = ChatService.str(m, 'status');
    // 服务端 MessageStatus.OK 在序列化层是 "FINISHED"，但历史接口可能返回其他值
    const finished: boolean = statusRaw.length === 0 || statusRaw === FragStatus.FINISHED;

    const msg: ChatMessage = {
      id: id,
      role: role,
      fragments: [],
      streaming: false,
      done: finished,
      rev: 0
    };
    const f: Object | undefined = m['fragments'];
    if (f !== undefined && f !== null) {
      const fl: Object[] = f as Object[];
      for (let i = 0; i < fl.length; i++) {
        const fo: Record<string, Object> = fl[i] as Record<string, Object>;
        const t: string = ChatService.str(fo, 'type');
        const c: string = ChatService.str(fo, 'content');
        const fid: string = ChatService.str(fo, 'id');
        const stRaw: string = ChatService.str(fo, 'status');
        // 缺省视为已完成（历史消息常常不带 status）
        const st: string = stRaw.length === 0 ? FragStatus.FINISHED : stRaw;

        if (t === FragmentType.RESPONSE || t === FragmentType.TEMPLATE_RESPONSE) {
          msg.fragments.push({ id: fid, type: FragmentType.RESPONSE, content: c, status: st });
        } else if (t === FragmentType.THINK) {
          msg.fragments.push({ id: fid, type: FragmentType.THINK, content: c, status: st });
        } else if (t === FragmentType.SEARCH) {
          // SEARCH 片段正文是可读文本，归入 THINK 区一起展示
          msg.fragments.push({ id: fid, type: FragmentType.THINK, content: c, status: st });
        } else if (t === FragmentType.TOOL_SEARCH || t === FragmentType.TOOL_OPEN
          || t === FragmentType.TOOL_FIND) {
          msg.fragments.push({
            id: fid, type: FragmentType.TOOL_SEARCH, content: '', status: st, results: []
          });
        }
        // 其余（REQUEST / FILE / TIP）不展示
      }
    }
    // 有些消息 content 直接放在顶层
    if (msg.fragments.length === 0) {
      const c: string = ChatService.str(m, 'content');
      if (c.length > 0) {
        msg.fragments.push({
          id: id + '-c', type: FragmentType.RESPONSE, content: c, status: FragStatus.FINISHED
        });
      }
    }
    return msg;
  }

  private static str(o: Record<string, Object>, k: string): string {
    const v: Object | undefined = o[k];
    if (v === undefined || v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  /** 宽松取数：number 直接用，string 尝试 parseInt */
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
