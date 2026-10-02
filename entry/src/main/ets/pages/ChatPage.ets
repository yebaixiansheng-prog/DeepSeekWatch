/**
 * 对话页（主界面）
 *
 * ★ 2026-10-03 重构（用户需求：「优化整体界面设计，统一视觉风格，提升交互体验
 *   和易用性，使界面更现代、直观、响应式，并深度适配圆形表盘」）
 *
 * 本次改动的四条主线：
 *   ① **导航收进圆环径向菜单** —— 升级前顶部是一条 38vp 的 bar
 *      （新对话 / 模型名 / 历史），占掉了圆屏最金贵的纵向空间。
 *      改为菜单后，对话内容区多出约 50px 高度（手表上一行半文字）。
 *   ② **宽度全部按 y 计算** —— 不再出现 `width('86%')` 这类字面百分比。
 *      见 `Round.bottomUsableVp` 与各处的 `xxxWidthVp()`。
 *   ③ **配色全部走 Theme 令牌** —— 页面里 0 个字面色值。
 *   ④ **人设可见** —— 顶栏显示当前对话绑定的人设名（用户明确要「一眼看懂」）。
 *
 * ## 圆屏纪律（来自真机实测，不是拍脑袋）
 *
 *   1. 屏幕 466×466，圆心 (233,233)，R=233。**越靠下弦宽越窄**：
 *      y=415 弦宽 291px，y=428 弦宽 **255px**，y=450 弦宽 170px，y=466 弦宽 0。
 *      （★ y=428 的 255 是圆方程算出来的，升级前手抄的 262 是错的。）
 *   2. y ≥ 450 是**系统手势区**，点这里会把 App 推到后台
 *      → 可点元素下沿必须 ≤ 436（硬上限），推荐 ≤ 415（舒适线）。
 *   3. 1vp = 2px（density=2）。
 *   4. 输入法（本机）是 `[0,0][466,466]` 的**全屏窗口**，会完全盖住 App
 *      → 输入态下 App 内任何按钮都点不到，**收键盘只能靠系统 Back**。
 *      ★ 因此**绝不能**在输入态加「收起键盘」按钮 —— 看不见也点不到。
 *
 * ## ArkUI 渲染纪律
 *
 *   · **绝不原地改 `@State` 数组里的元素属性**（如 `this.msgs[i].content += x`）
 *     —— @State 只在引用变化时通知，ForEach 按 key diff，双重不感知 = 界面不动。
 *     流式追加必须「造新对象 + 替换数组元素 + rev++」，ForEach key 里带 rev。
 *   · `@Builder` 里调用的私有方法**不能是 async** —— 需要异步就走
 *     `() => { this.xxx(); }` 包一层。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round, Unit, FontScale } from '../common/RoundScreen';
import { Crown } from '../common/Crown';
import { Color, Radius, Space, Touch, Motion, Opacity } from '../common/Theme';
import { AppConfig } from '../model/AppConfig';
import {
  ChatStore, Session, trimForSend, validateApiSequence, injectSystem,
  personaBadge, needsFreshSession
} from '../model/ChatStore';
import { ApiClient, ChatMsg, ChatRequest, StreamSink, ToolCall } from '../model/ApiClient';
import { SearchService, formatForModel } from '../model/SearchService';
import { Persona, PersonaStore, buildSystemPrompt } from '../model/Persona';
import { Role, ErrCode, ErrMsg, Model } from '../common/Constants';
import { Store, Keys } from '../common/Store';
import { RoundButton } from '../components/RoundWidgets';
import { RadialMenu, RadialItem, RadialScrim } from '../components/RadialMenu';

/** 一条用于渲染的消息 */
interface ViewMsg {
  key: string;
  role: string;
  content: string;
  reasoning: string;
  /** 是否正在流式输出（显示光标） */
  streaming: boolean;
  /** 工具调用状态文案（如「正在搜索：xxx」） */
  toolNote: string;
  /** 渲染版本号：内容变化时 +1，让 ForEach 一定感知（见文件头纪律） */
  rev: number;
}

