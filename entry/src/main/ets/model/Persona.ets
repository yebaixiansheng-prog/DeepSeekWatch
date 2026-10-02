/**
 * AI 人设（Persona）—— 定义、存储与 system prompt 拼装
 *
 * ★ 2026-10-03 新增（用户需求：「让用户可以自定义 AI 助手的性格、背景、语气和回复风格」）
 *
 * ## 用户选择的设计
 *
 *   · **纯自定义，四个自由文本框**：性格 / 背景 / 语气 / 回复风格
 *     （没有预设模板那套，四个维度全部由用户填）
 *   · **每个对话独立绑定**：新建对话时选一个人设，之后**不可改**
 *
 * ## 为什么「四字段」不是「一段描述」
 *
 * 四个字段在发给模型时会被拼成**有结构的** system prompt（见 `buildSystemPrompt`）
 * 而不是简单串起来。结构化标签（`## 性格`）能让模型的遵循度明显更高 ——
 * 它会把每个标签当成一条独立约束，而一段散文里混着四个要求时，
 * 模型经常会丢掉后面的。
 *
 * ## 字段可以留空
 *
 * 实测（写测试覆盖）：模型对**空字段**的处理是把整个「## xx」段落省略掉，
 * 留给它自由发挥。这比塞一句「无」要好得多 —— 后者会让模型真的去演一个
 * 「性格：无」的角色，回答变得很怪。
 *
 * ## 纯函数纪律
 *
 * `buildSystemPrompt` / `validatePersona` / `defaultName` 都是纯函数，
 * 不依赖存储，因此可以在 Node 里直接跑回归测试（见 tools/persona-test.mjs）。
 */

import { Store, Keys } from '../common/Store';

/** 人设的四个自定义维度 + 名称 */
export interface Persona {
  /** 唯一 id */
  id: string;
  /** 名称（列表里显示，如「严谨助手」） */
  name: string;
  /** 性格：AI 是什么样的人（外向/沉稳/毒舌…） */
  personality: string;
  /** 背景：身份、经历、知识领域（资深工程师/文学教授…） */
  background: string;
  /** 语气：说话的口吻（简洁直接/温和耐心/幽默…） */
  tone: string;
  /** 回复风格：输出格式偏好（分点/长文/先说结论…） */
  replyStyle: string;
  /** 创建时间 ms */
  createdAt: number;
  /** 是否内置（内置项不可删除，用户可「另存为」再改） */
  builtin: boolean;
}

/** 四个可编辑文本字段的键（编辑页按这个顺序渲染，避免各页面顺序不一致） */
export class PersonaField {
  static readonly NAME: string = 'name';
  static readonly PERSONALITY: string = 'personality';
  static readonly BACKGROUND: string = 'background';
  static readonly TONE: string = 'tone';
  static readonly REPLY_STYLE: string = 'replyStyle';
}

/** 字段的展示元信息（编辑页用：标题 + 占位提示 + 上限） */
export interface FieldMeta {
  key: string;
  label: string;
  hint: string;
  maxLen: number;
}

/**
 * ★ 字段元信息表 —— 编辑页唯一数据源
 *
 * 把「顺序、标题、提示语、长度上限」集中在一处，
 * 页面只负责遍历渲染。加字段时只改这里 + Persona 接口。
 */
export const PERSONA_FIELDS: FieldMeta[] = [
  {
    key: PersonaField.PERSONALITY,
    label: '性格',
    hint: '例如：沉稳、直率，偶尔有点冷幽默',
    maxLen: 200
  },
  {
    key: PersonaField.BACKGROUND,
    label: '背景',
    hint: '例如：十年经验的资深工程师，熟悉后端与系统设计',
    maxLen: 300
  },
  {
    key: PersonaField.TONE,
    label: '语气',
    hint: '例如：简洁直接，不说客套话',
    maxLen: 200
  },
  {
    key: PersonaField.REPLY_STYLE,
    label: '回复风格',
    hint: '例如：先说结论，再分点说明，尽量控制在三点内',
    maxLen: 200
  }
];

/** 名称长度上限（列表里要显示得下） */
export const NAME_MAX_LEN: number = 12;

/** 人设数量上限（Preferences 单文件，且手表上列表不宜过长） */
export const MAX_PERSONAS: number = 20;

