import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, FontScale, Round } from '../common/RoundScreen';
import { AuthService, LoginResult } from '../model/AuthService';
import { Store, Keys } from '../common/Store';
import { Crown } from '../common/Crown';
import { RoundButton } from '../components/RoundWidgets';

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

  private accountInput: TextInputController = new TextInputController();
  private passwordInput: TextInputController = new TextInputController();

  aboutToAppear(): void {
    this.loadFontScale();
  }

  aboutToDisappear(): void {
    // 离开页面时清理表冠累积，避免回来后第一步"跳变"
    Crown.reset();
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
          .margin({ top: 22 })
        } else {
          // 输入态：极简标题，最大限度让出竖向空间给表单
          Text('登录')
            .fontSize(Typo.caption - 2)
            .fontColor('#6E7380')
            .margin({ top: 2 })
        }

        // ---------- 表单 ----------
        this.FormView()

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
        promptAction.showToast({ message: '登录成功', duration: 1500 });
        // ⚠️ 不能只 replaceUrl：初始栈是 [Index]，LoginPage 压上来后是 [Index, LoginPage]，
        //    replaceUrl(Index) 会把 LoginPage 换成**新的** Index，栈变成 [Index, Index]。
        //    此时用户按返回会退回到那个旧 Index 实例 —— 它的 loggedIn 还是 false，
        //    于是刚登录完又看到登录页，只能再登一次（栈还会越滚越长）。
        //    先 clear()（只留当前页）再 replaceUrl，保证栈里只有一个 Index。
        router.clear();
        router.replaceUrl({ url: 'pages/Index' });
      } else {
        this.errMsg = r.message;
      }
    } catch (e) {
      this.errMsg = '登录异常，请重试';
    }
    this.loading = false;
  }
}
