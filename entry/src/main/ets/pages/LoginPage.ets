import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, FontScale, Round } from '../common/RoundScreen';
import { AuthService, LoginResult, DsUser } from '../model/AuthService';
import { QrLoginService, QrStartResult, QrPollCallbacks } from '../model/QrLoginService';
import { Store, Keys } from '../common/Store';
import { Crown } from '../common/Crown';
import { RoundButton } from '../components/RoundWidgets';

/** 登录方式 */
export enum LoginMode {
  PASSWORD = 0,
  WECHAT = 1
}

/**
 * 登录页（圆形表盘定制）
 *
 * 设计决策（v2，2026-09-12 改版）：
 *   - **输入一律使用系统官方输入法**：账号/密码框均为真正的 TextInput 组件，
 *     点击后由系统拉起手表自带输入法（支持中文、邮箱符号、长按粘贴）。
 *     旧版自绘键盘（仅字母数字、无中文、圆屏易溢出）已彻底移除。
 *   - 圆形屏不做并排输入框，改为「点字段 → 拉起输入法」的直连交互。
 *   - 密码框用 showPasswordIcon=false 且不显示明文。
 *   - 表冠旋转 = 调节字号（圆形屏可读性适配）。
 *
 * 设计决策（v3，2026-09-19）：**新增「微信扫码登录」**
 *   - 顶部两个分段：**密码登录** / **微信扫码**，两者并存可随时切换。
 *   - 微信扫码**不显示二维码**（圆屏扫不动 + 微信 OAuth 要求浏览器环境，
 *     实测直接抓 `qrconnect` 必被拒，详见 docs/微信扫码登录_设计与可行性.md 第 3 节）。
 *     改为显示**大号配对码**：用户在手机浏览器上完成微信扫码，手表拿到 token。
 *   - 密码登录的全部实现**原样保留**（Bug 15 的风控字段拼装不可动）。
 *
 * ⚠️ 圆屏输入法遮挡说明：
 *   官方输入法在圆形表盘上会占据约下半屏。为让字段不被遮挡，
 *   输入态下（keyboardOn=true）表单整体上移到安全圆上半部，
 *   并把标题压缩，保证 TextInput 始终可见。
 */
@Entry
@Component
struct LoginPage {
  @State account: string = '';
  @State password: string = '';
  @State loading: boolean = false;
  @State errMsg: string = '';
  @State fontScale: number = FontScale.STANDARD;

  /** 输入法是否已拉起（用于动态上移表单，避免被输入法遮挡） */
  @State keyboardOn: boolean = false;

  // ---------- 微信扫码相关状态 ----------
  /** 当前登录方式 */
  @State mode: LoginMode = LoginMode.PASSWORD;
  /** 扫码会话是否已建立（true 才显示配对码） */
  @State qrReady: boolean = false;
  /** 配对码（大号展示） */
  @State qrCode: string = '';
  /** 手机侧要打开的地址 */
  @State qrUrl: string = '';
  /** 扫码状态文案（常驻显示，绝不隐藏 —— Bug 17 的教训） */
  @State qrStatus: string = '';
  /** 是否已扫码待确认 */
  @State qrScanned: boolean = false;
  /** 二维码是否已过期（显示刷新入口） */
  @State qrExpired: boolean = false;

  private accountInput: TextInputController = new TextInputController();
  private passwordInput: TextInputController = new TextInputController();
  private qr: QrLoginService = new QrLoginService();

  aboutToAppear(): void {
    this.loadFontScale();
  }

  aboutToDisappear(): void {
    // 离开页面时清理表冠累积，避免回来后第一步"跳变"
    Crown.reset();
    // ★ 必须停掉扫码轮询：否则离开页面后回调仍会触发（本项目的定时器纪律）
    this.qr.stop();
  }

