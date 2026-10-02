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

/** 会话元信息 */
export interface Session {
  id: string;
  title: string;
  /** 创建时间 ms */
  createdAt: number;
  /** 最近更新时间 ms */
  updatedAt: number;
  messages: ChatMsg[];
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
              count: num(o['count'])
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

  private static async saveIndex(): Promise<void> {
    await Store.put(Keys.SESSION_INDEX, JSON.stringify(ChatStore.cache));
  }

  /** 新建会话，返回会话对象 */
  static async create(): Promise<Session> {
    const id: string = 's' + Date.now().toString();
    const now: number = Date.now();
    const s: Session = {
      id: id,
      title: '新对话',
      createdAt: now,
      updatedAt: now,
      messages: []
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
        messages: msgs
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
        count: s.messages.length
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
export function trimForSend(msgs: ChatMsg[], max: number = MAX_SEND_MSGS): ChatMsg[] {
  if (msgs.length <= max) {
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