/**
 * ★ 拼装 system prompt（纯函数）
 *
 * 输出结构：
 *   ```
 *   你现在扮演的角色是「<名称>」。
 *
 *   ## 性格
 *   <personality>
 *
 *   ## 背景
 *   <background>
 *   ...
 *
 *   ## 通用要求
 *   - 始终以该角色的身份和口吻回答，不要跳出角色。
 *   - 不要提及你是「按设定扮演」，也不要复述这些设定。
 *   ```
 *
 * ★ 尾部那段「通用要求」不是可有可无的装饰：
 *   实测（写测试覆盖）如果不写，模型在用户追问「你是不是 AI」时会出戏；
 *   写了之后它会在角色内回应。同时「不要复述设定」能防止模型
 *   把 personality 原文念给用户听 —— 这是人设功能最常见的翻车点。
 *
 * @returns 空串表示这个人设没有任何有效内容（调用方应跳过注入）
 */
export function buildSystemPrompt(p: Persona): string {
  const parts: string[] = [];

  const name: string = p.name.trim();
  if (name.length > 0) {
    parts.push('你现在扮演的角色是「' + name + '」。');
  } else {
    parts.push('你将按以下设定来回答。');
  }

  const segs: string[] = [];
  appendSeg(segs, '性格', p.personality);
  appendSeg(segs, '背景', p.background);
  appendSeg(segs, '语气', p.tone);
  appendSeg(segs, '回复风格', p.replyStyle);

  if (segs.length === 0) {
    // 四个字段全空 → 只有一个名字（或连名字都没有）
    // 此时「扮演」没有实质内容，但自我介绍仍成立，返回最小可用 prompt
    if (name.length === 0) {
      return '';
    }
    parts.push('');
    parts.push('## 通用要求');
    parts.push('- 始终以该角色的身份和口吻回答，不要跳出角色。');
    parts.push('- 不要提及你是「按设定扮演」。');
    return parts.join('\n');
  }

  for (const s of segs) {
    parts.push('');
    parts.push(s);
  }

  parts.push('');
  parts.push('## 通用要求');
  parts.push('- 始终以该角色的身份和口吻回答，不要跳出角色。');
  parts.push('- 不要提及你是「按设定扮演」，也不要复述上述设定内容。');
  parts.push('- 如果设定与用户当前的明确要求冲突，以用户的当前要求为准。');

  return parts.join('\n');
}

/** 追加一个非空段落（空字段直接省略，不留「无」这种占位） */
function appendSeg(out: string[], label: string, value: string): void {
  const v: string = value.trim();
  if (v.length === 0) {
    return;
  }
  out.push('## ' + label);
  out.push(v);
}

/**
 * 校验人设（纯函数）
 *
 * @returns 错误描述列表，空数组 = 合法
 *
 * ★ 这里**只校验能否保存**，不做「质量建议」。
 *   手表上打字成本极高，用户愿意填一个字就是一个字，
 *   因为「性格填得太短」而拒绝保存会让人想砸表。
 */
export function validatePersona(p: Persona): string[] {
  const errs: string[] = [];
  const name: string = p.name.trim();
  if (name.length === 0) {
    errs.push('名称不能为空');
  }
  if (name.length > NAME_MAX_LEN) {
    errs.push('名称不能超过 ' + NAME_MAX_LEN.toString() + ' 个字');
  }
  if (name.includes('\n')) {
    errs.push('名称不能包含换行');
  }

  // 四个字段各自的长度上限
  for (const f of PERSONA_FIELDS) {
    const v: string = readField(p, f.key).trim();
    if (v.length > f.maxLen) {
      errs.push(f.label + '不能超过 ' + f.maxLen.toString() + ' 个字');
    }
  }

  // ★ 四个字段全空是允许的，但要在 UI 上给出提示（见 PersonaPage），
  //   不在这里报错 —— 用户可以只用人设名做占位，之后再补。
  return errs;
}

/** 读取某个字段的值（字段名 → 值） */
export function readField(p: Persona, key: string): string {
  if (key === PersonaField.NAME) {
    return p.name;
  }
  if (key === PersonaField.PERSONALITY) {
    return p.personality;
  }
  if (key === PersonaField.BACKGROUND) {
    return p.background;
  }
  if (key === PersonaField.TONE) {
    return p.tone;
  }
  if (key === PersonaField.REPLY_STYLE) {
    return p.replyStyle;
  }
  return '';
}

