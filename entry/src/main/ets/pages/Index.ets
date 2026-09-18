import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { AuthService, DsUser } from '../model/AuthService';
import { Typo, Round } from '../common/RoundScreen';
import { Store } from '../common/Store';
import { RoundButton } from '../components/RoundWidgets';

/**
 * 入口页
 *
 * 职责：
 *   1. 判断登录态 → 分流到登录页或对话页
 *   2. 作为全局表冠事件的分发入口
 *
 * ⚠️ 表冠事件说明（重要，交付给打包方）：
 *   HarmonyOS 手表的旋转表冠使用 **onDigitalCrown** 事件（API 18+，仅 Wearable 支持）：
 *     .focusable(true).defaultFocus(true).focusOnTouch(true)
 *     .onDigitalCrown((event: CrownEvent) => { ... })
 *   CrownEvent 关键字段：
 *     - degree         相对旋转角度 [-360, 360]，正=顺时针
 *     - angularVelocity 旋转角速度（度/秒）
 *     - action         表冠动作（BEGIN / UPDATE / END）
 *
 *   本应用各页面（LoginPage / ChatPage）暴露 handleCrown(degree) 方法，
 *   已在页面 build() 中通过 .onDigitalCrown 接入。
 *   若打包目标机型 API 版本低于 18，请在打包时降级为 sensor 方案，
 *   仅需把角度值喂给 handleCrown 即可，业务逻辑无需改动。
 */
@Entry
@Component
struct Index {
  @State checked: boolean = false;
  @State loggedIn: boolean = false;
  /** 本地存储不可用（Preferences 初始化失败）—— 与「未登录」是两回事 */
  @State storageFailed: boolean = false;
  /** 退出登录二次确认浮层 */
  @State confirmLogout: boolean = false;

  aboutToAppear(): void {
    this.checkAuth();
  }

  private async checkAuth(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    const ok: boolean = await AuthService.restore();
    // ★ 存储读不出来时绝不能显示登录页：
    //   token 其实还在磁盘上，把用户引导去重新输密码是纯粹的伤害。
    //   这里单独标出来，UI 给「重试」而不是「登录」。
    //
    //   ⚠️ 两个来源都要覆盖：
    //     ① Store 整体没就绪（isReady()=false）
    //     ② Store 就绪了但 **这一次读 token 失败**（isRestoreFailed()）
    //   第 ② 种更隐蔽 —— 存储初看起来正常，只是某次读抛了异常，
    //   旧代码会拿到空串并当成「未登录」。
    this.storageFailed = !Store.isReady() || AuthService.isRestoreFailed();
    this.loggedIn = ok;
    this.checked = true;
  }

  build() {
    Stack() {
      if (!this.checked) {
        // 启动检查态
        Column() {
          Text('DeepSeek')
            .fontSize(Typo.display)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E8EAED')
          Text('DeepSeek 手表版')
            .fontSize(Typo.caption)
            .fontColor('#5A5F6B')
            .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.storageFailed) {
        this.StorageErrorView()
      } else if (this.loggedIn) {
        this.HomeView()
      } else {
        this.LoginEntry()
      }

      if (this.confirmLogout) {
        this.ConfirmLogoutOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .borderRadius('50%')
    .clip(true)
  }

  /** 本地存储初始化失败：给重试入口，不要误报成「未登录」 */
  @Builder
  StorageErrorView() {
    Column({ space: 10 }) {
      Text('⚠')
        .fontSize(26)
        .fontColor('#E5A24D')
      Text('本地数据读取失败')
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
      Text('登录状态可能仍然有效')
        .fontSize(Typo.caption - 1)
        .fontColor('#6E7380')
      RoundButton({
        label: '重试',
        primary: true,
        widthRatio: 0.6,
        onTap: () => {
          this.checked = false;
          this.checkAuth();
        }
      })
        .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 退出登录确认浮层
   *
   * ⚠️ 必须要有：手表屏幕小、按钮密集，很容易误触。
   *    一旦误触就要用表盘上那个极难用的键盘重新输账号密码 ——
   *    这是本页风险最高的操作，不能一步执行。
   */
  @Builder
  ConfirmLogoutOverlay() {
    Column({ space: 8 }) {
      Text('退出登录？')
        .fontSize(Typo.body)
        .fontColor('#E8EAED')
      Text('需重新输入账号密码')
        .fontSize(Typo.caption - 1)
        .fontColor('#6E7380')
        .margin({ bottom: 6 })

      RoundButton({
        label: '确定退出',
        primary: true,
        widthRatio: 0.62,
        onTap: () => {
          this.doLogout();
        }
      })
      RoundButton({
        label: '取消',
        primary: false,
        widthRatio: 0.62,
        onTap: () => {
          this.confirmLogout = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#E6000000')
  }
  @Builder
  LoginEntry() {
    Column() {
      Text('DeepSeek')
        .fontSize(Typo.display)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E8EAED')
      Text('手表版')
        .fontSize(Typo.caption)
        .fontColor('#4D6BFE')
        .margin({ top: 4 })

      RoundButton({
        label: '登录',
        primary: true,
        onTap: () => {
          router.pushUrl({ url: 'pages/LoginPage' });
        }
      })
        .margin({ top: 26 })

      Text('使用 DeepSeek 账号密码登录')
        .fontSize(Typo.caption - 1)
        .fontColor('#5A5F6B')
        .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  HomeView() {
    Column() {
      Text('DeepSeek')
        .fontSize(Typo.title)
        .fontColor('#E8EAED')
      // 显示当前账号，让用户知道登录的是哪个号（手表上很容易搞混）
      Text(this.accountLabel())
        .fontSize(Typo.caption - 1)
        .fontColor('#5A5F6B')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(Round.wPct(Round.safeRadius * 1.2))
        .textAlign(TextAlign.Center)
        .margin({ top: 4, bottom: 18 })

      RoundButton({
        label: '开始对话',
        primary: true,
        onTap: () => {
          router.pushUrl({ url: 'pages/ChatPage' });
        }
      })

      RoundButton({
        label: '退出登录',
        primary: false,
        onTap: () => {
          // 不直接退出：先弹确认（见 ConfirmLogoutOverlay 注释）
          this.confirmLogout = true;
        }
      })
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 脱敏账号展示 */
  private accountLabel(): string {
    const u: DsUser | null = AuthService.getUser();
    if (u === null) {
      return '已登录';
    }
    if (u.mobile.length >= 11) {
      return u.mobile.substring(0, 3) + '****' + u.mobile.substring(7);
    }
    if (u.email.length > 0) {
      return u.email;
    }
    return '已登录';
  }

  /**
   * 退出登录
   *
   * 先本地清态再通知服务端：手表网络不稳，
   * 若等接口返回再清，用户可能卡在「点了没反应」。
   */
  private async doLogout(): Promise<void> {
    this.confirmLogout = false;
    await AuthService.logout();
    this.loggedIn = false;
    promptAction.showToast({ message: '已退出登录', duration: 1500 });
  }

  /**
   * 返回键：浮层打开时先关浮层，而不是直接退出应用
   * @returns true 表示已消费该事件
   */
  onBackPress(): boolean {
    if (this.confirmLogout) {
      this.confirmLogout = false;
      return true;
    }
    return false;
  }
}
