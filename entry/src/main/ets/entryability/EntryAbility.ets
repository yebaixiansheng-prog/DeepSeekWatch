import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { Store } from '../common/Store';
import { Round } from '../common/RoundScreen';
import { AppConfig } from '../model/AppConfig';

const TAG: string = 'Boot';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 本地存储（异步；页面侧发消息前会 await 配置加载）
    Store.init(this.context);

    // 加载配置（API 密钥 / 模型 / 开关）
    AppConfig.load().then(() => {
      console.info(TAG + ' config ready, hasKey=' + (AppConfig.hasKey() ? 'Y' : 'N')
        + ' model=' + AppConfig.model()
        + ' thinking=' + (AppConfig.thinking() ? 'Y' : 'N')
        + ' search=' + (AppConfig.search() ? 'Y' : 'N'));
    }).catch(() => {
      console.warn(TAG + ' config load failed');
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        return;
      }
      const win: window.Window = windowStage.getMainWindowSync();

      // 全屏沉浸：圆形表盘没有状态栏
      win.setWindowLayoutFullScreen(true).catch(() => {
      });

      // 读取实际屏幕尺寸，供圆形适配使用
      const rect: window.Rect = win.getWindowProperties().windowRect;
      Round.screenW = rect.width;
      Round.screenH = rect.height;
      console.info(TAG + ' screen=' + Round.screenW.toString() + 'x' + Round.screenH.toString());

      // 对话中需要保持常亮（长回答不该走到一半熄屏）
      win.setWindowKeepScreenOn(true).catch(() => {
      });
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  onDestroy(): void {
  }
}