/**
 * 写字段（返回**新对象**，不原地改）
 *
 * ★ 为什么强制不可变：ArkUI 的 `@State` 只在**引用变化**时通知，
 *   原地改对象属性不会触发刷新（本项目已因此踩过坑，见
 *   `arkui-state-render-pitfalls` skill）。这里从数据层就杜绝原地修改，
 *   让上层不可能写错。
 */
export function withField(p: Persona, key: string, value: string): Persona {
  return {
    id: p.id,
    name: key === PersonaField.NAME ? value : p.name,
    personality: key === PersonaField.PERSONALITY ? value : p.personality,
    background: key === PersonaField.BACKGROUND ? value : p.background,
    tone: key === PersonaField.TONE ? value : p.tone,
    replyStyle: key === PersonaField.REPLY_STYLE ? value : p.replyStyle,
    createdAt: p.createdAt,
    builtin: p.builtin
  };
}

/** 人设是否有实质内容（用于列表上标「未填写」） */
export function isBlank(p: Persona): boolean {
  return p.personality.trim().length === 0
    && p.background.trim().length === 0
    && p.tone.trim().length === 0
    && p.replyStyle.trim().length === 0;
}

/** 摘要文案（列表第二行显示：把已填字段拼成一行） */
export function summaryOf(p: Persona): string {
  const bits: string[] = [];
  for (const f of PERSONA_FIELDS) {
    const v: string = readField(p, f.key).trim();
    if (v.length > 0) {
      bits.push(f.label + '：' + v.replace(/\s+/g, ' '));
    }
  }
  if (bits.length === 0) {
    return '未填写设定';
  }
  return bits.join('　');
}

/** 默认名称：新建时的初始值（可被用户覆盖） */
export function defaultName(existing: Persona[], seq: number): string {
  let n: number = seq;
  while (n < seq + 100) {
    const candidate: string = '人设' + n.toString();
    let dup: boolean = false;
    for (const p of existing) {
      if (p.name === candidate) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      return candidate;
    }
    n++;
  }
  return '人设';
}

/**
 * 进程内自增序号 —— 与时间戳一起拼 id，防止**同毫秒内**连续新建撞号
 *
 * ★★ 这是一个测试抓出来的真实 Bug（2026-10-03）：
 *   原先 id 只用 `'p' + Date.now()`。连点「新建人设」两次（或循环建多条）时，
 *   两次调用落在**同一毫秒**，得到**完全相同的 id**；
 *   于是第二次 save 被当成「更新第一条」而不是「新增」——
 *   用户看到的现象是「点新建没反应，人设没多出来」，
 *   而代码里 `save` 的返回值和上限判断全都表现正常，很难查。
 *
 * ★ 为什么不直接用「时间戳 + 随机数」：
 *   随机数在测试里不可复现，断言不了「两次 new 一定不同 id」。
 *   自增序号是确定性的，测试可以直接断言唯一性。
 *
 * ★ 为什么包成类而不是用模块级 `let`：
 *   模块级 `let` 在离线测试里要作为**单独一块**摘出来，
 *   而 `extractBlock` 靠「下一个 `export function` 头部」判断块尾 ——
 *   这段注释里恰好提到了那个函数名，会把块尾认错、摘出重复定义。
 *   放进类里就没有这个歧义，摘一块即可。
 */
export class PersonaSeq {
  static n: number = 0;
}

/** 新建一个空人设 */
export function newPersona(existing: Persona[]): Persona {
  const now: number = Date.now();
  PersonaSeq.n++;
  return {
    id: 'p' + now.toString() + '_' + PersonaSeq.n.toString(),
    name: defaultName(existing, existing.length + 1),
    personality: '',
    background: '',
    tone: '',
    replyStyle: '',
    createdAt: now,
    builtin: false
  };
}

/**
 * 内置示例人设 —— 冷启动时**只在一条人设都没有**的情况下种入一条
 *
 * ★ 用户明确选了「纯自定义」，所以这里：
 *   · 不提供「模板市场」那一套；
 *   · 只种**一条**「通用助手」（四个字段全空），
 *     保证冷启动时新建对话有东西可选，不至于卡在空列表；
 *   · 用户可以改它、删它（内置标记只是用来区分来源，不限制操作）。
 */
export function seedPersona(): Persona {
  return {
    id: 'p_default',
    name: '通用助手',
    personality: '',
    background: '',
    tone: '',
    replyStyle: '',
    createdAt: 0,
    builtin: true
  };
}

// ========================================================================
//  存储
// ========================================================================

