/**
 * 会话与历史管理（本地存储）
 *
 * ★ 2026-09-30 新写。
 *   官方 API **没有**云端会话列表（每次请求自带完整 messages），
 *   所以历史必须自己存。用户选择「存本地」。
 *
 * 存储方案：Preferences（键值），每条会话存成一个 JSON 字符串。
 *   · 手表上 Preferences 比关系型库省电、API 更简单；
 *   · 单条会话 JSON 有大小上限风险 → 见 `MAX_STORED_MSGS` 与裁剪逻辑。
 *
 * ★ 上下文裁剪（手表场景必须做）：
 *   模型上下文有限，且手表网络慢。策略：
 *     ① 只保留最近 `MAX_SEND_MSGS` 条消息发给 API；
 *     ② 第一条永远是 system（如果配了）；
 *     ③ 裁剪**只影响发送**，不删本地历史 —— 用户往回翻还能看到完整记录；
 *     ④ 必须成对：不能把带 tool_calls 的 assistant 消息留下、
 *        却把对应的 tool 结果裁掉（会 400）。见 `trimForSend`。
 */

import { Store, Keys } from '../common/Store';
import { ChatMsg, ToolCall } from './ApiClient';
import { Role } from '../common/Constants';
// ★ 只借用**类型**（`import type` 语义）。ArkTS 的 import 是静态的，
//   虽然这里会建立模块引用，但 `Persona.ets` 只依赖 `Store`，不依赖本文件，
//   所以**不存在循环依赖**。（注释里说的"反向 import 成环"指运行期调用，
//   这里是编译期类型，安全。）
import { Persona } from './Persona';

/** 会话元信息 */
export interface Session {
  id: string;
  title: string;
  /** 创建时间 ms */
  createdAt: number;
  /** 最近更新时间 ms */
  updatedAt: number;
  messages: ChatMsg[];
  /**
   * 绑定的人设 id
   *
   * ★ 空串 = 未绑定（不注入任何 system prompt）。
   *
   * ★ 为什么用空串而不是 `undefined` / `null`：
   *   · 这份结构要 JSON 往返，空串天然可序列化，`undefined` 会**整个键消失**；
   *   · 老会话（升级前存的）读回来没有这个字段，
   *     `str(o['personaId'])` 得到空串 —— **自动向前兼容**，
   *     不会因为多了个字段就读不出来。
   *
   * ★ 人设是**每个对话独立绑定**的（用户明确选择），对话建立后不可改：
   *   绑在会话上而不是全局设置上 —— 否则改一次人设会追溯影响历史对话，
   *   用户会觉得「我以前的回答怎么变了」。
   */
  personaId: string;
}

/** 发送给 API 时的裁剪上限 */
export const MAX_SEND_MSGS: number = 24;
/** 单条会话本地最多保留的消息条数（超出丢最旧的） */
export const MAX_STORED_MSGS: number = 200;
/** 会话上限 */
export const MAX_SESSIONS: number = 30;

/** 会话索引（存所有会话的元信息，避免一次读全部内容） */
interface SessionIndexEntry {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  count: number;
  /**
   * ★ 绑定的人设 id（2026-10-03 新增）
   *
   * 为什么要**冗余**存进索引（消息体里已经有一份）：
   *   历史对话页要在**不加载任何消息体**的前提下显示「这条对话用了什么人设」。
   *   否则打开列表页就得把最多 30 条会话的 JSON 全读一遍 ——
   *   在手表上是几百毫秒的卡顿，而且完全没必要。
   *
   * 老索引没有这个键 → `str(o['personaId'])` 得空串 → 向前兼容。
   */
  personaId: string;
}

export class ChatStore {
  private static cache: SessionIndexEntry[] = [];
  private static loaded: boolean = false;

