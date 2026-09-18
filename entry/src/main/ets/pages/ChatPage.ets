import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round } from '../common/RoundScreen';
import { Crown, ContextScroller } from '../common/Crown';
import { AuthService } from '../model/AuthService';
import { ChatService, ChatMessage, ChatParams, Fragment, ChatCallbacks } from '../model/ChatService';
import { DsApi, FragmentType, FragStatus, Role, ModelType } from '../common/Constants';
import { Store, Keys } from '../common/Store';
import { RoundSwitchRow } from '../components/RoundWidgets';
import { Nav } from '../common/Nav';
import { PowSolver, PowFail } from '../model/PowSolver';

/**
 * 对话页（圆形表盘深度定制）
 *
 * 表冠行为（按用户要求）：
 *   - **旋转表冠 = 翻动上下文**（滚动消息列表）
 *   - 逆时针向上翻（看历史），顺时针向下翻（看最新）
 *
 * 圆形屏适配：
 *   - 消息气泡不做满宽，按纵向位置动态收窄（避免被圆弧裁切）
 *   - 顶部标题栏 + 底部输入条尽量贴圆
 *   - 长按消息可复制
 */
@Entry
@Component
struct ChatPage {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State sending: boolean = false;
  @State statusText: string = '';
  @State sessionId: string = '';
  @State thinkingOn: boolean = true;   // 默认开深度思考（省电优先，符合用户要求）
  @State searchOn: boolean = true;     // 默认开联网搜索
  @State scrollOffset: number = 0;
  @State contentHeight: number = 0;
  @State viewHeight: number = 0;
  @State showMenu: boolean = false;
  /** 输入法是否已拉起（用于让出竖向空间，避免输入框被输入法遮挡） */
  @State keyboardOn: boolean = false;

  private scroller: Scroller = new Scroller();
  private ctx: ContextScroller = new ContextScroller();
  private chat: ChatService = new ChatService();
  private followTail: boolean = true;
  private inputCtl: TextInputController = new TextInputController();

  aboutToAppear(): void {
    this.restoreSession();
  }

  /**
   * 页面重新可见时，检查「历史对话页」带回来的导航意图
   *
   * 历史页点会话 → Nav.selectSession(id) → router.back()，
   * 这里取走意图并切到对应会话（取走即清空，只生效一次）。
   */
  onPageShow(): void {
    const pending: string | null = Nav.takePending();
    if (pending === null) {
      return;
    }
    if (pending.length === 0) {
      this.newChat();
    } else {
      this.loadSession(pending);
    }
  }

  /**
   * 返回键
   *
   * ⚠️ 真实事故（2026-09-13）：设置浮层打开时按返回，事件穿透到路由，
   *    把对话页整个弹回入口页，紧接着的一次点击就落在「退出登录」上，
   *    登录态被抹掉、只能重新输密码。
   *    因此浮层打开时返回键必须先被浮层消费掉。
   * @returns true 表示已消费该事件
   */
  onBackPress(): boolean {
    if (this.showMenu) {
      this.showMenu = false;
      return true;
    }
    return false;
  }

  private async restoreSession(): Promise<void> {
    const v: string = await Store.get(Keys.AUTO_THINK, '1');
    this.thinkingOn = v === '1';
    const s: string = await Store.get(Keys.AUTO_SEARCH, '1');
    this.searchOn = s === '1';

    // 会话来源优先级：路由参数（历史页带 id 跳进来）> 上次会话
    let sid: string = this.readSessionIdParam();
    if (sid.length === 0) {
      sid = await Store.get(Keys.LAST_SESSION, '');
    }
    if (sid.length > 0) {
      await this.loadSession(sid);
    }
    // ★ 预热 PoW：空闲时先把「安全校验」算好放进缓存，
    //   用户点发送时直接命中缓存（挑战 5 分钟内可复用），体感从「转十几秒」变「几乎瞬时」。
    PowSolver.prewarm(AuthService.getToken(), DsApi.COMPLETION);
  }

  /** 读取路由参数里的 sessionId（无参数 / 类型不符一律返回空串） */
  private readSessionIdParam(): string {
    try {
      const po: Record<string, Object> = router.getParams() as Record<string, Object>;
      const raw: Object | undefined = po['sessionId'];
      if (typeof raw === 'string') {
        return raw as string;
      }
    } catch (e) {
      // 无参数时 getParams() 可能返回 undefined，取下标会抛异常 —— 按「无 sessionId」处理
    }
    return '';
  }