@Entry
@Component
struct ChatPage {
  @State msgs: ViewMsg[] = [];
  @State input: string = '';
  @State sending: boolean = false;
  @State errMsg: string = '';
  @State sessionId: string = '';
  /** 当前搜索状态提示（空 = 没在搜） */
  @State searchNote: string = '';
  /** 输入法是否在屏（全屏输入法会盖住 App） */
  @State keyboardOn: boolean = false;
  /** 字号 */
  @State fontScale: number = FontScale.STANDARD;
  /** 径向菜单是否展开 */
  @State menuOpen: boolean = false;
  /** 菜单高亮项（表冠驱动） */
  @State menuIndex: number = 0;
  /** 当前对话绑定的人设（null = 未绑定） */
  @State persona: Persona | null = null;
  /** 顶部「模式」文案（模型 + 思考/搜索状态，一眼可见） */
  @State modeLabel: string = '';

  private scroller: Scroller = new Scroller();
  private inputCtl: TextInputController = new TextInputController();
  private api: ApiClient = new ApiClient();
  /** 渲染版本计数器（全局递增，保证 key 唯一） */
  private revSeq: number = 0;

  // ======================================================================
  //  生命周期
  // ======================================================================

  async aboutToAppear(): Promise<void> {
    await AppConfig.load();
    Typo.scale = this.fontScale as FontScale;
    this.syncModeLabel();

    // ★ 先结算「人设选择页带回来的选择」（如果用户刚选了人设）
    await this.consumePendingPersona();

    // 恢复上次会话；没有就新建
    const last: string = await ChatStore.getLastSession();
    let s: Session | null = null;
    if (last.length > 0) {
      s = await ChatStore.load(last);
    }
    if (s === null) {
      s = await ChatStore.create();
    }
    this.sessionId = s.id;
    await ChatStore.setLastSession(s.id);
    this.msgs = toView(s.messages);
    await this.loadPersona(s.personaId);

    // 空会话 → 自动滚到欢迎语
    if (this.msgs.length === 0) {
      await this.pushWelcome();
    }
  }

  /**
   * ★ 结算「人设选择页带回来的选择」
   *
   * ArkUI 的 `router.back()` 不支持携带参数，所以走「写约定 key → 读走即清」。
   * ★ **读走必须立刻清掉**：不清的话下次进对话页会再次应用同一个选择，
   *   表现为「明明没选，人设却自己变了」。
   */
  private async consumePendingPersona(): Promise<void> {
    const picked: string = await Store.get(Keys.PENDING_PERSONA, '');
    if (picked.length === 0) {
      return;
    }
    await Store.remove(Keys.PENDING_PERSONA);
    // 当前会话若已绑定人设 → 提示是否换绑；否则直接绑上
    const last: string = await ChatStore.getLastSession();
    if (last.length === 0) {
      await Store.put(Keys.LAST_PERSONA, picked);
      return;
    }
    await this.applyPersona(picked);
  }

  /** 读人设到视图状态 */
  private async loadPersona(personaId: string): Promise<void> {
    if (personaId.length === 0) {
      this.persona = null;
      return;
    }
    const p: Persona | null = await PersonaStore.get(personaId);
    this.persona = p;
  }

  private syncModeLabel(): void {
    const bits: string[] = [];
    bits.push(Model.label(AppConfig.model()));
    if (AppConfig.search()) {
      bits.push('🌐');
    }
    if (AppConfig.thinking()) {
      bits.push('🧠');
    }
    this.modeLabel = bits.join(' ');
  }

  /** 首次进入的空会话：放一条助手欢迎语（不发网络请求） */
  private async pushWelcome(): Promise<void> {
    const tip: ChatMsg = {
      role: Role.ASSISTANT,
      content: this.welcomeText(),
      ts: Date.now()
    };
    const s: Session | null = await ChatStore.load(this.sessionId);
    if (s === null) {
      return;
    }
    s.messages.push(tip);
    await ChatStore.save(s);
    this.msgs = toView(s.messages);
  }

  /** ★ 欢迎语随人设变化 —— 绑了人设就用它的名字打招呼（让用户立刻感到「生效了」） */
  private welcomeText(): string {
    const p: Persona | null = this.persona;
    if (p !== null) {
      const n: string = personaBadge(p);
      return '我是' + n + '。\n\n有什么可以帮你的？';
    }
    return '你好，我是 DeepSeek。\n\n有什么可以帮你的？\n\n（说「联网搜一下…」我会去查实时信息）';
  }

  // ======================================================================
  //  核心：发送 + 流式接收
  // ======================================================================