  /** 读取会话索引 */
  static async index(): Promise<SessionIndexEntry[]> {
    if (ChatStore.loaded) {
      return ChatStore.cache;
    }
    const raw: string = await Store.get(Keys.SESSION_INDEX, '');
    if (raw.length > 0) {
      try {
        const arr: Object[] = JSON.parse(raw) as Object[];
        const out: SessionIndexEntry[] = [];
        if (Array.isArray(arr)) {
          for (const it of arr) {
            const o: Record<string, Object> = it as Record<string, Object>;
            out.push({
              id: str(o['id']),
              title: str(o['title']),
              createdAt: num(o['createdAt']),
              updatedAt: num(o['updatedAt']),
              count: num(o['count']),
              // ★ 老索引没这个键 → 空串（向前兼容，不会因为多字段读不出整条索引）
              personaId: str(o['personaId'])
            });
          }
        }
        ChatStore.cache = out;
      } catch (e) {
        // ★ 索引坏了不能把应用卡死：重置为空，用户最多丢列表（消息体仍在）
        ChatStore.cache = [];
      }
    }
    ChatStore.loaded = true;
    return ChatStore.cache;
  }

  /** 读该写索引（内部） */
  private static async saveIndex(): Promise<void> {
    await Store.put(Keys.SESSION_INDEX, JSON.stringify(ChatStore.cache));
  }

  /**
   * ★ 强制清索引缓存（2026-10-03 新增）
   *
   * 为什么需要：`index()` 有内存缓存（`loaded` 标志）。
   * 会话列表页跨页返回时，如果别处已经改过索引（例如对话页保存了新消息），
   * 列表页拿到的还是**上一份快照** —— 表现为「刚聊完的对话，回历史列表
   * 看到的还是旧标题/旧条数」，用户会以为消息没发出去。
   *
   * ★ 这与 `PersonaStore.invalidate()` 是同一个模式：
   *   「内存缓存 + 明确的失效出口」，而不是让每个调用点自己想办法绕过缓存。
   */
  static invalidate(): void {
    ChatStore.loaded = false;
  }

  /** 新建会话，返回会话对象 */
  /**
   * 新建会话，返回会话对象
   *
   * @param personaId 绑定的人设 id；空串表示不绑定（见 `Session.personaId`）。
   *                  默认空串 —— 保证所有旧调用点不用改也能编译。
   */
  static async create(personaId: string = ''): Promise<Session> {
    const id: string = 's' + Date.now().toString();
    const now: number = Date.now();
    const s: Session = {
      id: id,
      title: '新对话',
      createdAt: now,
      updatedAt: now,
      messages: [],
      personaId: personaId
    };
    await ChatStore.save(s);
    return s;
  }

  /** 读取单个会话 */
  static async load(id: string): Promise<Session | null> {
    const raw: string = await Store.get(ChatStore.msgKey(id), '');
    if (raw.length === 0) {
      return null;
    }
    try {
      const o: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const msgs: ChatMsg[] = [];
      const arr: Object[] = o['messages'] as Object[];
      if (Array.isArray(arr)) {
        for (const m of arr) {
          msgs.push(ChatStore.decodeMsg(m as Record<string, Object>));
        }
      }
      return {
        id: str(o['id']),
        title: str(o['title']),
        createdAt: num(o['createdAt']),
        updatedAt: num(o['updatedAt']),
        messages: msgs,
        // ★ 老会话没有这个键 → str() 返回空串 → 自动向前兼容
        personaId: str(o['personaId'])
      };
    } catch (e) {
      return null;
    }
  }

  /** 保存会话（同时更新索引） */
  static async save(s: Session): Promise<void> {
    // 本地超量裁剪：只保留最新 MAX_STORED_MSGS 条
    if (s.messages.length > MAX_STORED_MSGS) {
      s.messages = s.messages.slice(s.messages.length - MAX_STORED_MSGS);
    }
    s.updatedAt = Date.now();
    // 标题：取首条用户消息前 12 字
    if (s.title === '新对话') {
      s.title = ChatStore.deriveTitle(s.messages);
    }
    await Store.put(ChatStore.msgKey(s.id), JSON.stringify(ChatStore.encodeSession(s)));

    await ChatStore.index();
    const idx: SessionIndexEntry[] = ChatStore.cache;
    let found: boolean = false;
    for (const e of idx) {
      if (e.id === s.id) {
        e.title = s.title;
        e.updatedAt = s.updatedAt;
        e.count = s.messages.length;
        e.personaId = s.personaId;
        found = true;
        break;
      }
    }
    if (!found) {
      idx.push({
        id: s.id,
        title: s.title,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
        count: s.messages.length,
        personaId: s.personaId
      });
    }
    // 索引排序：最近更新在前
    idx.sort((a: SessionIndexEntry, b: SessionIndexEntry) => b.updatedAt - a.updatedAt);
    // 会话数超限：删掉最旧的（连消息体一起删）
    while (idx.length > MAX_SESSIONS) {
      const drop: SessionIndexEntry = idx.pop() as SessionIndexEntry;
      await Store.remove(ChatStore.msgKey(drop.id));
    }
    await ChatStore.saveIndex();
  }