  /**
   * 载入指定会话的历史消息
   *
   * 切换会话前必须先停掉正在进行的流式生成，
   * 否则旧会话的增量会灌进新会话的气泡里。
   */
  private async loadSession(sid: string): Promise<void> {
    if (sid.length === 0) {
      return;
    }
    if (this.sending) {
      await this.chat.stop(AuthService.getToken(), this.sessionId, '');
      this.sending = false;
    }
    this.messages = [];
    this.sessionId = sid;
    this.statusText = '加载历史…';
    this.followTail = true;
    this.ctx.offset = 0;
    this.ctx.contentH = 0;
    const hist: ChatMessage[] = await ChatService.history(AuthService.getToken(), sid);
    this.messages = hist;
    this.statusText = '';
    await Store.put(Keys.LAST_SESSION, sid);
    this.scrollToBottom();
  }

  build() {
    Stack() {
      Column() {
        // 顶部状态条
        this.TopBar()

        // 消息区
        this.MessageArea()

        // 底部输入区
        this.BottomBar()
      }
      .width('100%')
      .height('100%')

      // 长按菜单
      if (this.showMenu) {
        this.MenuOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 圆形屏最外层：裁成内切圆，四角内容不会溢出到表壳外
    .borderRadius('50%')
    .clip(true)
  }

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(20)
        .fontColor('#C8CCD4')
        .width(30)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })

      Column() {
        Text(this.sending ? '思考中…' : 'DeepSeek')
          .fontSize(Typo.body)
          .fontColor('#E8EAED')
          .fontWeight(FontWeight.Medium)
          // ⚠️ 圆形屏顶栏很窄（466 屏上该行可用宽度仅约 321px），
          //    必须限制单行，否则标题会折成两行把状态条挤出可视区
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(Typo.caption - 1)
            .fontColor('#4D6BFE')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        // 点标题也能打开设置（与右侧「⋯」等价，降低发现成本）
        this.showMenu = true;
      })

      // ⋯ 对话设置（深度思考 / 联网搜索 / 新对话）
      Text('⋯')
        .fontSize(16)
        .fontColor('#C8CCD4')
        .width(26)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.showMenu = true;
        })

      // ≡ 历史对话（网页版能看历史，手表也能翻）
      Text('≡')
        .fontSize(18)
        .fontColor('#C8CCD4')
        .width(30)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.pushUrl({ url: 'pages/HistoryPage' });
        })
    }
    // 顶栏位于圆弧收窄区，宽度取安全圆在上部的实际可用宽度
    .width(Round.wPct(Round.widthAtY(-Round.safeRadius * 0.62)))
    .height(44)
    .margin({ top: Round.topInset + 8 })
  }

  @Builder
  MessageArea() {
    Scroll(this.scroller) {
      Column({ space: 10 }) {
        if (this.messages.length === 0) {
          this.WelcomeBlock()
        } else {
          ForEach(this.messages, (m: ChatMessage, idx: number) => {
            this.Bubble(m, idx)
          }, (m: ChatMessage) => m.id + '#' + m.rev.toString())
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      // 用内容列自身高度作为内容总高（比 Blank 探针可靠）
      .onAreaChange((o: Area, n: Area) => {
        const h: number = Number(n.height);
        if (h > 0) {
          this.contentHeight = h;
          this.ctx.contentH = h;
        }
      })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Vertical)
    .width('100%')
    .layoutWeight(1)
    // ★ 表冠旋转 → 翻动上下文
    //
    // 设计说明：
    //   Scroll 组件**默认**已支持表冠滚动（系统内置交互），
    //   只需满足焦点条件：focusable + defaultFocus + focusOnTouch。
    //   这里再显式接管 onDigitalCrown，是为了实现：
    //     1) 自定义翻动步长（默认滚动太灵敏，手表上不易精确阅读）
    //     2) 「用户翻动时暂停自动跟随，滚到底部恢复跟随」的行为
    //   event.stopPropagation() 阻止事件冒泡，避免与默认滚动叠加。
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      // 阻止默认滚动，改由 handleCrown 精确控制
      event.stopPropagation();
      this.handleCrown(event.degree);
    })
    .onAreaChange((o: Area, n: Area) => {
      this.viewHeight = Number(n.height);
      this.ctx.viewH = this.viewHeight;
    })
    .onScroll((xOff: number, yOff: number) => {
      this.scrollOffset = yOff;
      this.ctx.offset = yOff;
    })
  }

  @Builder
  WelcomeBlock() {
    Column() {
      Text('◈')
        .fontSize(38)
        .fontColor('#4D6BFE')
      Text('有什么可以帮你？')
        .fontSize(Typo.title)
        .fontColor('#E8EAED')
        .margin({ top: 8 })
      Text('表冠上下翻动 · 点击输入')
        .fontSize(Typo.caption)
        .fontColor('#5A5F6B')
        .margin({ top: 6 })
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
  }

  /** 消息气泡 */
  @Builder
  Bubble(m: ChatMessage, idx: number) {
    Column({ space: 6 }) {
      ForEach(m.fragments, (f: Fragment) => {
        if (f.type === FragmentType.THINK) {
          // 思考过程：灰底、折叠风格
          Column() {
            Row() {
              Text('深度思考')
                .fontSize(Typo.caption - 1)
                .fontColor('#8A8F9A')
              Blank()
              // WIP → 转圈提示；异常结束 → 提示被截断
              if (f.status === FragStatus.WIP) {
                Text('思考中')
                  .fontSize(Typo.caption - 1)
                  .fontColor('#4D6BFE')
              } else if (f.status === FragStatus.CONTENT_FILTER) {
                Text('已过滤')
                  .fontSize(Typo.caption - 1)
                  .fontColor('#E5484D')
              } else {
                Text('✦')
                  .fontSize(Typo.caption - 1)
                  .fontColor('#4D6BFE')
              }
            }
            .width('100%')

            Text(f.content)
              .fontSize(Typo.caption)
              .fontColor('#8A8F9A')
              .lineHeight(Typo.caption * Typo.lineHeight)
              .width('100%')
              .margin({ top: 4 })
          }
          .width('100%')
          .padding(10)
          .borderRadius(12)
          .backgroundColor('#14161C')
          .border({ width: 1, color: '#1E222C' })
        } else if (f.type === FragmentType.TOOL_SEARCH) {
          Row() {
            Text('🔍')
              .fontSize(Typo.caption)
            Text(f.status === FragStatus.WIP ? '联网搜索中…' : '已联网搜索')
              .fontSize(Typo.caption)
              .fontColor(f.status === FragStatus.FAILED ? '#E5A24D' : '#4DD07E')
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(10)
          .backgroundColor('#12241A')
        } else {
          // 正文片段
          //
          // ⚠️ 服务端会在片段上带 status，除了正常的 FINISHED 还可能是
          //    CONTENT_FILTER（内容被安全过滤）、TIMEOUT / INCOMPLETE（生成中断）、
          //    CONTEXT_LENGTH_EXCEEDED（超出上下文长度）。
          //    这些情况下 content 可能是空的或半截的 —— 必须显式告诉用户原因，
          //    否则用户只看到一个空气泡，会以为「App 坏了 / DeepSeek 没回应」。
          if (f.content.length > 0) {
            Text(f.content)
              .fontSize(Typo.body)
              .fontColor('#E8EAED')
              .lineHeight(Typo.body * Typo.lineHeight)
              .width('100%')
              .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
              .copyOption(CopyOptions.LocalDevice)
          }
          if (f.status === FragStatus.CONTENT_FILTER) {
            Text('⚠ 该内容已被安全过滤')
              .fontSize(Typo.caption)
              .fontColor('#E5A24D')
              .width('100%')
          } else if (f.status === FragStatus.TIMEOUT || f.status === FragStatus.INCOMPLETE) {
            Text('⚠ 回复被中断')
              .fontSize(Typo.caption)
              .fontColor('#E5A24D')
              .width('100%')
          } else if (f.status === FragStatus.CONTEXT_LENGTH_EXCEEDED) {
            Text('⚠ 已超出上下文长度，请新建对话')
              .fontSize(Typo.caption)
              .fontColor('#E5A24D')
              .width('100%')
          }
        }
      }, (f: Fragment, i: number) => f.id + i.toString())

      // 流式光标
      if (m.streaming) {
        Text('▍')
          .fontSize(Typo.caption)
          .fontColor('#4D6BFE')
      }
    }
    .width('94%')
    .alignItems(m.role === Role.USER ? HorizontalAlign.End : HorizontalAlign.Start)
    .padding(m.role === Role.USER ? { left: 40 } : { right: 40 })
  }

  @Builder
  BottomBar() {
    Row() {
      // ★ 官方输入法：真正的系统 TextInput，点击即拉起手表自带输入法
      //   注意：controller 必须写在构造参数对象里，不能链式 .controller()
      //   ⚠️ 底栏在圆弧收窄区（466 屏上约 256px 宽），减去发送键只剩 ~156px，
      //      占位符用「发消息」三个字刚好；写成「发消息…」会被截成「发…」。
      TextInput({ text: this.inputText, placeholder: '发消息', controller: this.inputCtl })
        .type(InputType.Normal)
        // 聊天场景用「发送」作为回车键，输入法右下角直接可发
        .enterKeyType(EnterKeyType.Send)
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
        .placeholderColor('#5A5F6B')
        .backgroundColor('#12141A')
        .borderRadius(21)
        .height(42)
        .layoutWeight(1)
        .padding({ left: 10, right: 10 })
        .caretColor('#4D6BFE')
        .selectedBackgroundColor('#2A3350')
        .onFocus(() => {
          // 输入法弹出 → 记录状态，让消息区自动跟随到底部
          this.keyboardOn = true;
          this.followTail = true;
        })
        .onBlur(() => {
          this.keyboardOn = false;
        })
        .onChange((v: string) => {
          this.inputText = v;
        })
        .onSubmit(() => {
          // 输入法回车键 → 直接发送
          this.sendMessage();
        })

      // 发送 / 停止
      if (this.sending) {
        Text('■')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor('#E5484D')
          .margin({ left: 8 })
          .onClick(() => {
            this.stopGeneration();
          })
      } else {
        Text('↑')
          .fontSize(18)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor(this.inputText.length > 0 ? '#4D6BFE' : '#2A2E3A')
          .margin({ left: 8 })
          .onClick(() => {
            this.sendMessage();
          })
      }
    }
    // 底栏同样在圆弧收窄区，用圆方程算出该高度的可用宽度
    .width(Round.wPct(Round.widthAtY(Round.safeRadius * 0.78)))
    .margin({ bottom: Round.topInset + 10 })
  }

  @Builder
  MenuOverlay() {
    // ⚠️ 466 圆形屏上 1vp = 2px：浮层内容总高必须控制在 ~217vp(434px) 内，
    //    否则底部的按钮会被圆弧/屏幕边缘裁掉（真机实测踩过：height 58 的开关行
    //    就是 116px，两行加两个按钮直接把「关闭」挤出了屏幕）。
    Column({ space: 8 }) {
      Text('对话设置')
        .fontSize(Typo.title)
        .fontColor('#E8EAED')
        .margin({ top: 2 })

      // ⚠️ 这里原本是「快速模式 / 专项模式」分段控件，已按需求删除：
      //    DeepSeek 官网已把两种模式合并为统一模式（expert 模型在账号侧
      //    是 disabled，切过去会 400），手表端再做一层「模式」只会误导用户。
      //    现在只保留两个真正影响请求参数的开关，且默认全开。
      //    model_type 固定用 ModelType.QUICK（= 'default'）。

      // 深度思考
      RoundSwitchRow({
        label: '深度思考',
        desc: '更严谨，耗电略高',
        widthRatio: 0.84,
        on: this.thinkingOn,
        onChange: (v: boolean) => {
          this.thinkingOn = v;
          Store.put(Keys.AUTO_THINK, v ? '1' : '0');
        }
      })

      // 联网搜索
      RoundSwitchRow({
        label: '联网搜索',
        desc: '获取实时信息',
        widthRatio: 0.84,
        on: this.searchOn,
        onChange: (v: boolean) => {
          this.searchOn = v;
          Store.put(Keys.AUTO_SEARCH, v ? '1' : '0');
        }
      })

      Button('新对话')
        .type(ButtonType.Capsule)
        .width('84%')
        .height(38)
        .fontSize(Typo.body)
        .fontColor('#FFFFFF')
        .backgroundColor('#1C1F27')
        .onClick(() => {
          this.newChat();
        })

      Button('关闭')
        .type(ButtonType.Capsule)
        .width('84%')
        .height(38)
        .fontSize(Typo.body)
        .fontColor('#C8CCD4')
        .backgroundColor('#1C1F27')
        .margin({ bottom: 6 })
        .onClick(() => {
          this.showMenu = false;
        })
    }
    .width('100%')
    .height('92%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#000000')
  }

  /**
   * 表冠旋转 → 翻动上下文
   *
   * 实现策略：
   *   Scroll 组件本身已默认响应表冠滚动（系统内置逻辑），
   *   但为了精准控制「翻动步长」和「跟随最新」行为，
   *   这里显式接管：关闭 followTail，按步长滚动到目标位置。
   *
   * 方向约定（符合直觉）：
   *   顺时针（degree > 0）→ 向下翻 → 看更新的内容
   *   逆时针（degree < 0）→ 向上翻 → 看历史内容
   *
   * @param degree CrownEvent.degree（正=顺时针）
   */
  handleCrown(degree: number): void {
    // ⚠️ 输入法拉起时表冠交给输入法（光标/候选词移动），不抢事件，
    //    否则用户在输入中文时会因为表冠而误翻消息列表。
    if (this.keyboardOn) {
      return;
    }
    const steps: number = Crown.normalize(degree);
    if (steps === 0) {
      return;
    }
    // 用户主动翻动 → 暂停自动跟随
    this.followTail = false;

    this.ctx.contentH = this.contentHeight;
    this.ctx.viewH = this.viewHeight;
    if (this.ctx.rotate(steps)) {
      this.scroller.scrollTo({
        xOffset: 0,
        yOffset: this.ctx.offset,
        animation: { duration: 100, curve: Curve.EaseOut }
      });
    }
    // 翻到最底部则恢复自动跟随（新消息会继续滚屏）
    if (this.ctx.atBottom()) {
      this.followTail = true;
    }
  }

  /** 发送消息 */
  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    this.inputText = '';
    // 清空内容后同步清控件，避免 TextInput 内部缓存旧文本
    this.inputCtl.stopEditing();
    this.keyboardOn = false;
    this.followTail = true;
    this.showMenu = false;

    // 计算 parentMessageId：取最近一条「已完成且有服务端真实 id」的助手消息
    // ⚠️ 必须在追加本地占位消息**之前**计算，否则会把占位消息算进去
    let parentId: string | null = null;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const m: ChatMessage = this.messages[i];
      // 只认服务端返回的 id（本地占位 id 带 'u-' / 'a-' 前缀）
      if (m.role === Role.ASSISTANT && m.done && m.id.length > 0
        && m.id.indexOf('a-') !== 0) {
        parentId = m.id;
        break;
      }
    }

    // ⚠️ 顺序关键：先确保有会话，再追加本地消息。
    //    否则会话创建失败时列表里会留下一条「永远转圈」的空消息。
    if (this.sessionId.length === 0) {
      this.statusText = '创建会话…';
      const sid: string = await ChatService.createSession(AuthService.getToken());
      if (sid.length === 0) {
        this.sending = false;
        this.statusText = '';
        promptAction.showToast({ message: '会话创建失败，请重试', duration: 2000 });
        return;
      }
      this.sessionId = sid;
      await Store.put(Keys.LAST_SESSION, sid);
    }

    // 本地追加用户消息
    const userMsg: ChatMessage = {
      id: 'u-' + Date.now().toString(),
      role: Role.USER,
      fragments: [{ id: 'uf', type: FragmentType.RESPONSE, content: text, status: FragStatus.FINISHED }],
      streaming: false,
      done: true,
      rev: 0
    };

    // 助手消息（流式占位）
    const asstId: string = 'a-' + Date.now().toString();
    const asstMsg: ChatMessage = {
      id: asstId,
      role: Role.ASSISTANT,
      fragments: [],
      streaming: true,
      done: false,
      rev: 0
    };

    const list: ChatMessage[] = this.messages.slice();
    list.push(userMsg);
    list.push(asstMsg);
    this.messages = list;
    this.sending = true;
    this.statusText = '准备中…';
    this.startSendWatchdog(asstId);

    const params: ChatParams = {
      sessionId: this.sessionId,
      parentMessageId: parentId,
      prompt: text,
      thinkingEnabled: this.thinkingOn,
      searchEnabled: this.searchOn,
      modelType: ModelType.QUICK
    };

    // 本地增量缓冲：THINK / RESPONSE 分片
    let thinkBuf: string = '';
    let respBuf: string = '';
    let thinkId: string = 't-' + asstId;
    let respId: string = 'r-' + asstId;
    /** 本次是否收到过任何正文（用于「流结束了但一个字都没有」的兜底提示） */
    let gotAny: boolean = false;
    /** 是否已经报过错（报错后流还可能补一个 finish，不能把错误文案覆盖掉） */
    let hadError: boolean = false;
    /** PoW 被判无效后是否已自动重试过（只重试一次，避免死循环） */
    let powRetried: boolean = false;

    const cb: ChatCallbacks = {
      onPowProgress: (tried: number, total: number) => {
        const pct: number = total > 0 ? Math.min(99, Math.floor(tried * 100 / total)) : 0;
        this.statusText = '安全校验 ' + pct.toString() + '%';
      },
      onSessionCreated: (sid: string) => {
        this.sessionId = sid;
        Store.put(Keys.LAST_SESSION, sid);
      },
      onThinkingDelta: (t: string) => {
        gotAny = true;
        this.statusText = '深度思考中…';
        thinkBuf += t;
        this.updateAssistant(asstId, this.buildFrags(thinkId, thinkBuf, respId, respBuf, true));
      },
      onResponseDelta: (t: string) => {
        gotAny = true;
        this.statusText = '';
        respBuf += t;
        this.updateAssistant(asstId, this.buildFrags(thinkId, thinkBuf, respId, respBuf, false));
      },
      onSearchResult: () => {
        gotAny = true;
        this.statusText = '已联网搜索';
      },
      onHint: (t: string) => {
        this.statusText = t;
      },
      onFinish: () => {
        // ★ 兜底：流正常结束但一个字都没收到 —— 必须给用户明确反馈，
        //   否则界面只剩一个空气泡，看起来就是「没得到 DeepSeek 的回应」。
        //   ⚠️ 已经报过错就不要覆盖（错误路径也可能紧随其后收到 finish）。
        if (!gotAny && !hadError) {
          this.updateAssistant(asstId, [
            {
              id: respId, type: FragmentType.RESPONSE,
              content: '⚠ 未收到回复内容，请重试', status: FragStatus.FINISHED
            }
          ]);
        }
        this.finishAssistant(asstId);
      },
      onError: (msg: string) => {
        // ★ PoW 头被服务端判无效（POW_HEADER_ERROR=40300 / INVALID_POW_RESPONSE=40301）：
        //   绝大多数情况是「缓存的挑战已过期或被服务端作废」，而不是算法错。
        //   这里清掉缓存自动重试一次（只重试一次，避免死循环），用户无感 ——
        //   直接报错会让用户以为「消息根本发不出去」。
        if ((msg === 'srv_40300' || msg === 'srv_40301') && !powRetried) {
          powRetried = true;
          PowSolver.clearCache();
          thinkBuf = '';
          respBuf = '';
          gotAny = false;
          this.statusText = '重新校验…';
          // ★ 重试是「又开了一轮」，必须把看门狗时间窗重启。
          //   否则重试这一轮会继承上一轮已经消耗掉的时间，
          //   可能在正常等待中就被硬上限打断，弹出假的超时提示。
          this.startSendWatchdog(asstId);
          this.chat.send(AuthService.getToken(), params, DsApi.COMPLETION, cb);
          return;
        }
        hadError = true;
        this.sending = false;
        this.statusText = '';
        this.updateAssistant(asstId, [
          {
            id: respId, type: FragmentType.RESPONSE,
            content: '⚠ ' + this.errText(msg), status: FragStatus.FINISHED
          }
        ]);
        this.finishAssistant(asstId);
      }
    };

    await this.chat.send(AuthService.getToken(), params, DsApi.COMPLETION, cb);

    // ★ 本次发送结束后立刻预热下一道 PoW：
    //   当前缓存可能已经快到期，提前算好，用户发下一条消息时依旧几乎瞬时。
    PowSolver.prewarm(AuthService.getToken(), DsApi.COMPLETION);
  }

  /**
   * 组装流式片段的快照
   *
   * ⚠️ 必须每次构造**新对象**：ArkUI 的 @State 依赖引用变化触发重渲染，
   *    复用同一对象会导致增量内容不刷新。
   *    status 用于 UI 区分「思考中」（WIP）与「已完成」（FINISHED）。
   */
  private buildFrags(thinkId: string, thinkBuf: string,
    respId: string, respBuf: string, thinking: boolean): Fragment[] {
    const frags: Fragment[] = [];
    if (thinkBuf.length > 0) {
      frags.push({
        id: thinkId,
        type: FragmentType.THINK,
        content: thinkBuf,
        status: thinking ? FragStatus.WIP : FragStatus.FINISHED
      });
    }
    if (respBuf.length > 0) {
      frags.push({
        id: respId,
        type: FragmentType.RESPONSE,
        content: respBuf,
        status: FragStatus.WIP
      });
    }
    return frags;
  }

  private errText(code: string): string {
    if (code === 'pow_failed') {
      return '安全校验失败，请重试';
    }
    // ★ PoW 的两种失败要分开说（见 PowSolver.getLastFail 的注释）
    if (code === PowFail.NO_CHALLENGE) {
      return '无法获取安全校验题（网络或登录态异常）。请检查网络后重试';
    }
    if (code === PowFail.TIMEOUT) {
      return '安全校验超时（设备算力或网络较慢）。请稍后重试，或切换到更稳的网络';
    }
    if (code === 'stream_error') {
      return '网络中断，请重试';
    }
    // ★ 服务端把请求挂住了：连接建立但一个字节都没回（典型是排队/网关挂死）。
    //   必须给出「怎么解决」，只说失败用户会一直重试到崩溃。
    if (code === 'stalled') {
      return '服务端无响应（连接被挂起）。请重试；若反复出现，点左下角「＋」新建对话';
    }
    // 服务端在 SSE 流里返回的业务错误（如 PoW 未通过）
    if (code.indexOf('srv_') === 0) {
      const c: string = code.substring(4);
      if (c === '40300' || c === '40301') {
        return '安全校验未通过，请重试';
      }
      if (c === '40002') {
        return '会话不存在，请新建会话';
      }
      if (c === '40011' || c === '40012') {
        return '请求过于频繁，请稍后再试';
      }
      // 40303 = 该会话上有未结束的流（排队被拒）
      if (c === '40303') {
        return '上一轮回复未结束，请稍候重试';
      }
      return '服务端拒绝（' + c + '）';
    }
    return '请求失败，请重试';
  }

  /** 更新助手消息内容 */
  private updateAssistant(id: string, frags: Fragment[]): void {
    const list: ChatMessage[] = this.messages.slice();
    for (let i = 0; i < list.length; i++) {
      const m: ChatMessage = list[i];
      if (m.id === id) {
        // ★ 必须换成**新对象**并递增 rev：
        //   ArkUI 的 @State 只在引用变化时通知刷新，而 ForEach 又按 key 做 diff；
        //   两者叠加会导致「原地改 fragments」完全不可见（气泡永远是空的）。
        list[i] = {
          id: m.id,
          role: m.role,
          fragments: frags,
          streaming: m.streaming,
          done: m.done,
          rev: m.rev + 1
        };
        break;
      }
    }
    this.messages = list;
    if (this.followTail) {
      this.scrollToBottom();
    }
  }

  /**
   * 结束助手消息（幂等）
   *
   * 除清掉 streaming 标记外，还要把仍处于 WIP 的片段置为 FINISHED，
   * 否则「思考中」指示会一直挂着不消失。
   * 重复调用安全（onFinish 可能来自 finish 事件与流结束两处）。
   */
  private finishAssistant(id: string): void {
    const list: ChatMessage[] = this.messages.slice();
    let changed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== id) {
        continue;
      }
      // 已经结束过 → 不必重建对象（省一次多余刷新），
      // 但**不能 return**：后面的 sending/statusText 复位必须照常执行。
      // 之前这里直接 return，一旦某条结束路径命中它，界面就会永久卡在「发送中」。
      if (!(list[i].done && !list[i].streaming)) {
        const fixed: Fragment[] = [];
        for (let j = 0; j < list[i].fragments.length; j++) {
          const f: Fragment = list[i].fragments[j];
          fixed.push({
            id: f.id,
            type: f.type,
            content: f.content,
            status: f.status === FragStatus.WIP ? FragStatus.FINISHED : f.status,
            results: f.results
          });
        }
        // 同样换成新对象 + rev++，保证「思考中/流式光标」能正确消失
        list[i] = {
          id: list[i].id,
          role: list[i].role,
          fragments: fixed,
          streaming: false,
          done: true,
          rev: list[i].rev + 1
        };
        changed = true;
      }
      break;
    }
    if (changed) {
      this.messages = list;
    }
    // 所有结束路径都会汇到这里 → 统一撤掉发送看门狗
    this.clearSendWatchdog();
    this.sending = false;
    this.statusText = '';
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 30);
  }

  /**
   * 停止生成
   *
   * ⚠️ 顺序很重要：必须先 abort 本地 SSE（否则事件还会继续灌进来），
   *    再通知服务端停流。
   *    `messageId` 传空串是**故意**的：ChatService.stop 会自动回退到
   *    最近一次从 SSE 首帧记录下来的真实 message_id ——
   *    传空串但内部回退，等价于「一定带对 id」，比调用方猜一个 id 可靠。
   */
  private async stopGeneration(): Promise<void> {
    this.sending = false;
    this.statusText = '已停止';
    this.clearSendWatchdog();
    // 把当前助手消息标记为结束，避免光标一直闪
    const list: ChatMessage[] = this.messages.slice();
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].streaming) {
        this.finishAssistant(list[i].id);
        break;
      }
    }
    await this.chat.stop(AuthService.getToken(), this.sessionId, '');
  }

  /**
   * 新对话
   *
   * 只清本地视图与缓存会话 id，**不删服务端会话** ——
   * 服务端历史仍保留，用户下次可从列表找回（避免误点丢记录）。
   */
  private async newChat(): Promise<void> {
    this.showMenu = false;
    // 正在生成时先停掉，否则 SSE 还会往已清空的列表里灌内容
    if (this.sending) {
      await this.chat.stop(AuthService.getToken(), this.sessionId, '');
      this.sending = false;
    }
    this.messages = [];
    this.sessionId = '';
    this.statusText = '已新建对话';
    this.followTail = true;
    this.ctx.offset = 0;
    this.ctx.contentH = 0;
    this.contentHeight = 0;
    this.scrollOffset = 0;
    await Store.remove(Keys.LAST_SESSION);
  }

  /**
   * 发送看门狗
   *
   * ★ 兜住「sending 永久卡住」这一类现象（用户反馈的「就不能对话了」）：
   *   SSE 层有自己的静默看门狗负责 abort 并报 `stalled`；
   *   但万一连回调都没回来（极端网络下 SDK 不触发任何事件），
   *   这里再兜一层**硬上限**：无论如何在 SEND_HARD_LIMIT_MS 后
   *   强制把 UI 恢复到可再次输入的状态，并给出明确提示。
   *
   *   宁可多提示一次「超时了，请重试」，也不能让用户面对
   *   一个永远转圈、再也点不动发送按钮的界面。
   */
  private sendTimer: number = -1;
  private static readonly SEND_HARD_LIMIT_MS: number = 180000;

  private startSendWatchdog(asstId: string): void {
    this.clearSendWatchdog();
    this.sendTimer = setTimeout(() => {
      if (!this.sending) {
        return;
      }
      this.chat.abortStream();
      this.sending = false;
      this.statusText = '';
      this.updateAssistant(asstId, [
        {
          id: 'r-' + asstId, type: FragmentType.RESPONSE,
          content: '⚠ 等待超时（3 分钟无结果）。请重试，或点「＋」新建对话',
          status: FragStatus.FINISHED
        }
      ]);
      this.finishAssistant(asstId);
    }, ChatPage.SEND_HARD_LIMIT_MS);
  }

  private clearSendWatchdog(): void {
    if (this.sendTimer >= 0) {
      clearTimeout(this.sendTimer);
      this.sendTimer = -1;
    }
  }

  aboutToDisappear(): void {
    // 离开页面：中断流并清理表冠累积
    this.followTail = false;
    Crown.reset();
    if (this.sending) {
      // ★ 必须把 message_id 带上（ChatService.stop 会自动回退到最近一次记录的 id）。
      //   传空串等于没停 —— 服务端那条流会继续跑，下一轮发送就会被排队挂死，
      //   用户看到的现象就是「聊两轮之后它就不能对话了」。
      this.chat.stop(AuthService.getToken(), this.sessionId, '');
      this.sending = false;
    }
    this.clearSendWatchdog();
  }
}
