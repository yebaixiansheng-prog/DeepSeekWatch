/**
 * 对话页（主界面）
 *
 * ★ 2026-09-30 推倒重来后重写。
 *
 * 圆屏纪律（都来自真机实测，不是拍脑袋）：
 *   1. 屏幕 466×466，圆心 (233,233)，R=233。**越靠下弦宽越窄**：
 *      y=415 弦宽 291px，y=428 弦宽 262px，y=450 弦宽 170px，y=466 弦宽 0。
 *   2. y ≥ 450 是**系统手势区**，点这里会把 App 推到后台 → 可点元素下沿必须 ≤ 436。
 *   3. 1vp = 2px（density=2）。
 *   4. 输入法（本机）是 `[0,0][466,466]` 的**全屏窗口**，会完全盖住 App
 *      → 输入态下 App 内任何按钮都点不到，收键盘只能靠系统 Back。
 *
 * ArkUI 渲染纪律：
 *   · **绝不原地改 `@State` 数组里的元素属性**（如 `this.msgs[i].content += x`）
 *     —— @State 只在引用变化时通知，ForEach 按 key diff，双重不感知 = 界面不动。
 *     流式追加必须「造新对象 + 替换数组元素 + rev++」，ForEach key 里带 rev。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round, FontScale } from '../common/RoundScreen';
import { Crown } from '../common/Crown';
import { RoundButton } from '../components/RoundWidgets';
import { AppConfig } from '../model/AppConfig';
import { ChatStore, Session, trimForSend, validateApiSequence } from '../model/ChatStore';
import { ApiClient, ChatMsg, ChatRequest, StreamSink, ToolCall } from '../model/ApiClient';
import { SearchService, formatForModel } from '../model/SearchService';
import { Role, ErrCode, ErrMsg, Model } from '../common/Constants';

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

/** 界面模式 */
enum UiMode {
  CHAT = 0,
  SETTINGS = 1
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
  @State mode: UiMode = UiMode.CHAT;
  /** 输入法是否在屏（全屏输入法会盖住 App） */
  @State keyboardOn: boolean = false;
  /** 字号 */
  @State fontScale: number = FontScale.STANDARD;
  /** 设置页的本地镜像（避免设置页直接读静态类导致不刷新） */
  @State stModel: string = Model.FLASH;
  @State stThinking: boolean = false;
  @State stSearch: boolean = false;
  @State stKeyPreview: string = '';

  private scroller: Scroller = new Scroller();
  private inputCtl: TextInputController = new TextInputController();
  private api: ApiClient = new ApiClient();
  /** 渲染版本计数器（全局递增，保证 key 唯一） */
  private revSeq: number = 0;

  // ======================================================================
  //  生命周期
  // ======================================================================

  async aboutToAppear(): Promise<void> {
    Typo.scale = this.fontScale as FontScale;
    await AppConfig.load();

    // 同步设置页镜像
    this.stModel = AppConfig.model();
    this.stThinking = AppConfig.thinking();
    this.stSearch = AppConfig.search();
    this.stKeyPreview = maskKey(AppConfig.apiKey());

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

    // 空会话 → 自动滚到欢迎语
    if (this.msgs.length === 0) {
      await this.pushWelcome();
    }
  }