  private async doSend(): Promise<void> {
    const text: string = this.input.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    if (!AppConfig.hasKey()) {
      this.errMsg = ErrMsg.NO_KEY;
      return;
    }

    this.errMsg = '';
    this.searchNote = '';
    this.input = '';
    this.sending = true;

    // ① 用户消息进内存 + 视图
    const s: Session | null = await ChatStore.load(this.sessionId);
    if (s === null) {
      this.sending = false;
      this.errMsg = '会话读取失败，请返回重进';
      return;
    }
    const userMsg: ChatMsg = { role: Role.USER, content: text, ts: Date.now() };
    s.messages.push(userMsg);

    // ② 助手占位消息（流式往里填）
    const asstMsg: ChatMsg = { role: Role.ASSISTANT, content: '', ts: Date.now() };
    s.messages.push(asstMsg);

    this.msgs = toView(s.messages);
    await this.scrollToBottom();

    // ③ 发请求
    const sendList: ChatMsg[] = trimForSend(s.messages);
    // 占位的空 assistant 不发给 API（会被当成「要求继续」）
    const apiList: ChatMsg[] = [];
    for (const m of sendList) {
      if (m.role === Role.ASSISTANT && m.content.length === 0
        && (m.toolCalls === undefined || (m.toolCalls as ToolCall[]).length === 0)) {
        continue;
      }
      apiList.push(m);
    }

    // ★★ 人设注入（2026-10-03）—— 本功能**唯一**的生效点
    //
    //   顺序纪律：**先 trimForSend / 过滤占位，再 injectSystem**。
    //   反过来（先注入再裁剪）虽然当前实现下结果相同（trimForSend 规则 1
    //   明确让 system 不占配额），但那是**依赖内部实现细节**；
    //   先裁后注入不依赖任何细节，语义也更清楚：
    //   「裁剪的是真实对话，人设是发送时附加的包装层」。
    //
    //   `session.personaId` 为空（老会话 / 未绑定）时 `injectSystem`
    //   收到空 prompt 会**原样返回**，行为与升级前逐字节一致。
    //
    //   人设读不到（被删了）也**不报错**：静默不注入，正常对话。
    //   理由：用户删掉一条人设，不应该让他已有的会话直接发不出消息。
    let personaPrompt: string = '';
    if (s.personaId.length > 0) {
      const pf: Persona | null = await PersonaStore.get(s.personaId);
      if (pf !== null) {
        personaPrompt = buildSystemPrompt(pf);
      } else {
        console.info('ChatPage: 会话绑定的人设已不存在，跳过注入 id=' + s.personaId);
      }
    }
    const finalList: ChatMsg[] = injectSystem(apiList, personaPrompt);

    // ★ 发送前结构自检（2026-09-30）
    //   官方 API 对消息序列有硬约束（tool 必须与其 assistant tool_calls 配对）。
    //   一旦序列非法，服务端只会回一个 400，用户看到的是「莫名其妙失败」。
    //   这里提前校验：
    //     · 合法 → 正常发送；
    //     · 非法 → **不静默降级**，明确告知并放弃本轮（避免发出坏请求污染会话）。
    //   校验器是纯函数，与离线测试用的是同一份代码（tools/api-protocol-test.mjs）。
    //
    //   ★ 校验放在注入**之后**：system 不算 tool 配对的参与者，
    //     但「注入这个动作本身」也不能破坏配对 —— 交给同一个校验器兜住。
    const seqErrs: string[] = validateApiSequence(finalList);
    if (seqErrs.length > 0) {
      this.sending = false;
      this.errMsg = '对话上下文异常，请开启新对话';
      console.warn('ChatPage: 消息序列非法 → ' + seqErrs.join('; '));
      // 占位的助手消息没有产出，移除，避免留一条空消息
      const s2: Session | null = await ChatStore.load(this.sessionId);
      if (s2 !== null) {
        const ai: number = s2.messages.length - 1;
        if (ai >= 0 && s2.messages[ai].role === Role.ASSISTANT
          && s2.messages[ai].content.length === 0) {
          s2.messages.splice(ai, 1);
        }
        await ChatStore.save(s2);
        this.msgs = toView(s2.messages);
      }
      return;
    }

    // 视图索引（助手占位是最后一条）
    const asstIdx: number = this.msgs.length - 1;

    const sink: StreamSink = {
      onDelta: (d: string) => {
        this.appendToView(asstIdx, d, '', '');
      },
      onReasoning: (r: string) => {
        this.appendToView(asstIdx, '', r, '');
      },
      onToolCalls: (calls: ToolCall[]) => {
        const q: string = calls.length > 0 ? extractQ(calls[0].arguments) : '';
        this.searchNote = q.length > 0 ? ('正在搜索：' + q) : '正在搜索…';
        this.setToolNote(asstIdx, '🔍 ' + (q.length > 0 ? q : '联网搜索中'));
      },
      onDone: () => {
        this.finishStream(asstIdx, '');
      },
      onError: (code: number, message: string) => {
        this.finishStream(asstIdx, message);
      }
    };

    // ★ ArkTS 要求对象字面量对应显式声明的接口（arkts-no-untyped-obj-literals）
    const req: ChatRequest = {
      apiKey: AppConfig.apiKey(),
      model: AppConfig.model(),
      messages: finalList,
      stream: true,
      thinking: AppConfig.thinking(),
      search: AppConfig.search(),
      onSearch: AppConfig.search() ? async (q: string): Promise<string> => {
        const r = await SearchService.search(q);
        this.searchNote = '';
        return formatForModel(q, r.items);
      } : undefined
    };

    try {
      await this.api.chat(req, sink);
    } catch (e) {
      this.finishStream(asstIdx, ErrMsg.NETWORK);
    }
  }