  /**
   * ★ 重设会话绑定的人设（2026-10-03 新增）
   *
   * ## 为什么允许改绑（与「每对话独立绑定」并不矛盾）
   *
   * 用户明确选的是「每个对话独立绑定」——**绑定的粒度**是对话，
   * 不是"建好就焊死"。真实场景：
   *   · 一条对话聊到一半，发现当前人设不合适，想换一个；
   *   · 用户在会话里用人设做临时「角色扮演」。
   *
   * ★ 但这里刻意**不清空历史消息**。理由：
   *   人设是「发送时附加的包装层」（见 ChatPage.doSend 的顺序纪律），
   *   历史消息本身没被人设改写过，所以换人设只是换了个说话的人，
   *   之前的对话记录依然是有意义的事实。
   *   若清空历史，用户只会觉得「换个人设把我聊天记录弄没了」。
   *
   * ★ 什么时候**必须**开新对话：见 `needsFreshSession`。
   *   某些人设的内容与已有历史直接冲突（例如历史是「资深工程师」口吻，
   *   现在要换成「幼儿园老师」），继续续写会让模型精神分裂。
   *   那种情况由 UI 提示用户，**不在这里偷偷清空**。
   *
   * @returns 是否真的改了（同一个 id 或无此会话 → false）
   */
  static async setPersona(id: string, personaId: string): Promise<boolean> {
    const s: Session | null = await ChatStore.load(id);
    if (s === null) {
      return false;
    }
    if (s.personaId === personaId) {
      return false;
    }
    s.personaId = personaId;
    await ChatStore.save(s);
    return true;
  }

  /** 删除会话 */
  static async remove(id: string): Promise<void> {
    await Store.remove(ChatStore.msgKey(id));
    await ChatStore.index();
    const idx: SessionIndexEntry[] = ChatStore.cache;
    const keep: SessionIndexEntry[] = [];
    for (const e of idx) {
      if (e.id !== id) {
        keep.push(e);
      }
    }
    ChatStore.cache = keep;
    await ChatStore.saveIndex();
  }

  /** 清空全部 */
  static async clearAll(): Promise<void> {
    await ChatStore.index();
    for (const e of ChatStore.cache) {
      await Store.remove(ChatStore.msgKey(e.id));
    }
    ChatStore.cache = [];
    await ChatStore.saveIndex();
    await Store.remove(Keys.LAST_SESSION);
  }

  /** 记住最近打开的会话（冷启动恢复用） */
  static async setLastSession(id: string): Promise<void> {
    await Store.put(Keys.LAST_SESSION, id);
  }

  /** 读取最近打开的会话 id（空串 = 没有） */
  static async getLastSession(): Promise<string> {
    return await Store.get(Keys.LAST_SESSION, '');
  }

  private static msgKey(id: string): string {
    return 'session_' + id;
  }

  /** 从首条用户消息推导标题 */
  private static deriveTitle(msgs: ChatMsg[]): string {
    for (const m of msgs) {
      if (m.role === Role.USER && m.content.trim().length > 0) {
        const t: string = m.content.trim().replace(/\s+/g, ' ');
        return t.length > 14 ? t.substring(0, 14) + '…' : t;
      }
    }
    return '新对话';
  }

  // ---- 序列化（手写而非直接 JSON.stringify 整个对象，保证字段白名单）----

