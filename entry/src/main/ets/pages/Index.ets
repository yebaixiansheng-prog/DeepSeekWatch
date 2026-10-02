/**
 * 应用入口（启动闪屏）
 *
 * ★ 2026-09-30 推倒重来：不再有「登录页 → 聊天页」的流程，
 *   因为官方 API 用内置密钥，开箱即用 → 直接进对话页。
 *
 * ★ 2026-10-03：配色走 Theme 令牌（去掉字面色值），
 *   并把跳转失败兜底成一句话提示 —— 升级前 `router.replaceUrl`
 *   一旦抛异常（路由表没登记本页、页面被系统回收），
 *   用户看到的是**纯黑屏**，完全不知道发生了什么。
 */

import router from '@ohos.router';
import { Typo } from '../common/RoundScreen';
import { Color } from '../common/Theme';

@Entry
@Component
struct Index {
  @State err: string = '';

  aboutToAppear(): void {
    this.go();
  }

  private go(): void {
    try {
      // 直接进对话页（replaceUrl：返回时不该回到这个中间页）
      router.replaceUrl({ url: 'pages/ChatPage' });
    } catch (e) {
      // ★ 兜底：不能让用户对着纯黑屏发呆
      this.err = '启动失败，请重启应用';
      console.error('Index: replaceUrl 失败 e=' + JSON.stringify(e));
    }
  }

  build() {
    Column() {
      Text('DeepSeek')
        .fontSize(Typo.display)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.text)
      Text('手表版')
        .fontSize(Typo.caption)
        .fontColor(Color.primary)
        .margin({ top: 2 })
      if (this.err.length > 0) {
        Text(this.err)
          .fontSize(Typo.caption - 1)
          .fontColor(Color.danger)
          .margin({ top: 8 })
          .onClick(() => this.go())
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.bg)
    .borderRadius('50%')
    .clip(true)
  }
}
