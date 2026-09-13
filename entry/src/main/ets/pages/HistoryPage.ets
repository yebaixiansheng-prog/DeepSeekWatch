import router from '@ohos.router';
import { Typo, Round } from '../common/RoundScreen';
import { AuthService } from '../model/AuthService';
import { ChatService, SessionInfo, SessionListResult } from '../model/ChatService';
import { Nav } from '../common/Nav';

/** 相对时间文案（手表上不展示完整时间戳，太长） */
function relTimeText(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const diff: number = Date.now() - ms;
  const MIN: number = 60000;
  const HOUR: number = 3600000;
  const DAY: number = 86400000;
  if (diff < MIN) {
    return '刚刚';
  }
  if (diff < HOUR) {
    return Math.floor(diff / MIN).toString() + ' 分钟前';
  }
  if (diff < DAY) {
    return Math.floor(diff / HOUR).toString() + ' 小时前';
  }
  if (diff < DAY * 2) {
    return '昨天';
  }
  if (diff < DAY * 7) {
    return Math.floor(diff / DAY).toString() + ' 天前';
  }
  const d: Date = new Date(ms);
  return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
}

/**
 * 历史对话列表页（圆形表盘定制）
 *
 * 入口：对话页右上角 `≡`
 * 数据：ChatService.listSessions() → GET /api/v0/chat_session/fetch_page
 *
 * 交互：
 *   - 点击某条会话 → Nav.selectSession(id) + router.back()，由对话页接管切换
 *   - 底部「新对话」→ Nav.selectNewChat() + router.back()
 *   - 右上角 ⟳ 刷新
 *   - 表冠旋转 = 滚动列表（List 组件原生支持，这里只补焦点）
 *
 * 圆形屏适配：列表项宽度按「列表区最窄处」的内接圆弦长取 86%，
 * 保证贴圆弧的首尾两行也不会被裁掉。
 */
@Entry
@Component
struct HistoryPage {
  @State sessions: SessionInfo[] = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  /** 失败原因是「token 失效」——此时给「重新登录」而不是「重试」 */
  @State needRelogin: boolean = false;

  aboutToAppear(): void {
    // 首次加载放在 onPageShow（页面可见即拉一次），
    // 这里不重复请求，避免进页面就打两次接口。
  }

  onPageShow(): void {
    // 每次页面可见都刷新：既覆盖首次进入，也覆盖「从对话页返回」的场景
    this.refresh();
  }

  private async refresh(): Promise<void> {
    this.errorText = '';
    this.needRelogin = false;
    this.loading = true;
    const r: SessionListResult = await ChatService.listSessions(AuthService.getToken(), 50);
    this.sessions = r.sessions;
    this.loading = false;
    // 失败（网络/未登录/格式异常）与「确实没有会话」要区分开，
    // 否则用户会以为自己从来没有聊过。
    this.errorText = r.ok ? '' : r.message;
    this.needRelogin = r.ok ? false : (r.needRelogin === true);
  }

  build() {
    Stack() {
      Column() {
        this.TopBar()

        if (this.loading && this.sessions.length === 0) {
          this.HintBlock('正在加载…', '#5A5F6B')
        } else if (this.sessions.length === 0 && this.errorText.length > 0) {
          this.ErrorBlock()
        } else if (this.sessions.length === 0) {
          this.EmptyBlock()
        } else {
          this.SessionList()
        }

        this.BottomBar()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 圆形屏：裁成内切圆，四角内容不溢出到表壳
    .borderRadius('50%')
    .clip(true)
  }

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(22)
        .fontColor('#C8CCD4')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })

      Column() {
        Text('历史对话')
          .fontSize(Typo.body)
          .fontColor('#E8EAED')
          .fontWeight(FontWeight.Medium)
        Text(this.sessions.length > 0 ? (this.sessions.length.toString() + ' 个会话') : '')
          .fontSize(Typo.caption - 1)
          .fontColor('#5A5F6B')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Text('⟳')
        .fontSize(18)
        .fontColor('#C8CCD4')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.refresh();
        })
    }
    .width(Round.wPct(Round.widthAtY(-Round.safeRadius * 0.62)))
    .height(40)
    .margin({ top: Round.topInset + 4 })
  }

  @Builder
  HintBlock(text: string, color: string) {
    Column() {
      Text(text)
        .fontSize(Typo.body)
        .fontColor(color)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyBlock() {
    Column({ space: 8 }) {
      Text('🗂')
        .fontSize(30)
        .fontColor('#2A2E3A')
      Text('暂无历史对话')
        .fontSize(Typo.body)
        .fontColor('#8A8F9A')
      Text('点下方「新对话」开始')
        .fontSize(Typo.caption)
        .fontColor('#5A5F6B')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 加载失败（网络 / 未登录 / 格式异常）—— 给出原因 + 重试入口 */
  @Builder
  ErrorBlock() {
    Column({ space: 10 }) {
      Text('⚠')
        .fontSize(26)
        .fontColor('#E5A24D')
      Text(this.errorText)
        .fontSize(Typo.caption)
        .fontColor('#8A8F9A')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width(Round.wPct(Round.widthAtY(0) * 0.7))
      Button(this.needRelogin ? '重新登录' : '重试')
        .type(ButtonType.Capsule)
        .width(96)
        .height(36)
        .fontSize(Typo.caption)
        .fontColor('#FFFFFF')
        .backgroundColor('#4D6BFE')
        .onClick(() => {
          if (this.needRelogin) {
            this.goRelogin();
          } else {
            this.refresh();
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * token 已失效：清掉本地登录态并回到入口页
   *
   * 先 clear()（只留当前页）再 replaceUrl，
   * 这样入口页会**重新构造**并重跑 aboutToAppear→checkAuth，
   * 从而正确显示登录界面（否则旧实例的 loggedIn 还是 true，会卡住），
   * 同时保证路由栈里只有一个入口页。
   */
  private async goRelogin(): Promise<void> {
    await AuthService.logout();
    Nav.selectNewChat();
    router.clear();
    router.replaceUrl({ url: 'pages/Index' });
  }

  @Builder
  SessionList() {
    List({ space: 6 }) {
      ForEach(this.sessions, (s: SessionInfo) => {
        ListItem() {
          this.SessionRow(s)
        }
      }, (s: SessionInfo) => s.id)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .scrollBar(BarState.Off)
    // 表冠：List 原生支持滚动，补上焦点条件即可
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
  }

  @Builder
  SessionRow(s: SessionInfo) {
    Column({ space: 1 }) {
      Row() {
        if (s.pinned) {
          Text('置顶')
            .fontSize(Typo.caption - 2)
            .fontColor('#4D6BFE')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor('#1A2340')
            .margin({ right: 5 })
        }
        // 圆形屏列表区很矮（466 屏上约 150~300px），标题只给一行，
        // 否则单条就占 90px+，一屏只看得见一条半。
        Text(s.title)
          .fontSize(Typo.body)
          .fontColor('#E8EAED')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      Text(relTimeText(s.updatedAt))
        .fontSize(Typo.caption - 1)
        .fontColor('#6E7380')
    }
    .width('86%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor('#12141A')
    .onClick(() => {
      this.openSession(s.id);
    })
  }

  @Builder
  BottomBar() {
    Button('＋ 新对话')
      .type(ButtonType.Capsule)
      // 该行可用宽度约 256px，「＋ 新对话」5 个字在 14fp 下约 140px，留足余量
      .width(Round.wPct(Round.widthAtY(Round.safeRadius * 0.78) * 0.78))
      .height(38)
      .fontSize(Typo.body)
      .fontColor('#FFFFFF')
      .backgroundColor('#4D6BFE')
      .margin({ bottom: Round.topInset + 6 })
      .onClick(() => {
        this.newChat();
      })
  }

  /** 选中一个历史会话：写入导航意图后返回对话页 */
  private openSession(id: string): void {
    Nav.selectSession(id);
    this.goBackToChat();
  }

  /** 新建对话：同样写导航意图（空 id 代表新对话） */
  private newChat(): void {
    Nav.selectNewChat();
    this.goBackToChat();
  }

  /**
   * 返回对话页
   *
   * 正常情况下本页是从对话页 push 进来的，`router.back()` 即可；
   * 若本页是栈底（异常路径），则直接 push 一个对话页，避免「点了没反应」。
   */
  private goBackToChat(): void {
    // ⚠️ router.getLength() 返回的是**字符串**（页数），必须转成数字再比较
    const depth: number = parseInt(router.getLength());
    if (!isNaN(depth) && depth > 1) {
      router.back();
    } else {
      router.pushUrl({ url: 'pages/ChatPage' });
    }
  }
}