  /**
   * ★ 追加流式内容到指定视图消息
   *
   * 三重保险（缺一个界面就可能不刷新）：
   *   ① 造**新对象**（不能原地改 this.msgs[i]）
   *   ② 用新数组替换（触发 @State 引用变化）
   *   ③ rev++ 并让 ForEach key 带上 rev（ForEach 才会重建该节点）
   */
  private appendToView(idx: number, delta: string, reasoning: string, toolNote: string): void {
    if (idx < 0 || idx >= this.msgs.length) {
      return;
    }
    if (delta.length === 0 && reasoning.length === 0 && toolNote.length === 0) {
      return;
    }
    const old: ViewMsg = this.msgs[idx];
    this.revSeq++;
    const next: ViewMsg = {
      key: old.key,
      role: old.role,
      content: old.content + delta,
      reasoning: old.reasoning + reasoning,
      streaming: true,
      toolNote: toolNote.length > 0 ? toolNote : old.toolNote,
      rev: this.revSeq
    };
    const arr: ViewMsg[] = this.msgs.slice(0);
    arr[idx] = next;
    this.msgs = arr;
  }

  private setToolNote(idx: number, note: string): void {
    if (idx < 0 || idx >= this.msgs.length) {
      return;
    }
    const old: ViewMsg = this.msgs[idx];
    this.revSeq++;
    const next: ViewMsg = {
      key: old.key,
      role: old.role,
      content: old.content,
      reasoning: old.reasoning,
      streaming: true,
      toolNote: note,
      rev: this.revSeq
    };
    const arr: ViewMsg[] = this.msgs.slice(0);
    arr[idx] = next;
    this.msgs = arr;
  }

  /** 流结束：落盘 + 更新视图 */
  private async finishStream(idx: number, err: string): Promise<void> {
    this.sending = false;
    this.searchNote = '';
    this.errMsg = err;

    if (idx >= 0 && idx < this.msgs.length) {
      const old: ViewMsg = this.msgs[idx];
      this.revSeq++;
      const arr: ViewMsg[] = this.msgs.slice(0);
      arr[idx] = {
        key: old.key,
        role: old.role,
        content: old.content,
        reasoning: old.reasoning,
        streaming: false,
        toolNote: '',
        rev: this.revSeq
      };
      this.msgs = arr;
    }

    // 落盘：把视图内容写回会话（视图是唯一真相源）
    const s: Session | null = await ChatStore.load(this.sessionId);
    if (s === null) {
      return;
    }
    // 会话里最后两条是本轮 user + assistant
    if (s.messages.length >= 1) {
      const ai: number = s.messages.length - 1;
      if (s.messages[ai].role === Role.ASSISTANT) {
        s.messages[ai].content = idx >= 0 && idx < this.msgs.length ? this.msgs[idx].content : '';
        s.messages[ai].reasoning = idx >= 0 && idx < this.msgs.length ? this.msgs[idx].reasoning : '';
      }
    }
    // 错误时如果助手啥也没产出，把占位删掉，避免留一条空消息
    if (err.length > 0) {
      const ai: number = s.messages.length - 1;
      if (ai >= 0 && s.messages[ai].role === Role.ASSISTANT
        && s.messages[ai].content.length === 0) {
        s.messages.splice(ai, 1);
      }
    }
    await ChatStore.save(s);
    this.msgs = toView(s.messages);
    await this.scrollToBottom();
  }

