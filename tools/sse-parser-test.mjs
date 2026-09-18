/**
 * 回归测试：把 ArkTS 版 SseClient 的 patch 解析逻辑（片段类型追踪 + SET/APPEND 语义）
 * 1:1 移植到 JS，喂入几种真实的 SSE 帧序列，断言正文分派结果正确。
 *
 * 覆盖 10 种形态：
 *   A. 首帧全量 + response/fragments/<idx>/content 增量（当前线上主形态）
 *   B. thinking/content + response/content 前缀形态（老版本）
 *   C. 只有 fragments 数组帧 + fragments/-1/content（无首帧）
 *   D. 服务端错误帧（40301）
 *   E. 非正文路径（token 统计）不得打断正文
 *   F. 工具片段与不可展示片段（REQUEST/FILE/TIP 过滤）
 *   G. 首帧就带完整 content（SET 语义）→ 输出全文，且后续 APPEND 不重复
 *   H. fragments 数组 APPEND 帧自带首段 content → 与后续增量正确拼接
 *   I. 从首帧 response 对象提取 message_id（Bug 16 的修复依赖它）
 *   J. 零帧挂死判定条件（Bug 17 看门狗的判据）
 *
 * 运行：node tools/sse-parser-test.mjs
 */

// ---------------- 常量（与 Constants.ets 对齐） ----------------
const FragmentType = {
  THINK: 'THINK',
  RESPONSE: 'RESPONSE',
  TEMPLATE_RESPONSE: 'TEMPLATE_RESPONSE',
  SEARCH: 'SEARCH',
  TOOL_SEARCH: 'TOOL_SEARCH',
  TOOL_OPEN: 'TOOL_OPEN',
  TOOL_FIND: 'TOOL_FIND'
};

// ---------------- 被测逻辑（从 SseClient.ets 移植） ----------------
class MiniSse {
  /** 与 SseClient.lastMessageId 对应的静态去重状态 */
  static lastMessageId = '';
  /** 本次测试收集到的 message_id 上报序列 */
  static messageIds = [];

  constructor() {
    this.lastPath = '';
    this.lastOp = '';
    this.fragTypes = [];
    this.fragFull = [];
    this.lastFragType = '';
    this.events = [];
    this.errors = [];
    this.seenPaths = '';
  }

  static pickStr(o, key) {
    const v = o[key];
    if (v === undefined || v === null) return '';
    if (typeof v === 'string') return v;
    if (typeof v === 'number') return v.toString();
    return '';
  }

  static isFragmentsStructPath(p) {
    if (p.endsWith('/content')) return false;
    return p === 'fragments' || p.endsWith('/fragments') || p.indexOf('/fragments/') >= 0;
  }

  static resolveIndex(path, last) {
    const segs = path.split('/');
    for (let i = 0; i < segs.length; i++) {
      if (segs[i] === 'fragments' && i + 1 < segs.length) {
        const n = parseInt(segs[i + 1]);
        if (isNaN(n)) return -1;
        return n < 0 ? last - 1 : n;
      }
    }
    return -1;
  }

  static normalizeType(t) {
    if (t === FragmentType.THINK || t === FragmentType.SEARCH) return FragmentType.THINK;
    if (t === FragmentType.TOOL_SEARCH || t === FragmentType.TOOL_OPEN || t === FragmentType.TOOL_FIND) return FragmentType.TOOL_SEARCH;
    if (t === 'REQUEST' || t === 'FILE' || t === 'TIP') return '';
    return FragmentType.RESPONSE;
  }

  typeAt(idx) {
    if (idx >= 0 && idx < this.fragTypes.length) {
      const t = this.fragTypes[idx];
      if (t.length > 0) return t;
    }
    return this.lastFragType;
  }

  typeFromPathHead(path) {
    const slash = path.indexOf('/');
    const head = slash > 0 ? path.substring(0, slash) : path;
    if (head === 'thinking') return FragmentType.THINK;
    if (head === 'search') return FragmentType.TOOL_SEARCH;
    if (head === 'response') return FragmentType.RESPONSE;
    return FragmentType.RESPONSE;
  }

  notePath(path) {
    if (path.length > 0 && this.seenPaths.indexOf(path) < 0) {
      this.seenPaths = this.seenPaths.length === 0 ? path : this.seenPaths + ',' + path;
    }
  }

  pushDelta(t, text) {
    if (text.length === 0) return;
    this.events.push({ type: t, text });
  }

  emitStructContent(idx, content) {
    if (content.length === 0) return;
    const t = MiniSse.normalizeType(this.typeAt(idx));
    if (t.length === 0) return;
    this.pushDelta(t, content);
  }