  private async loadFontScale(): Promise<void> {
    const v: string = await Store.get(Keys.FONT_SCALE, '1');
    this.fontScale = parseInt(v);
    Typo.scale = this.fontScale;
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        // 品牌区（输入态下压缩为极简标题，给输入法让出空间）
        if (!this.keyboardOn) {
          Column() {
            Text('DeepSeek')
              // 圆屏高度紧张：品牌字号降一档，避免挤压下方表单
              .fontSize(Typo.title + 3)
              .fontWeight(FontWeight.Bold)
              .fontColor('#E8EAED')
            Text('登录')
              .fontSize(Typo.caption - 1)
              .fontColor('#6E7380')
              .margin({ top: 1 })
          }
          .margin({ top: this.mode === LoginMode.WECHAT ? 6 : 22 })
        } else {
          // 输入态：极简标题，最大限度让出竖向空间给表单
          Text('登录')
            .fontSize(Typo.caption - 2)
            .fontColor('#6E7380')
            .margin({ top: 2 })
        }

        // ---------- 登录方式切换（密码 / 微信扫码）----------
        // 输入法拉起时隐藏，避免和输入法抢竖向空间
        if (!this.keyboardOn) {
          this.ModeTabs()
        }

        // ---------- 表单 ----------
        if (this.mode === LoginMode.PASSWORD) {
          this.FormView()
        } else {
          this.WechatView()
        }

        // 未拉起输入法时才显示辅助提示（避免和输入法抢占竖向空间）
        // 圆屏底部会被裁切 → 提示整体上提，避免贴着下沿
        if (!this.keyboardOn) {
          Text('表冠调节字号 · ' + this.fontLabel())
            .fontSize(Typo.caption - 2)
            .fontColor('#5A5F6B')
            .margin({ top: 2 })
        }
      }
      .width('100%')
      // ★ 关键：输入态下表单从顶部排列，避免被全屏输入法顶掉。
      //   非输入态下压缩为 92% 高度，让登录按钮离圆屏下沿远一点（不被视觉裁切）。
      .height(this.keyboardOn ? '52%' : '92%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      // 圆屏：整体内容压进安全圆（上下各让出约 40vp），避免两端被裁
      .padding({ top: this.keyboardOn ? 2 : 8, bottom: this.keyboardOn ? 0 : 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 圆形屏最外层处理
    .borderRadius('50%')
    .clip(true)
    // ★ 表冠旋转 → 调节字号（圆形屏可读性适配）
    //   onDigitalCrown：API 18+，仅 Wearable 支持，需组件获焦
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      // 输入法弹出时表冠交给输入法处理（光标移动），不抢事件
      if (this.keyboardOn) {
        return;
      }
      this.handleCrown(event.degree);
    })
  }

  /**
   * 登录方式切换分段
   *
   * 圆屏空间紧张 → 做成一个紧凑的双段控件，不做大按钮。
   * ⚠️ 切换时必须清掉 errMsg，否则上一种方式的报错会「串台」到另一种。
   */
  @Builder
  ModeTabs() {
    Row() {
      this.ModeTab('密码登录', LoginMode.PASSWORD)
      this.ModeTab('微信扫码', LoginMode.WECHAT)
    }
    .width('78%')
    .height(26)
    .backgroundColor('#12141A')
    .borderRadius(13)
    .padding(2)
    .margin({ top: 4, bottom: 2 })
  }

  @Builder
  ModeTab(label: string, m: LoginMode) {
    Text(label)
      .fontSize(Typo.caption - 1)
      .fontColor(this.mode === m ? '#FFFFFF' : '#6E7380')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height('100%')
      .borderRadius(11)
      .backgroundColor(this.mode === m ? '#4D6BFE' : Color.Transparent)
      .onClick(() => {
        this.switchMode(m);
      })
  }

  /** 切换登录方式 */
  private switchMode(m: LoginMode): void {
    if (this.mode === m) {
      return;
    }
    this.errMsg = '';
    // 离开扫码页 → 停掉轮询，避免后台空转耗电（手表尤其在意省电）
    this.qr.stop();
    this.mode = m;
    if (m === LoginMode.PASSWORD) {
      // 回到密码登录：清掉扫码的临时状态
      this.qrReady = false;
      this.qrScanned = false;
      this.qrExpired = false;
      this.qrStatus = '';
      this.qrCode = '';
      this.qrUrl = '';
    } else {
      this.qrScanned = false;
      this.qrExpired = false;
      // ★ 中继未部署时**不要**去发注定失败的请求：
      //   直接落到「暂不可用」分支并说明原因，用户不会白等一圈网络超时。
      if (!QrLoginService.isConfigured()) {
        this.qrReady = false;
        this.qrStatus = '';
        this.beginQrLogin();
      } else {
        this.qrStatus = '正在获取配对码…';
        this.beginQrLogin();
      }
    }
  }