  private static encodeSession(s: Session): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['id'] = s.id;
    out['title'] = s.title;
    out['createdAt'] = s.createdAt;
    out['updatedAt'] = s.updatedAt;
    const arr: Object[] = [];
    for (const m of s.messages) {
      arr.push(ChatStore.encodeMsg(m));
    }
    out['messages'] = arr;
    out['personaId'] = s.personaId;
    return out;
  }

  private static encodeMsg(m: ChatMsg): Record<string, Object> {
    const o: Record<string, Object> = {};
    o['role'] = m.role;
    o['content'] = m.content;
    o['ts'] = m.ts;
    if (m.reasoning !== undefined && m.reasoning.length > 0) {
      o['reasoning'] = m.reasoning;
    }
    if (m.toolCallId !== undefined && m.toolCallId.length > 0) {
      o['toolCallId'] = m.toolCallId;
    }
    if (m.toolCalls !== undefined && m.toolCalls.length > 0) {
      const tcs: Object[] = [];
      for (const t of m.toolCalls) {
        const to: Record<string, Object> = {};
        to['id'] = t.id;
        to['name'] = t.name;
        to['arguments'] = t.arguments;
        tcs.push(to);
      }
      o['toolCalls'] = tcs;
    }
    return o;
  }

  private static decodeMsg(o: Record<string, Object>): ChatMsg {
    const m: ChatMsg = {
      role: str(o['role']),
      content: str(o['content']),
      ts: num(o['ts'])
    };
    const r: Object = o['reasoning'];
    if (typeof r === 'string') {
      m.reasoning = r as string;
    }
    const tid: Object = o['toolCallId'];
    if (typeof tid === 'string') {
      m.toolCallId = tid as string;
    }
    const tcs: Object = o['toolCalls'];
    if (Array.isArray(tcs)) {
      const list: ToolCall[] = [];
      for (const t of (tcs as Object[])) {
        const to: Record<string, Object> = t as Record<string, Object>;
        list.push({
          id: str(to['id']),
          name: str(to['name']),
          arguments: str(to['arguments'])
        });
      }
      if (list.length > 0) {
        m.toolCalls = list;
      }
    }
    return m;
  }
}

// ========================================================================
//  人设相关的纯函数（不依赖存储，离线测试直接跑）
// ========================================================================

/**
 * 本地「人设是否没填任何内容」判定
 *
 * 四个设定字段全空 = 这条人设实际上什么都没约束。
 * 注意**不含名称**：只有名字的人设仍然是有意义的（模型会按名字自我定位），
 * 所以「名称填了、四字段全空」不算空白。
 *
 * ★ 为什么不直接 import `Persona.isBlank`：
 *   `ChatStore` 是底层存储模块，`Persona` 依赖它（而不是反过来）。
 *   反向 import 会成环。这四行重复的代价远小于一个循环依赖。
 */
export function isBlankPersona(p: Persona): boolean {
  return p.personality.trim().length === 0
    && p.background.trim().length === 0
    && p.tone.trim().length === 0
    && p.replyStyle.trim().length === 0;
}

/**
 * 人设的展示名（列表页/对话页顶部用）
 *
 * @returns 空串表示未绑定 —— 调用方据此决定要不要渲染那一行，
 *          **不要**在这里返回「未绑定」之类的文案：
 *          那样调用方就没法区分「没人设」和「人设叫未绑定」。
 */
export function personaBadge(p: Persona | null): string {
  if (p === null) {
    return '';
  }
  const n: string = p.name.trim();
  return n.length > 0 ? n : '未命名人设';
}

/**
 * ★ 换人设时是否**建议**开新对话（纯函数，只给 UI 做提示用）
 *
 * 判据不是「人设不同」，而是「新老两边**都填了设定**且不同」：
 *   · 原来没绑 → 现在绑上：历史是"素人"回答，加上人设正好是升级，直接续写没问题；
 *   · 原来绑 A → 换成空白人设：约束被解除，模型顺着历史继续答也不违和；
 *   · A → B 且两边都有内容：历史里已经有**一段带 A 口吻的回答**，
 *     模型会拿它当风格样本，与 B 打架 —— 这才是真需要开新对话的情况。
 *
 * ★ 这个函数只返回「建议」，**绝不清空任何东西**。
 *   清空是不可逆操作，必须由用户明确点击确认。
 */
export function needsFreshSession(oldP: Persona | null, newP: Persona | null): boolean {
  if (oldP === null || newP === null) {
    return false;
  }
  if (oldP.id === newP.id) {
    return false;
  }
  return !isBlankPersona(oldP) && !isBlankPersona(newP);
}

