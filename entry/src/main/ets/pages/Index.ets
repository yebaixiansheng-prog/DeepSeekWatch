/**
 * 应用入口
 *
 * ★ 2026-09-30 推倒重来：不再有「登录页 → 聊天页」的流程，
 *   因为官方 API 用内置密钥，开箱即用。
 *   直接进对话页。
 */
import router from '@ohos.router';
import { Round } from '../common/RoundScreen';

@Entry
@Component
struct Index {
  aboutToAppear(): void {
    // 直接进对话页（replaceUrl：返回时不该回到这个中间页）
    router.replaceUrl({ url: 'pages/ChatPage' });
  }

  build() {
    Column() {
      Text('DeepSeek')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E8EAED')
      Text('手表版')
        .fontSize(11)
        .fontColor('#4D6BFE')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#000000')
    .borderRadius('50%')
    .clip(true)
  }
}