  /** 首次进入的空会话：放一条助手欢迎语（不发网络请求） */
  private async pushWelcome(): Promise<void> {
    const tip: ChatMsg = {
      role: Role.ASSISTANT,
      content: '你好，我是 DeepSeek。\n\n有什么可以帮你的？\n\n（说「联网搜一下…」我会去查实时信息）',
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

    // ★ 发送前结构自检（2026-09-30）
    //   官方 API 对消息序列有硬约束（tool 必须与其 assistant tool_calls 配对）。
    //   一旦序列非法，服务端只会回一个 400，用户看到的是「莫名其妙失败」。
    //   这里提前校验：
    //     · 合法 → 正常发送；
    //     · 非法 → **不静默降级**，明确告知并放弃本轮（避免发出坏请求污染会话）。
    //   校验器是纯函数，与离线测试用的是同一份代码（tools/api-protocol-test.mjs）。
    const seqErrs: string[] = validateApiSequence(apiList);
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
      messages: apiList,
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

  private async newSession(): Promise<void> {
    this.api.abort();
    const s: Session = await ChatStore.create();
    this.sessionId = s.id;
    await ChatStore.setLastSession(s.id);
    this.msgs = [];
    this.errMsg = '';
    this.input = '';
    this.mode = UiMode.CHAT;
    await this.pushWelcome();
  }

  private async goSessions(): Promise<void> {
    this.api.abort();
    router.pushUrl({ url: 'pages/SessionsPage' });
  }

  private async doClearCurrent(): Promise<void> {
    // ★ 二次确认：手表上误删对话很痛苦
    promptAction.showDialog({
      title: '清空当前对话？',
      message: '该对话的全部消息将被删除，无法恢复。',
      buttons: [
        { text: '取消', color: '#8A8F9A' },
        { text: '清空', color: '#FF6B6B' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        this.clearCurrentNow();
      }
    }).catch(() => {
    });
  }

  private async clearCurrentNow(): Promise<void> {
    const s: Session | null = await ChatStore.load(this.sessionId);
    if (s !== null) {
      s.messages = [];
      await ChatStore.save(s);
    }
    this.msgs = [];
    this.errMsg = '';
    await this.pushWelcome();
  }

  // ======================================================================
  //  设置
  // ======================================================================

  private async saveThinking(v: boolean): Promise<void> {
    this.stThinking = v;
    await AppConfig.setThinking(v);
  }

  private async saveSearch(v: boolean): Promise<void> {
    this.stSearch = v;
    await AppConfig.setSearch(v);
  }

  private async switchModel(): Promise<void> {
    const next: string = this.stModel === Model.FLASH ? Model.PRO : Model.FLASH;
    this.stModel = next;
    await AppConfig.setModel(next);
    promptAction.showToast({ message: '已切换到' + Model.label(next), duration: 1200 });
  }

  private async doClearAllSessions(): Promise<void> {
    promptAction.showDialog({
      title: '清空全部对话？',
      message: '所有历史对话都会被删除，无法恢复。',
      buttons: [
        { text: '取消', color: '#8A8F9A' },
        { text: '全部清空', color: '#FF6B6B' }
      ]
    }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        await ChatStore.clearAll();
        await this.newSession();
        promptAction.showToast({ message: '已清空', duration: 1000 });
      }
    }).catch(() => {
    });
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
  //  UI
  // ======================================================================

  build() {
    Column() {
      if (this.mode === UiMode.SETTINGS) {
        this.SettingsView()
      } else {
        this.ChatView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .borderRadius('50%')
    .clip(true)
    // 表冠：对话页翻消息、设置页调字号
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      const step: number = Crown.normalize(event.degree);
      if (step === 0) {
        return;
      }
      if (this.mode === UiMode.SETTINGS) {
        this.rotateFont(step);
      } else if (event.degree > 0) {
        this.scroller.scrollBy(0, 60);
      } else {
        this.scroller.scrollBy(0, -60);
      }
    })
    // ⚠️ 不用 `onBackPressed`（该 API 在本 SDK 版本的 ColumnAttribute 上不存在）。
    //    系统 Back 的默认行为已经正确：输入法在屏时收键盘、否则退出应用。
    //    设置页的返回由页内「‹ 返回」按钮负责（见 SettingsView）。
  }

  private rotateFont(step: number): void {
    let v: number = this.fontScale + (step > 0 ? 1 : -1);
    if (v < 0) {
      v = 0;
    }
    if (v > 2) {
      v = 2;
    }
    if (v !== this.fontScale) {
      this.fontScale = v;
      Typo.scale = v as FontScale;
    }
  }

  // ----------------------------------------------------------------------
  //  对话视图
  // ----------------------------------------------------------------------

  @Builder
  ChatView() {
    Column() {
      // ---------- 顶部条 ----------
      Row() {
        // 新对话
        Text('＋')
          .fontSize(19)
          .fontColor('#C8CCD4')
          .textAlign(TextAlign.Center)
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor('#16181F')
          .onClick(() => this.newSession())

        Text(AppConfig.modelLabel())
          .fontSize(Typo.caption - 1)
          .fontColor('#5A5F6B')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)

        // 历史
        Text('☰')
          .fontSize(19)
          .fontColor('#C8CCD4')
          .textAlign(TextAlign.Center)
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor('#16181F')
          .onClick(() => this.goSessions())
      }
      .width('86%')
      .height(38)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

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
      .padding({ left: 2, right: 2, top: 4, bottom: 2 })

      // ---------- 错误提示（有错才占位） ----------
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(Typo.caption - 1)
          .fontColor('#FF6B6B')
          .textAlign(TextAlign.Center)
          .width('84%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }

      // ---------- 搜索状态 ----------
      if (this.searchNote.length > 0) {
        Text(this.searchNote)
          .fontSize(Typo.caption - 2)
          .fontColor('#5B8DEF')
          .textAlign(TextAlign.Center)
          .width('84%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }

      // ---------- 底部操作区 ----------
      //
      // ★ 圆屏约束：这一整块的下沿必须 ≤ 436（避开 y≥450 的系统手势区）
      if (this.keyboardOn) {
        // 输入态：只留输入框 + 收起提示
        this.InputRow()
        Text('按侧键返回可收起键盘')
          .fontSize(Typo.caption - 2)
          .fontColor('#5A5F6B')
          .margin({ top: 1 })
      } else {
        if (this.sending) {
          RoundButton({
            label: '停止生成',
            primary: false,
            widthRatio: 0.52,
            heightVp: 36,
            onTap: () => this.doStop()
          })
            .margin({ top: 2 })
            .flexShrink(0)
        } else {
          this.InputRow()
        }
        // 设置入口（极小，放右下）
        Row() {
          Text('设置')
            .fontSize(Typo.caption - 2)
            .fontColor('#4A4F5A')
            .onClick(() => {
              this.mode = UiMode.SETTINGS;
            })
          Blank()
          Text(AppConfig.search() ? '🌐 联网' : '')
            .fontSize(Typo.caption - 2)
            .fontColor('#4A4F5A')
        }
        .width('62%')
        .margin({ top: 1 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }

  /** 输入行：点击拉起全屏输入法 */
  @Builder
  InputRow() {
    Row() {
      TextInput({ text: this.input, placeholder: '发消息…', controller: this.inputCtl })
        .id('msgField')
        .enterKeyType(EnterKeyType.Send)
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
        .placeholderColor('#5A5F6B')
        .backgroundColor('#12141A')
        .borderRadius(19)
        .height(38)
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .caretColor('#4D6BFE')
        .selectedBackgroundColor('#2A3350')
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
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(38)
        .height(38)
        .borderRadius(19)
        .backgroundColor(this.input.trim().length > 0 ? '#4D6BFE' : '#2A2E3A')
        .margin({ left: 4 })
        .onClick(() => this.doSend())
    }
    .width('84%')
    .height(38)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 2 })
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
            .fontColor('#FFFFFF')
            .lineHeight(Typo.body * Typo.lineHeight)
            .textAlign(TextAlign.Start)
            .width('100%')
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(12)
        .backgroundColor('#3352CC')
        .constraintSize({ maxWidth: '86%' })
      } else {
        Column() {
          // 工具/搜索提示
          if (m.toolNote.length > 0) {
            Text(m.toolNote)
              .fontSize(Typo.caption - 2)
              .fontColor('#5B8DEF')
              .width('100%')
              .margin({ bottom: 2 })
          }
          // 思考内容（折叠展示，暗色小字）
          if (m.reasoning.length > 0) {
            Text(m.reasoning)
              .fontSize(Typo.caption - 2)
              .fontColor('#6E7380')
              .lineHeight(Typo.caption * Typo.lineHeight)
              .width('100%')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(8)
              .backgroundColor('#0E1014')
              .margin({ bottom: 3 })
          }
          // 正文
          Text(m.content + (m.streaming ? ' ▌' : ''))
            .fontSize(Typo.body)
            .fontColor('#E8EAED')
            .lineHeight(Typo.body * Typo.lineHeight)
            .textAlign(TextAlign.Start)
            .width('100%')
          // 完全没内容且在流式 → 显示动起来的占位，避免「什么都没有」
          if (m.content.length === 0 && m.reasoning.length === 0
            && m.toolNote.length === 0 && m.streaming) {
            Text('▌')
              .fontSize(Typo.body)
              .fontColor('#4D6BFE')
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

  // ----------------------------------------------------------------------
  //  设置视图
  // ----------------------------------------------------------------------

  @Builder
  SettingsView() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(Typo.caption)
          .fontColor('#8A8F9A')
          .onClick(() => {
            this.mode = UiMode.CHAT;
          })
        Blank()
        Text('设置')
          .fontSize(Typo.caption)
          .fontColor('#E8EAED')
        Blank()
        Text('　　')
          .fontSize(Typo.caption)
      }
      .width('80%')
      .height(30)
      .margin({ top: 10 })

      Scroll() {
        Column({ space: 7 }) {
          // 模型
          this.SetRow('模型', Model.label(this.stModel), () => this.switchModel())

          // 思考模式
          this.SetToggle('深度思考', AppConfig.thinkingLabel(), this.stThinking,
            (v: boolean) => this.saveThinking(v))

          // 联网搜索
          this.SetToggle('联网搜索', AppConfig.searchLabel(), this.stSearch,
            (v: boolean) => this.saveSearch(v))

          // 字号
          this.SetRow('字号', fontLabel(this.fontScale),
            () => this.rotateFont(1))

          // 密钥预览
          this.SetRow('API 密钥', this.stKeyPreview, () => {
            promptAction.showToast({
              message: '密钥已内置，如需更换请修改工程内 Constants.ets',
              duration: 2000
            });
          })

          // 清空当前对话
          this.SetDangerRow('清空当前对话', () => this.doClearCurrent())

          // 清空全部
          this.SetDangerRow('清空全部对话', () => this.doClearAllSessions())

          Text('DeepSeek Watch · 官方 API')
            .fontSize(Typo.caption - 2)
            .fontColor('#3E434E')
            .margin({ top: 4, bottom: 6 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 4, bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SetRow(label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
        .layoutWeight(1)
        .maxLines(1)
      Text(value)
        .fontSize(Typo.caption)
        .fontColor('#8A8F9A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '52%' })
    }
    .width('84%')
    .height(42)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor('#12141A')
    .onClick(onTap)
  }

  @Builder
  SetToggle(label: string, desc: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(Typo.body)
          .fontColor('#E8EAED')
          .maxLines(1)
        if (desc.length > 0) {
          Text(desc)
            .fontSize(Typo.caption - 2)
            .fontColor('#6E7380')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor('#4D6BFE')
        .switchPointColor('#FFFFFF')
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('84%')
    .height(48)
    .padding({ left: 12, right: 8 })
    .borderRadius(12)
    .backgroundColor('#12141A')
  }

  @Builder
  SetDangerRow(label: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(Typo.body)
        .fontColor('#FF6B6B')
        .layoutWeight(1)
        .maxLines(1)
    }
    .width('84%')
    .height(42)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor('#1A1214')
    .onClick(onTap)
  }
}

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

/** 密钥脱敏显示 */
function maskKey(k: string): string {
  if (k.length <= 12) {
    return k.length > 0 ? '****' : '（未配置）';
  }
  return k.substring(0, 7) + '…' + k.substring(k.length - 4);
}

function fontLabel(v: number): string {
  if (v === FontScale.SMALL) {
    return '小';
  }
  if (v === FontScale.LARGE) {
    return '大';
  }
  return '标准';
}