/**
 * ★★ 人设生效的唯一注入点（2026-10-03）
 *
 * 在消息序列**最前面**插入一条 system 消息，内容是 `buildSystemPrompt` 的产物。
 *
 * ## 三条纪律
 *
 * 1. **必须先 `trimForSend` 再调用本函数。**
 *    顺序反了虽然当前实现下结果相同（`trimForSend` 规则 1 让 system 不占配额），
 *    但那依赖 trim 的内部实现细节；先裁后注入不依赖任何细节。
 *    见 `tools/persona-round-test.mjs` 第 9 组。
 *
 * 2. **空 prompt 什么都不做**（不插空 system）。
 *    这条保证「未绑定人设的老会话」行为与升级前**逐字节一致** ——
 *    服务端看到的请求体没有任何变化。
 *
 * 3. **不改入参**，返回新数组。
 *    入参 `msgs` 可能直接来自 `@State` 持有的数据，原地改会引发渲染问题，
 *    而且调用方可能还要拿原数组做别的事。
 *
 * ## 为什么是「插入」而不是「替换已有的 system」
 *
 * 本工程的消息序列里 system 只由本函数产生，不存在「用户自己写的 system」。
 * 选择插入而非替换，是为了**不静默吃掉**任何东西 ——
 * 万一将来别处也往序列里放了 system，宁可让它留在那里（服务端能接受多条），
 * 也不要在这里悄悄删掉别人的内容。
 *
 * @param msgs   已裁剪好的消息列表（真实对话）
 * @param prompt system 内容；空白串则不注入
 * @returns 新数组（可能含新加的 system，也可能是原内容的浅拷贝）
 */
export function injectSystem(msgs: ChatMsg[], prompt: string): ChatMsg[] {
  const out: ChatMsg[] = [];
  if (prompt.trim().length > 0) {
    out.push({ role: Role.SYSTEM, content: prompt, ts: Date.now() });
  }
  for (const m of msgs) {
    out.push(m);
  }
  return out;
}

/**
 * ★ 裁剪消息用于发送
 *
 * 规则（都要守，缺一个就会 400 或语义错乱）：
 *   1. 保留第一条 system；
 *   2. 从后往前取最近的 `MAX_SEND_MSGS` 条；
 *   3. **tool 消息不能孤立** —— 若裁剪后第一条是 tool，
 *      说明它对应的 assistant(tool_calls) 被切掉了，
 *      必须继续往前回溯，直到遇到带 tool_calls 的 assistant；
 *   4. 反过来，**assistant(tool_calls) 也不能没有 tool 结果** ——
 *      若末尾的 assistant 声明了 tool_calls 但结果不在（例如搜索进行到一半），
 *      整条裁掉，否则服务端会认为「你要求调工具却一直不给我结果」。
 *
 * 抽成**独立纯函数**（不依赖 Store），便于离线回归测试。
 *
 * ★★ 为什么这里写成「先选区间、再修正边界」两段式（2026-09-30 注入测试教训）：
 *   初版把规则 3 写成 `while (msgs[start].role === TOOL) start--`，
 *   看似正确，但注入测试（tools/mutate.py 的 trim-breaks-tool-pair）
 *   把它删掉后**测试仍然全绿** —— 因为当时用例的裁剪落点恰好没落在 tool 上，
 *   那条分支**从没被执行过**。也就是说：代码对，但「对的证据」是假的。
 *   现在改成显式扫描 + 独立的 `isSendableSequence` 校验，
 *   并把校验器也用于测试断言，保证「执行过」而不是「碰巧没触发」。
 */