  // ========================================================================
  //   微信扫码登录视图
  // ========================================================================

  /**
   * 微信扫码登录视图
   *
   * ★ 为什么显示「配对码」而不是二维码：
   *   1. 圆屏扫二维码体验极差（反光 / 曲率 / 需手机对准手表小屏）；
   *   2. 更根本的是**技术上拿不到二维码** —— 微信 OAuth 的二维码由
   *      `open.weixin.qq.com` 在 iframe 内渲染，且该页拒绝非浏览器来源
   *      （实测恒返回 892 字节错误页 qqBS_a089916-0）。
   *      详见 docs/微信扫码登录_设计与可行性.md 第 3 节。
   *   3. 手表最擅长显示**大号数字**，配对码正合适。
   */
  @Builder
  WechatView() {
    Column({ space: 4 }) {
      if (this.loading) {
        // 建立会话中
        Text('正在获取配对码…')
          .fontSize(Typo.body)
          .fontColor('#9AA0AC')
          .margin({ top: 10 })
      } else if (this.qrExpired) {
        // 已过期：给明确的刷新入口，不停在死界面
        Text('配对码已过期')
          .fontSize(Typo.body)
          .fontColor('#FFB454')
          .margin({ top: 8 })
        Text('请重新获取后再扫码')
          .fontSize(Typo.caption - 1)
          .fontColor('#6E7380')
        RoundButton({
          label: '重新获取',
          primary: true,
          enabledState: true,
          onTap: () => {
            this.beginQrLogin();
          }
        })
          .margin({ top: 2 })
      } else if (this.qrReady) {
        // ---------- 配对码（核心信息，超大字号）----------
        Text('此配对码')
          .fontSize(Typo.caption - 2)
          .fontColor('#5A5F6B')
        Text(this.qrCode)
          // ★ 圆屏空间紧张：字号取 title+2，并限制单行，
          //   避免换行把下方状态行顶出屏幕
          .fontSize(Typo.title + 2)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4D6BFE')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // ---------- 手机侧地址 ----------
        Text('在手机浏览器打开')
          .fontSize(Typo.caption - 2)
          .fontColor('#5A5F6B')
          .margin({ top: 2 })
        Text(this.qrUrl.length > 0 ? this.qrUrl : '（地址未配置）')
          .fontSize(Typo.caption - 2)
          .fontColor('#9AA0AC')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('86%')
          .textAlign(TextAlign.Center)

        // ---------- 状态行（★ 常驻，绝不隐藏）----------
        Text(this.qrStatus)
          .fontSize(Typo.caption - 1)
          .fontColor(this.qrScanned ? '#3DDC84' : '#9AA0AC')
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .width('86%')
          .margin({ top: 4 })
      } else {
        // ---------- 不可用分支 ----------
        // 未配置中继 → 说清是「服务端未部署」，不要含糊成「暂不可用」，
        // 否则用户会反复重试（而重试永远不会成功）。
        Text(QrLoginService.isConfigured() ? '微信登录暂不可用' : '微信扫码登录尚未开放')
          .fontSize(Typo.body)
          .fontColor('#9AA0AC')
          .margin({ top: 8 })
        Text(QrLoginService.isConfigured() ? '可改用密码登录' : '该功能需服务端支持')
          .fontSize(Typo.caption - 1)
          .fontColor('#6E7380')
        if (!QrLoginService.isConfigured()) {
          Text('当前请使用密码登录')
            .fontSize(Typo.caption - 1)
            .fontColor('#6E7380')
        }
        RoundButton({
          // ★ 未配置时「重试」无意义 → 改成引导回密码登录，避免用户空点
          label: QrLoginService.isConfigured() ? '重试' : '去密码登录',
          primary: true,
          enabledState: true,
          onTap: () => {
            if (QrLoginService.isConfigured()) {
              this.beginQrLogin();
            } else {
              this.switchMode(LoginMode.PASSWORD);
            }
          }
        })
          .margin({ top: 2 })
      }

      // ---------- 错误提示（复用与密码登录同一样式）----------
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(Typo.caption)
          .fontColor('#FF6B6B')
          .textAlign(TextAlign.Center)
          .width('82%')
          .maxLines(2)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 2 })
  }

  /**
   * 开始微信扫码登录（建立会话 + 启动轮询）
   *
   * ★ 纪律：任何网络操作都必须有失败出口。
   *   这里的三条出口 —— start 失败 / 轮询过期 / 轮询出错 ——
   *   都会落到一个**明确的 UI 状态**，绝不出现「永久转圈」。
   */
  private async beginQrLogin(): Promise<void> {
    this.loading = true;
    this.errMsg = '';
    this.qrExpired = false;
    this.qrScanned = false;
    this.qrReady = false;
    // ★ 未配置时不要显示「正在获取配对码…」（那会转一下才失败，属于误导）
    this.qrStatus = QrLoginService.isConfigured() ? '正在获取配对码…' : '';

    let r: QrStartResult;
    try {
      r = await this.qr.start();
    } catch (e) {
      this.loading = false;
      this.qrStatus = '';
      this.errMsg = '微信登录初始化失败，请重试';
      return;
    }
    this.loading = false;

    if (!r.ok) {
      // 中继未配置 / 网络不可达 → 明确提示并引导回密码登录
      this.qrStatus = '';
      this.errMsg = r.message;
      return;
    }

    this.qrCode = r.userCode;
    this.qrUrl = r.verifyUrl;
    this.qrReady = true;
    this.qrStatus = '等待扫码…';

    const cb: QrPollCallbacks = {
      onScanned: () => {
        this.qrScanned = true;
        this.qrStatus = '已扫码，请在手机上确认';
      },
      onSuccess: (token: string, user: DsUser | null) => {
        this.loading = false;
        this.qrStatus = '登录成功';
        this.finishLogin(token, user);
      },
      onExpired: () => {
        this.loading = false;
        this.qrExpired = true;
        this.qrReady = false;
        this.qrStatus = '';
      },
      onNetworkRetry: (attempt: number, nextSec: number) => {
        this.qrStatus = '网络不稳定，' + nextSec.toString() + ' 秒后重试（第 '
          + attempt.toString() + ' 次）';
      },
      onError: (msg: string) => {
        this.loading = false;
        this.qrStatus = '';
        this.qrReady = false;
        this.errMsg = msg;
      }
    };
    this.qr.startPolling(cb);
  }

  // ========================================================================
  //   密码登录视图（原样保留，勿动风控相关逻辑）
  // ========================================================================

  @Builder
  FormView() {
    // 圆屏竖向空间紧张：整体收紧间距，保证两个输入框 + 按钮都在安全圆内
    Column({ space: 3 }) {
      // ---------- 账号 ----------
      Text('账号')
        .fontSize(Typo.caption - 1)
        .fontColor('#6E7380')
        .width('84%')
        .textAlign(TextAlign.Start)

      // ★ 官方输入法：真正的系统 TextInput
      //   注意：controller 必须写在构造参数对象里，不能链式 .controller()
      TextInput({ text: this.account, placeholder: '手机号 / 邮箱', controller: this.accountInput })
        .type(InputType.Normal)
        // focusControl.requestFocus 需要控件有 id
        .id('accountField')
        // 账号可能是手机号，也可能是邮箱 → 允许数字与字母混合
        .enterKeyType(EnterKeyType.Next)
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
        .placeholderColor('#5A5F6B')
        .backgroundColor('#12141A')
        .borderRadius(12)
        .height(42)
        .width('84%')
        .padding({ left: 12, right: 12 })
        .caretColor('#4D6BFE')
        .selectedBackgroundColor('#2A3350')
        // 键盘弹出/收起 → 动态让位
        .onFocus(() => {
          this.keyboardOn = true;
        })
        .onBlur(() => {
          this.keyboardOn = false;
        })
        .onChange((v: string) => {
          this.account = v;
          if (this.errMsg.length > 0) {
            this.errMsg = '';
          }
        })
        .onSubmit(() => {
          // 回车 → 跳到密码框（用 focusControl + id 定位）
          focusControl.requestFocus('passwordField');
        })

      // ---------- 密码 ----------
      Text('密码')
        .fontSize(Typo.caption - 1)
        .fontColor('#6E7380')
        .width('84%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2 })

      TextInput({ text: this.password, placeholder: '请输入密码', controller: this.passwordInput })
        // ★ 关键：Password 类型让系统输入法按密码模式处理，
        //   且控件自己负责掩码显示
        .type(InputType.Password)
        .id('passwordField')
        .enterKeyType(EnterKeyType.Done)
        .showPasswordIcon(false)
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
        .placeholderColor('#5A5F6B')
        .backgroundColor('#12141A')
        .borderRadius(12)
        .height(42)
        .width('84%')
        .padding({ left: 12, right: 12 })
        .caretColor('#4D6BFE')
        .selectedBackgroundColor('#2A3350')
        .onFocus(() => {
          this.keyboardOn = true;
        })
        .onBlur(() => {
          this.keyboardOn = false;
        })
        .onChange((v: string) => {
          this.password = v;
          if (this.errMsg.length > 0) {
            this.errMsg = '';
          }
        })
        .onSubmit(() => {
          this.doLogin();
        })

      // ---------- 错误提示 ----------
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(Typo.caption)
          .fontColor('#FF6B6B')
          .textAlign(TextAlign.Center)
          .width('82%')
          .maxLines(2)
          .margin({ top: 2 })
      }

      // ---------- 登录按钮 ----------
      // 输入法弹出时按钮可能被遮，仍保留（收起输入法即可点到）
      RoundButton({
        label: this.loading ? '登录中…' : '登 录',
        primary: true,
        enabledState: !this.loading && this.account.length > 0 && this.password.length > 0,
        onTap: () => {
          this.doLogin();
        }
      })
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: this.keyboardOn ? 0 : 4 })
  }

  private fontLabel(): string {
    if (this.fontScale === FontScale.SMALL) {
      return '小';
    }
    if (this.fontScale === FontScale.LARGE) {
      return '大';
    }
    return '标准';
  }

  /** 表冠旋转：调字号（顺时针放大，逆时针缩小） */
  handleCrown(raw: number): void {
    const steps: number = Crown.normalize(raw);
    if (steps === 0) {
      return;
    }
    const next: number = this.fontScale + (steps > 0 ? 1 : -1);
    const v: number = Math.max(FontScale.SMALL, Math.min(FontScale.LARGE, next));
    if (v !== this.fontScale) {
      this.fontScale = v;
      Typo.scale = v;
      Store.put(Keys.FONT_SCALE, v.toString());
      Crown.reset(); // 档位变化后清零头，避免连续跨越
    }
  }

  /** 执行登录 */
  private async doLogin(): Promise<void> {
    if (this.loading || this.account.length === 0 || this.password.length === 0) {
      return;
    }
    // 收起输入法，避免登录过程中的界面被遮挡
    this.keyboardOn = false;
    this.accountInput.stopEditing();
    this.passwordInput.stopEditing();

    this.loading = true;
    this.errMsg = '';
    try {
      const r: LoginResult = await AuthService.login(this.account, this.password);
      if (r.ok) {
        this.finishLogin(AuthService.getToken(), r.user);
      } else {
        this.errMsg = r.message;
      }
    } catch (e) {
      this.errMsg = '登录异常，请重试';
    }
    this.loading = false;
  }

  /**
   * 登录成功后的统一收尾（★ 密码登录与微信扫码登录**共用**）
   *
   * 为什么必须共用（而不是各写一份）：
   *   登录成功后的跳转顺序是踩过坑的（Bug 12）——
   *   不能只 replaceUrl：初始栈是 [Index]，LoginPage 压上来后是 [Index, LoginPage]，
   *   replaceUrl(Index) 会把 LoginPage 换成**新的** Index，栈变成 [Index, Index]。
   *   此时用户按返回会退回到那个旧 Index 实例 —— 它的 loggedIn 还是 false，
   *   于是刚登录完又看到登录页，只能再登一次（栈还会越滚越长）。
   *   先 clear()（只留当前页）再 replaceUrl，保证栈里只有一个 Index。
   *
   *   两种登录方式走同一段代码，才能保证这个顺序不会被漏改。
   */
  private finishLogin(token: string, user: DsUser | null): void {
    // 扫码路径：token 由轮询回调给出，需要落盘（走 AuthService 的统一出口）
    if (!AuthService.isLoggedIn() && token.length > 0) {
      AuthService.adoptToken(token, user);
    }
    // 离页前务必停掉轮询（否则回调仍会触发）
    this.qr.stop();
    promptAction.showToast({ message: '登录成功', duration: 1500 });
    router.clear();
    router.replaceUrl({ url: 'pages/Index' });
  }
}