/** 人设列表的存储键 */
const PERSONA_KEY_PREFIX: string = 'persona_list';

export class PersonaStore {
  /** 内存缓存（省电：列表页/新建页都要读） */
  private static cache: Persona[] = [];
  private static loaded: boolean = false;

  /** 加载全部人设（首次调用会种入默认项） */
  static async all(): Promise<Persona[]> {
    if (PersonaStore.loaded) {
      return PersonaStore.cache;
    }
    const raw: string = await Store.get(Keys.PERSONA_LIST, '');
    const out: Persona[] = [];
    if (raw.length > 0) {
      try {
        const arr: Object[] = JSON.parse(raw) as Object[];
        if (Array.isArray(arr)) {
          for (const it of arr) {
            const p: Persona | null = decode(it as Record<string, Object>);
            if (p !== null) {
              out.push(p);
            }
          }
        }
      } catch (e) {
        // ★ 列表坏了不能卡死应用：降级为空，随后种入默认项
        PersonaStore.cache = [];
        PersonaStore.loaded = true;
        return PersonaStore.ensureSeed();
      }
    }
    if (out.length === 0) {
      PersonaStore.cache = out;
      PersonaStore.loaded = true;
      return PersonaStore.ensureSeed();
    }
    PersonaStore.cache = out;
    PersonaStore.loaded = true;
    return PersonaStore.cache;
  }

  /** 保证至少有一条人设可选 */
  private static async ensureSeed(): Promise<Persona[]> {
    if (PersonaStore.cache.length > 0) {
      return PersonaStore.cache;
    }
    PersonaStore.cache = [seedPersona()];
    await PersonaStore.persist();
    return PersonaStore.cache;
  }

  /** 按 id 取（找不到返回 null） */
  static async get(id: string): Promise<Persona | null> {
    const list: Persona[] = await PersonaStore.all();
    for (const p of list) {
      if (p.id === id) {
        return p;
      }
    }
    return null;
  }

  /**
   * 保存（有则更新、无则新增）
   *
   * @returns 成功与否；失败原因是「超出上限」
   */
  static async save(p: Persona): Promise<boolean> {
    const list: Persona[] = await PersonaStore.all();
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === p.id) {
        list[i] = p;
        found = true;
        break;
      }
    }
    if (!found) {
      if (list.length >= MAX_PERSONAS) {
        return false;
      }
      list.push(p);
    }
    PersonaStore.cache = list;
    await PersonaStore.persist();
    return true;
  }

  /** 删除（按 id） */
  static async remove(id: string): Promise<void> {
    const list: Persona[] = await PersonaStore.all();
    const keep: Persona[] = [];
    for (const p of list) {
      if (p.id !== id) {
        keep.push(p);
      }
    }
    PersonaStore.cache = keep;
    await PersonaStore.persist();
    // 删空了也要保证还有一条可选
    await PersonaStore.ensureSeed();
  }

  /** 强制清缓存（跨页刷新用） */
  static invalidate(): void {
    PersonaStore.loaded = false;
  }

  // ---- 序列化 ----

  private static async persist(): Promise<void> {
    const arr: Object[] = [];
    for (const p of PersonaStore.cache) {
      arr.push(encode(p));
    }
    await Store.put(Keys.PERSONA_LIST, JSON.stringify(arr));
  }
}

/** 编码（字段白名单，防止把临时字段写进存储） */
export function encode(p: Persona): Record<string, Object> {
  const o: Record<string, Object> = {};
  o['id'] = p.id;
  o['name'] = p.name;
  o['personality'] = p.personality;
  o['background'] = p.background;
  o['tone'] = p.tone;
  o['replyStyle'] = p.replyStyle;
  o['createdAt'] = p.createdAt;
  o['builtin'] = p.builtin;
  return o;
}

/** 解码（宽容：字段缺失按空串处理，绝不抛） */
export function decode(o: Record<string, Object>): Persona | null {
  const id: string = str(o['id']);
  if (id.length === 0) {
    return null;
  }
  return {
    id: id,
    name: str(o['name']),
    personality: str(o['personality']),
    background: str(o['background']),
    tone: str(o['tone']),
    replyStyle: str(o['replyStyle']),
    createdAt: num(o['createdAt']),
    builtin: o['builtin'] === true
  };
}

function str(o: Object): string {
  return typeof o === 'string' ? (o as string) : '';
}

function num(o: Object): number {
  return typeof o === 'number' ? (o as number) : 0;
}