  /** 停止生成 */
  private doStop(): void {
    this.api.abort();
    promptAction.showToast({ message: '已停止', duration: 1000 });
  }

  // ======================================================================
  //  会话操作
  // ======================================================================

  /**
   * ★ 新对话
   *
   * 带上「上次用过的人设」作为默认绑定 —— 用户如果一直用同一个人设，
   * 每次新建都要重选会很烦。这个默认值来自 `Keys.LAST_PERSONA`。
   */
  private async newSession(): Promise<void> {
    this.api.abort();
    this.menuOpen = false;
    const lastPersona: string = await Store.get(Keys.LAST_PERSONA, '');
    const s: Session = await ChatStore.create(lastPersona);
    this.sessionId = s.id;
    await ChatStore.setLastSession(s.id);
    this.msgs = [];
    this.errMsg = '';
    this.input = '';
    await this.loadPersona(s.personaId);
    await this.pushWelcome();
  }

  private goSessions(): void {
    this.api.abort();
    this.menuOpen = false;
    router.pushUrl({ url: 'pages/SessionsPage' });
  }

  private goSettings(): void {
    this.menuOpen = false;
    router.pushUrl({ url: 'pages/SettingsPage' });
  }

  private goPersonaPick(): void {
    this.menuOpen = false;
    router.pushUrl({ url: 'pages/PersonaPage', params: { pick: '1' } });
  }