  absorbFragmentArray(arr, op) {
    if (op === 'SET') {
      this.fragTypes = [];
      this.fragFull = [];
    }
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      let t = '';
      let content = '';
      if (item !== null && item !== undefined && typeof item === 'object') {
        t = MiniSse.pickStr(item, 'type');
        content = MiniSse.pickStr(item, 'content');
      }
      if (t.length > 0) this.lastFragType = t;
      const idx = this.fragTypes.length;
      this.fragTypes.push(t);
      this.fragFull.push(op !== 'APPEND' && content.length > 0);
      if (content.length > 0) this.emitStructContent(idx, content);
    }
  }

  absorbStructValue(v, op) {
    if (typeof v !== 'object' || v === null) return;
    // ★ 新增：从 response 对象里捞 message_id（Bug 16 的修复依赖它）
    MiniSse.pickMessageId(v);
    const direct = v['fragments'];
    if (direct !== undefined && direct !== null && Array.isArray(direct)) {
      this.absorbFragmentArray(direct, op);
      return;
    }
    for (const k of ['response', 'thinking', 'search']) {
      const inner = v[k];
      if (inner === undefined || inner === null || typeof inner !== 'object') continue;
      MiniSse.pickMessageId(inner);
      const fs = inner['fragments'];
      if (fs !== undefined && fs !== null && Array.isArray(fs)) {
        this.absorbFragmentArray(fs, op);
        return;
      }
    }
  }

  /**
   * 移植自 SseClient.pickMessageId
   *
   * 服务端首帧的 response 对象里带 message_id，这是后续
   * `stop_stream` 唯一能用的凭据（下一轮发送前用它清僵尸流）。
   * 兼容 message_id / messageId / id 三种命名。
   */
  static pickMessageId(o) {
    if (!o || typeof o !== 'object') return;
    let mid = MiniSse.pickStr(o, 'message_id');
    if (mid.length === 0) mid = MiniSse.pickStr(o, 'messageId');
    if (mid.length === 0) mid = MiniSse.pickStr(o, 'id');
    if (mid.length === 0) return;
    if (mid === MiniSse.lastMessageId) return;
    MiniSse.lastMessageId = mid;
    MiniSse.messageIds.push(mid);
  }

  absorbStructValueAtPath(path, op, v) {
    if (Array.isArray(v)) {
      this.absorbFragmentArray(v, op);
      return;
    }
    if (typeof v !== 'object' || v === null) return;
    const idx = MiniSse.resolveIndex(path, this.fragTypes.length);
    const t = MiniSse.pickStr(v, 'type');
    const content = MiniSse.pickStr(v, 'content');
    if (t.length > 0) this.lastFragType = t;
    if (idx >= 0) {
      while (this.fragTypes.length <= idx) {
        this.fragTypes.push('');
        this.fragFull.push(false);
      }
      this.fragTypes[idx] = t;
      this.fragFull[idx] = (op !== 'APPEND') && content.length > 0;
    }
    if (content.length > 0) this.emitStructContent(idx, content);
  }

  emitContent(path, text, isAppend) {
    if (path.length === 0 || text.length === 0) return;
    if (!path.endsWith('/content')) return;
    const idx = MiniSse.resolveIndex(path, this.fragTypes.length);
    let t = '';
    if (idx >= 0) {
      if (this.fragFull[idx] === true) return;
      if (!isAppend) this.fragFull[idx] = true;
      t = MiniSse.normalizeType(this.typeAt(idx));
    } else {
      t = this.typeFromPathHead(path);
    }
    if (t.length === 0) return;
    this.notePath(path);
    this.pushDelta(t, text);
  }

  handlePatch(obj) {
    const codeObj = obj['code'];
    if (codeObj !== undefined && codeObj !== null) {
      this.errors.push('srv_' + MiniSse.pickStr(obj, 'code'));
      return;
    }
    const p = MiniSse.pickStr(obj, 'p');
    const op = MiniSse.pickStr(obj, 'o');
    const v = obj['v'];

    if (p.length === 0) {
      if (v !== undefined && v !== null && typeof v !== 'string') {
        this.absorbStructValue(v, 'SET');
        return;
      }
      if (v === undefined || v === null || typeof v !== 'string') return;
      this.emitContent(this.lastPath, v, this.lastOp === 'APPEND');
      return;
    }

    if (MiniSse.isFragmentsStructPath(p)) {
      if (v !== undefined && v !== null && typeof v !== 'string') {
        this.absorbStructValueAtPath(p, op, v);
      }
      return;
    }

    if (!p.endsWith('/content')) return;
    this.lastPath = p;
    this.lastOp = op;
    if (v === undefined || v === null || typeof v !== 'string') return;
    this.emitContent(p, v, op === 'APPEND');
  }

  /** 按 SSE 规范切帧并逐帧处理 */
  feed(raw) {
    const buf = raw.replace(/\r\n/g, '\n');
    for (const frame of buf.split('\n\n')) {
      let dataStr = '';
      for (const line of frame.split('\n')) {
        if (line.startsWith('data:')) dataStr += line.substring(5).trim();
      }
      if (dataStr.length === 0) continue;
      let obj = null;
      try {
        obj = JSON.parse(dataStr);
      } catch (e) {
        continue;
      }
      if (obj === null) continue;
      this.handlePatch(obj);
    }
  }

  /** 把事件按类型拼成「最终文本」，便于断言 */
  joined() {
    const m = {};
    for (const e of this.events) m[e.type] = (m[e.type] || '') + e.text;
    return m;
  }
}