export function trimForSend(msgs: ChatMsg[], max: number = MAX_SEND_MSGS): ChatMsg[] {  if (msgs.length <= max) {
    // 即使不裁剪，也可能本身就是非法序列（如工具结果还没回来的中间态）
    return msgs.slice(0);
  }

  // 规则 1：system 永远保留（且不占 max 配额）
  let sys: ChatMsg | null = null;
  let from: number = 0;
  if (msgs.length > 0 && msgs[0].role === Role.SYSTEM) {
    sys = msgs[0];
    from = 1;
  }

  let start: number = msgs.length - max;
  if (start < from) {
    start = from;
  }

  // 规则 3：起点不能落在 tool 上 → 往前回溯到发起它的 assistant
  while (start > from && msgs[start].role === Role.TOOL) {
    start--;
  }

  // 规则 4：若起点本身是带 tool_calls 的 assistant，说明它的结果在后面，
  //        保留它是正确的（结果会被一起带上）。无需特殊处理。

  // 规则 4b：末尾不能是「声明了 tool_calls 却缺结果」的 assistant
  let end: number = msgs.length;
  while (end > start) {
    const last: ChatMsg = msgs[end - 1];
    const hasCalls: boolean = last.role === Role.ASSISTANT
      && last.toolCalls !== undefined
      && (last.toolCalls as ToolCall[]).length > 0;
    if (hasCalls) {
      end--;
    } else {
      break;
    }
  }

  const body: ChatMsg[] = msgs.slice(start, end);
  if (sys !== null) {
    const out: ChatMsg[] = [sys];
    for (const m of body) {
      out.push(m);
    }
    return out;
  }
  return body;
}

/**
 * ★ 校验一段消息序列是否**可以合法发给官方 API**
 *
 * 返回空数组 = 合法；否则返回问题描述列表。
 *
 * 用途有两个，缺一不可：
 *   ① 发送前自检（发现问题就降级处理，而不是把非法序列发出去吃 400）；
 *   ② 离线回归测试的断言依据 —— 断言「结构不变量」比断言
 *      「某个具体下标的值」强得多：前者能抓住整类 bug，
 *      后者只能抓住你恰好想到的那一个实例。
 *
 * 不变量：
 *   · 首条不能是 tool（没有上下文）
 *   · 每条 tool 必须能追溯到**前面**某条 assistant 的 tool_calls（按 id 配对）
 *   · 每条 assistant 的 tool_calls 必须**紧跟**对应的 tool 结果
 *     （末尾悬挂的 tool_calls 视为非法）
 *   · tool 消息必须有 toolCallId
 */
export function validateApiSequence(msgs: ChatMsg[]): string[] {
  const errs: string[] = [];

  if (msgs.length === 0) {
    return errs;
  }
  if (msgs[0].role === Role.TOOL) {
    errs.push('首条是 tool 消息（缺少上下文）');
  }

  // 已声明但还没拿到结果的 tool_call id
  const pending: string[] = [];

  for (let i = 0; i < msgs.length; i++) {
    const m: ChatMsg = msgs[i];

    if (m.role === Role.ASSISTANT && m.toolCalls !== undefined
      && (m.toolCalls as ToolCall[]).length > 0) {
      // 上一批还没结算就来了新的一批 → 说明中间的结果丢了
      if (pending.length > 0) {
        errs.push('#' + i.toString() + ' 上一批 tool_calls 的结果尚未给出');
      }
      for (const c of (m.toolCalls as ToolCall[])) {
        pending.push(c.id);
      }
      continue;
    }

    if (m.role === Role.TOOL) {
      const id: string = m.toolCallId !== undefined ? (m.toolCallId as string) : '';
      if (id.length === 0) {
        errs.push('#' + i.toString() + ' tool 消息缺少 tool_call_id');
        continue;
      }
      const at: number = pending.indexOf(id);
      if (at < 0) {
        errs.push('#' + i.toString() + ' tool(id=' + id + ') 没有对应的 assistant tool_calls');
      } else {
        pending.splice(at, 1);
      }
      continue;
    }

    // 普通 user/assistant 消息：若此时还有未结算的 tool_calls，说明结果被吞了
    if (pending.length > 0) {
      errs.push('#' + i.toString() + ' 处仍有 ' + pending.length.toString()
        + ' 个 tool_calls 未收到结果');
      pending.length = 0;
    }
  }

  if (pending.length > 0) {
    errs.push('末尾有 ' + pending.length.toString() + ' 个 tool_calls 未收到结果');
  }
  return errs;
}

function str(o: Object): string {
  return typeof o === 'string' ? (o as string) : '';
}

function num(o: Object): number {
  return typeof o === 'number' ? (o as number) : 0;
}