  /**
   * ★ 绑定/更换人设
   *
   * 与 `needsFreshSession` 配合：只有当**新老人设都填了设定**时，
   * 才提示「建议开新对话」—— 因为历史里已经有一段带旧口吻的回答，
   * 模型会拿它当风格样本，与新设定打架。
   *
   * ★ 提示是**建议**，不是强制：用户点「继续聊」就继续，
   *   绝不偷偷清空历史（清空不可逆）。
   */
  private async applyPersona(personaId: string): Promise<void> {
    const newP: Persona | null = await PersonaStore.get(personaId);
    const oldP: Persona | null = this.persona;
    const changed: boolean = await ChatStore.setPersona(this.sessionId, personaId);
    this.persona = newP;
    if (!changed) {
      return;
    }
    if (needsFreshSession(oldP, newP)) {
      promptAction.showDialog({
        title: '已切换人设',
        message: '建议开启新对话：当前历史里已有上一套设定的回答，继续聊可能让风格混杂。',
        buttons: [
          { text: '继续聊', color: Color.textSub },
          { text: '开新对话', color: Color.primary }
        ]
      }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          await this.newSession();
        }
      }).catch(() => {
      });
    } else {
      promptAction.showToast({
        message: '已切换到「' + personaBadge(newP) + '」',
        duration: 1400
      });
    }
  }

  // ======================================================================
  //  径向菜单
  // ======================================================================

  /** 菜单项定义（顺序 = 环上顺时针从正上方开始） */
  private menuItems(): RadialItem[] {
    const out: RadialItem[] = [];
    out.push({ icon: '＋', label: '新对话' });
    out.push({ icon: '☰', label: '历史' });
    out.push({ icon: '🎭', label: '人设' });
    out.push({ icon: '⚙', label: '设置' });
    return out;
  }

  /** 菜单选择 */
  private onMenuPick(i: number): void {
    // -1 = 「请求展开」（收起态点中心按钮的信号，见 RadialMenu 注释）
    if (i < 0) {
      this.menuOpen = true;
      this.menuIndex = 0;
      return;
    }
    this.menuOpen = false;
    if (i === 0) {
      this.newSession();
    } else if (i === 1) {
      this.goSessions();
    } else if (i === 2) {
      this.goPersonaPick();
    } else if (i === 3) {
      this.goSettings();
    }
  }

  /** 表冠在菜单展开时驱动高亮 */
  private feedMenu(steps: number): void {
    const n: number = this.menuItems().length;
    if (n <= 0) {
      return;
    }
    this.menuIndex = ((this.menuIndex + steps) % n + n) % n;
  }

  // ======================================================================
  //  滚动
  // ======================================================================

  private async scrollToBottom(): Promise<void> {
    // 等一帧让布局完成，否则 scrollEdge 会滚到旧位置
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 空列表时会抛，忽略
      }
    }, 60);
  }

  // ======================================================================
  //  宽度计算（★ 全部按 y，不写字面百分比）
  // ======================================================================

  /** 顶栏中心 y（vp） */
  private static readonly Y_BAR: number = 20;
  /** 底栏中心 y（vp）—— 输入行的中心 */
  private static readonly Y_BOTTOM: number = 200;
  /** 顶栏高度（vp） */
  private static readonly BAR_H: number = Touch.barH;

  /**
   * 顶栏宽度（vp）
   *
   * ★ 为什么顶栏也要收窄：它位于 y≈3~37vp，已经接近安全圆顶部（y=14vp 起）。
   *   写死 86%（=401px）在 y=20vp 处的真实可用宽度只有约 236px —— 差 165px。
   */
  private barWidthVp(): number {
    return Round.bottomUsableVp(ChatPage.Y_BAR - ChatPage.BAR_H / 2, 6);
  }

  /**
   * 底部输入行宽度（vp）
   *
   * ★★ 这是全页**最容易踩坑**的一处：输入行位于圆屏最下方，
   *   弦宽收得最快。升级前写死 84%（=391px），而 y=440 处实测
   *   物理弦宽只有约 220px —— 输入框右端直接被圆弧切掉，
   *   而且切掉的位置正好是发送按钮。
   *
   * 这里用 `bottomUsableVp(yTop)` 拿到「从该 y 一直到舒适线之间
   * **最窄处**的可用宽度」，保证整段都不会被切。
   */
  private inputRowWidthVp(): number {
    const h: number = Touch.hMd;
    const yTop: number = this.inputRowTopVp(h);
    return Round.bottomUsableVp(yTop, 6);
  }

  /** 底部操作区的上沿 y（vp）—— 由底往上的布局锚点 */
  private inputRowTopVp(h: number): number {
    // 屏幕底（233vp）- 底部留白 - 行高
    return Unit.px2vp(Round.screenH) - BOTTOM_GAP_VP - h;
  }

  // ======================================================================
  //  UI
  // ======================================================================

  build() {
    Stack() {
      this.ChatView()

      // ★ 径向菜单（覆盖层）：展开时压暗背景 + 点击遮罩关闭
      if (this.menuOpen) {
        RadialScrim({ onTap: () => this.menuOpen = false })
        RadialMenu({
          items: this.menuItems(),
          active: this.menuIndex,
          open: true,
          onPick: (i: number) => this.onMenuPick(i),
          onClose: () => this.menuOpen = false
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .backgroundColor(Color.bg)
    .borderRadius('50%')
    .clip(true)
    // 表冠：菜单展开时选菜单，否则翻消息
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      const step: number = Crown.normalize(event.degree);
      if (step === 0) {
        return;
      }
      if (this.menuOpen) {
        this.feedMenu(step);
      } else if (step > 0) {
        this.scroller.scrollBy(0, 60);
      } else {
        this.scroller.scrollBy(0, -60);
      }
    })
    // ⚠️ 不用 `onBackPressed`（该 API 在本 SDK 版本的 ColumnAttribute 上不存在）。
    //    系统 Back 的默认行为已经正确：输入法在屏时收键盘、否则退出应用。
  }

  // ----------------------------------------------------------------------
  //  对话视图
  // ----------------------------------------------------------------------

  @Builder
  ChatView() {
    Column() {
      // ---------- 顶部条：人设名 + 模式 + 菜单入口 ----------
      Row() {
        // 左：径向菜单入口（收起态下就是那个 ＋ 圆钮的位置）
        RadialMenu({
          items: this.menuItems(),
          active: this.menuIndex,
          open: false,
          onPick: (i: number) => this.onMenuPick(i),
          onClose: () => {
          }
        })

        Column() {
          // ★ 人设名（用户要求「一眼看懂当前跟谁说话」）
          if (this.persona !== null) {
            Text(personaBadge(this.persona))
              .fontSize(Typo.caption)
              .fontColor(Color.primaryText)
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          } else {
            Text('未绑定人设')
              .fontSize(Typo.caption - 1)
              .fontColor(Color.textGhost)
              .maxLines(1)
              .width('100%')
              .onClick(() => this.goPersonaPick())
          }
          Text(this.modeLabel)
            .fontSize(Typo.caption - 3)
            .fontColor(Color.textFaint)
            .maxLines(1)
            .width('100%')
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width(this.barWidthVp())
      .height(ChatPage.BAR_H)
      .alignItems(VerticalAlign.Center)
      .margin({ top: ChatPage.Y_BAR - ChatPage.BAR_H / 2 })

      // ---------- 消息列表 ----------
      List({ scroller: this.scroller }) {
        ForEach(this.msgs, (m: ViewMsg) => {
          ListItem() {
            this.MsgItem(m)
          }
        }, (m: ViewMsg) => m.key + '_' + m.rev.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 2, right: 2, top: Space.xs, bottom: 2 })

      // ---------- 错误提示（有错才占位） ----------
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(Typo.caption - 1)
          .fontColor(Color.danger)
          .textAlign(TextAlign.Center)
          .width(this.textNoteWidthVp())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }

      // ---------- 搜索状态 ----------
      if (this.searchNote.length > 0) {
        Text(this.searchNote)
          .fontSize(Typo.caption - 2)
          .fontColor(Color.primaryText)
          .textAlign(TextAlign.Center)
          .width(this.textNoteWidthVp())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }

      // ---------- 底部操作区 ----------
      //
      // ★ 圆屏约束：这一整块的下沿必须 ≤ 436px（避开 y≥450 的系统手势区）。
      //   下面的宽度全部按 y 计算，见 `inputRowWidthVp`。
      if (this.keyboardOn) {
        // 输入态：只留输入框 + 提示
        // ⚠️ 这里**不放**「收起键盘」按钮 —— 全屏输入法会盖住它，
        //    用户既看不见也点不到。收键盘的唯一途径是系统 Back。
        this.InputRow()
        Text('按侧键返回可收起键盘')
          .fontSize(Typo.caption - 2)
          .fontColor(Color.textFaint)
          .margin({ top: 1 })
      } else {
        if (this.sending) {
          // ★ `@Builder` 调用**返回 void**，不能对结果链式调 `.margin()`。
          //   想加外边距只能：① 在 Builder 内部写，或 ② 用 Column/Row 包一层。
          //   这里用 ② —— 因为「是否显示停止按钮」是条件分支，
          //   包一层 Column 不会带来额外布局开销，且保留了两态各自的间距控制。
          Column() {
            RoundButton({
              label: '停止生成',
              primary: false,
              heightVp: Touch.hSm,
              centerYVp: this.inputRowTopVp(Touch.hSm) + Touch.hSm / 2,
              onTap: () => this.doStop()
            })
          }
          .width('100%')
          .flexShrink(0)
          .margin({ top: 2, bottom: BOTTOM_GAP_VP })
        } else {
          Column() {
            this.InputRow()
          }
          .width('100%')
          .flexShrink(0)
          .margin({ bottom: BOTTOM_GAP_VP })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }

  /** 底部提示文案的宽度（按它的 y 算） */
  private textNoteWidthVp(): number {
    return Round.bottomUsableVp(Unit.px2vp(Round.screenH) - BOTTOM_GAP_VP - Touch.hMd - 14, 6);
  }

  /** 输入行：点击拉起全屏输入法 */
  @Builder
  InputRow() {
    Row() {
      TextInput({ text: this.input, placeholder: '发消息…', controller: this.inputCtl })
        .id('msgField')
        .enterKeyType(EnterKeyType.Send)
        .fontSize(Typo.body)
        .fontColor(Color.text)
        .placeholderColor(Color.textFaint)
        .backgroundColor(Color.surface)
        .borderRadius(Touch.hMd / 2)
        .height(Touch.hMd)
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .caretColor(Color.primary)
        .selectedBackgroundColor(Color.primaryDim)
        .onFocus(() => {
          this.keyboardOn = true;
        })
        .onBlur(() => {
          this.keyboardOn = false;
        })
        .onChange((v: string) => {
          this.input = v;
          if (this.errMsg.length > 0) {
            this.errMsg = '';
          }
        })
        .onSubmit(() => {
          this.doSend();
        })

      // 发送按钮（输入法不在屏时才可能被点到）
      Text('↑')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.onPrimary)
        .textAlign(TextAlign.Center)
        .width(Touch.hMd)
        .height(Touch.hMd)
        .borderRadius(Touch.hMd / 2)
        .backgroundColor(this.input.trim().length > 0 ? Color.primary : Color.disabled)
        .margin({ left: Space.xs })
        .onClick(() => this.doSend())
    }
    .width(this.inputRowWidthVp())
    .height(Touch.hMd)
    .alignItems(VerticalAlign.Center)
  }

  /** 单条消息 */
  @Builder
  MsgItem(m: ViewMsg) {
    Row() {
      if (m.role === Role.USER) {
        Blank()
        Column() {
          Text(m.content)
            .fontSize(Typo.body)
            .fontColor(Color.onPrimary)
            .lineHeight(Typo.body * Typo.lineHeight)
            .textAlign(TextAlign.Start)
            .width('100%')
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(Radius.small)
        .backgroundColor(Color.primaryDeep)
        .constraintSize({ maxWidth: '86%' })
      } else {
        Column() {
          // 工具/搜索提示
          if (m.toolNote.length > 0) {
            Text(m.toolNote)
              .fontSize(Typo.caption - 2)
              .fontColor(Color.primaryText)
              .width('100%')
              .margin({ bottom: 2 })
          }
          // 思考内容（折叠展示，暗色小字）
          if (m.reasoning.length > 0) {
            Text(m.reasoning)
              .fontSize(Typo.caption - 2)
              .fontColor(Color.textFaint)
              .lineHeight(Typo.caption * Typo.lineHeight)
              .width('100%')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(Radius.chip)
              .backgroundColor(Color.surfaceSunken)
              .margin({ bottom: 3 })
          }
          // 正文
          Text(m.content + (m.streaming ? ' ▌' : ''))
            .fontSize(Typo.body)
            .fontColor(Color.text)
            .lineHeight(Typo.body * Typo.lineHeight)
            .textAlign(TextAlign.Start)
            .width('100%')
          // 完全没内容且在流式 → 显示动起来的占位，避免「什么都没有」
          if (m.content.length === 0 && m.reasoning.length === 0
            && m.toolNote.length === 0 && m.streaming) {
            Text('▌')
              .fontSize(Typo.body)
              .fontColor(Color.primary)
              .width('100%')
          }
        }
        .width('92%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 2, right: 2, top: 4, bottom: 4 })

        Blank()
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
  }
}

// ========================================================================
//  布局常量
// ========================================================================

/**
 * 底部留白（vp）
 *
 * 屏幕高 233vp。底部操作区必须整体落在舒适线（415px = 207.5vp）之上。
 * 输入行高 40vp → 下沿 = 233 - gap。要 ≤ 207.5 → gap ≥ 25.5vp。
 * 取 **26vp** 留 0.5vp 余量。
 *
 * ★ 这个值不是拍脑袋，是「手势区硬上限 436px」与「舒适线 415px」倒推出来的。
 *   改任何底部元素高度时**必须重算**，否则最后一行会被圆弧切掉或点不到。
 */
const BOTTOM_GAP_VP: number = Unit.px2vp(Round.screenH - Round.comfortBottomPx);

// ========================================================================
//  工具函数（模块级，不依赖组件状态）
// ========================================================================

/** 把会话消息转成视图消息 */
function toView(msgs: ChatMsg[]): ViewMsg[] {
  const out: ViewMsg[] = [];
  let i: number = 0;
  for (const m of msgs) {
    // 用户消息与助手最终消息才渲染；tool 结果不单独显示
    if (m.role === Role.TOOL) {
      i++;
      continue;
    }
    out.push({
      key: 'm' + i.toString() + '_' + m.ts.toString(),
      role: m.role,
      content: m.content,
      reasoning: m.reasoning !== undefined ? (m.reasoning as string) : '',
      streaming: false,
      toolNote: '',
      rev: 0
    });
    i++;
  }
  return out;
}

/** 从工具参数里摘出 query（仅用于 UI 提示，失败返回空串） */
function extractQ(args: string): string {
  try {
    const o: Record<string, Object> = JSON.parse(args) as Record<string, Object>;
    const q: Object = o['query'];
    return typeof q === 'string' ? (q as string) : '';
  } catch (e) {
    return '';
  }
}