// ---------------- 断言 ----------------
let pass = 0;
let fail = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a === b) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}\n      期望: ${b}\n      实际: ${a}`);
  }
}

// ---------------- 用例 A ----------------
console.log('用例 A：首帧全量 + response/fragments/<idx>/content');
{
  const s = new MiniSse();
  s.feed(
    'event: ready\n' +
    'data: {"request_message_id":1,"response_message_id":2,"model_type":"default"}\n\n' +
    'event: update_session\n' +
    'data: {"updated_at":1789207417.827801}\n\n' +
    'data: {"p":"","o":"SET","v":{"response":{"message_id":2,"role":"ASSISTANT","status":"WIP","fragments":[{"id":1,"type":"THINK","content":"","status":"WIP"},{"id":2,"type":"RESPONSE","content":"","status":"WIP"}]}}}\n\n' +
    'data: {"p":"response/fragments/0/content","o":"APPEND","v":"用户"}\n\n' +
    'data: {"v":"想要"}\n\n' +
    'data: {"p":"response/fragments/1/content","o":"APPEND","v":"你好"}\n\n' +
    'data: {"v":"！"}\n\n' +
    'event: finish\n' +
    'data: {}\n\n'
  );
  check('片段类型分派', s.joined(), { THINK: '用户想要', RESPONSE: '你好！' });
  check('无错误', s.errors, []);
}

// ---------------- 用例 B ----------------
console.log('用例 B：thinking/content + response/content 前缀形态');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"thinking/content","o":"APPEND","v":"先想"}\n\n' +
    'data: {"p":"thinking/content","o":"APPEND","v":"一下"}\n\n' +
    'data: {"p":"response/content","o":"APPEND","v":"答案是"}\n\n' +
    'data: {"p":"response/content","o":"APPEND","v":"42"}\n\n'
  );
  check('前缀映射', s.joined(), { THINK: '先想一下', RESPONSE: '答案是42' });
}

// ---------------- 用例 C ----------------
console.log('用例 C：fragments 数组帧 + fragments/-1/content');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"response/fragments","o":"APPEND","v":[{"id":11,"type":"THINK","content":"","status":"WIP"}]}\n\n' +
    'data: {"p":"response/fragments/-1/content","o":"APPEND","v":"思考"}\n\n' +
    'data: {"p":"response/fragments","o":"APPEND","v":[{"id":12,"type":"RESPONSE","content":"","status":"WIP"}]}\n\n' +
    'data: {"p":"response/fragments/-1/content","o":"APPEND","v":"回答"}\n\n' +
    'data: {"p":"response/fragments/1/content","o":"APPEND","v":"。"}\n\n'
  );
  check('-1 与绝对索引都正确', s.joined(), { THINK: '思考', RESPONSE: '回答。' });
}

// ---------------- 用例 D ----------------
console.log('用例 D：服务端错误帧');
{
  const s = new MiniSse();
  s.feed('data: {"code":40301,"msg":"INVALID_POW_RESPONSE"}\n\n');
  check('上报 srv_40301', s.errors, ['srv_40301']);
}

// ---------------- 用例 E ----------------
console.log('用例 E：非正文路径（token 统计）不得打断正文');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"response/fragments/0/content","o":"APPEND","v":"前"}\n\n' +
    'data: {"p":"response/accumulated_token_usage","o":"SET","v":123}\n\n' +
    'data: {"v":"后"}\n\n'
  );
  check('统计帧不影响延续帧', s.joined(), { RESPONSE: '前后' });
}

// ---------------- 用例 F ----------------
console.log('用例 F：工具片段与不可展示片段');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"","o":"SET","v":{"response":{"fragments":[{"id":1,"type":"REQUEST","content":"原始提问"},{"id":2,"type":"TOOL_SEARCH","content":""},{"id":3,"type":"RESPONSE","content":""}]}}}\n\n' +
    'data: {"p":"response/fragments/1/content","o":"APPEND","v":"搜索词"}\n\n' +
    'data: {"p":"response/fragments/2/content","o":"APPEND","v":"正文"}\n\n' +
    'data: {"p":"response/fragments/0/content","o":"APPEND","v":"不该出现"}\n\n'
  );
  check('REQUEST 被过滤，TOOL_SEARCH 归类', s.joined(), { TOOL_SEARCH: '搜索词', RESPONSE: '正文' });
}

// ---------------- 用例 G：SET 语义（首帧带全文） ----------------
console.log('用例 G：首帧就带完整 content（SET），后续 APPEND 不得重复');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"","o":"SET","v":{"response":{"fragments":[{"id":1,"type":"RESPONSE","content":"完整答案"}]}}}\n\n' +
    'data: {"p":"response/fragments/0/content","o":"APPEND","v":"完整答案"}\n\n'
  );
  check('只输出一次', s.joined(), { RESPONSE: '完整答案' });
}

// ---------------- 用例 H：APPEND 帧自带首段 content ----------------
console.log('用例 H：fragments 数组 APPEND 帧自带首段 content，需与后续增量拼接');
{
  const s = new MiniSse();
  s.feed(
    'data: {"p":"response/fragments","o":"APPEND","v":[{"id":1,"type":"RESPONSE","content":"开头"}]}\n\n' +
    'data: {"p":"response/fragments/-1/content","o":"APPEND","v":"结尾"}\n\n'
  );
  check('拼接为开头+结尾', s.joined(), { RESPONSE: '开头结尾' });
}

// ---------------- 用例 I：message_id 提取（Bug 16 依赖） ----------------
console.log('用例 I：从首帧 response 对象提取 message_id');
{
  MiniSse.lastMessageId = '';
  MiniSse.messageIds = [];
  const s = new MiniSse();
  s.feed(
    'data: {"p":"","o":"SET","v":{"response":{"message_id":"srv-abc-123",' +
    '"fragments":[{"id":1,"type":"RESPONSE","content":"hi"}]}}}\n\n'
  );
  check('提取到 message_id', MiniSse.messageIds, ['srv-abc-123']);
}
{
  // 同一 id 反复出现只上报一次（避免每帧都触发回调）
  MiniSse.lastMessageId = '';
  MiniSse.messageIds = [];
  const s = new MiniSse();
  s.feed(
    'data: {"p":"","o":"SET","v":{"response":{"message_id":"same-id","fragments":[]}}}\n\n' +
    'data: {"p":"","o":"SET","v":{"response":{"message_id":"same-id","fragments":[]}}}\n\n'
  );
  check('同一 message_id 只上报一次', MiniSse.messageIds, ['same-id']);
}
{
  // 兼容 camelCase 命名
  MiniSse.lastMessageId = '';
  MiniSse.messageIds = [];
  const s = new MiniSse();
  s.feed('data: {"p":"","o":"SET","v":{"response":{"messageId":"camel-1","fragments":[]}}}\n\n');
  check('兼容 messageId 命名', MiniSse.messageIds, ['camel-1']);
}
{
  // 裸 id 命名（部分版本）
  MiniSse.lastMessageId = '';
  MiniSse.messageIds = [];
  const s = new MiniSse();
  s.feed('data: {"p":"","o":"SET","v":{"response":{"id":"bare-1","fragments":[]}}}\n\n');
  check('兼容裸 id 命名', MiniSse.messageIds, ['bare-1']);
}

// ---------------- 用例 J：零帧挂死判定（Bug 17 的判定条件） ----------------
console.log('用例 J：零帧挂死判定条件');
{
  // 复刻 SseClient 看门狗的判定：45s 内 frameCount===0 → 判 stalled
  const STALL_MS = 45000;
  const judge = (idleMs, frameCount) =>
    ((idleMs >= STALL_MS && frameCount === 0) ? 'stalled' : 'wait');
  check('45s 零帧 → stalled', judge(45001, 0), 'stalled');
  check('45s 已有数据 → 只等待（长思考静默期不打断）', judge(45001, 12), 'wait');
  check('30s 零帧 → 还不到阈值', judge(30000, 0), 'wait');
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
