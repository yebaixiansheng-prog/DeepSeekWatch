import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { Store } from '../common/Store';
import { Round } from '../common/RoundScreen';
import { DeepSeekHash } from '../common/DeepSeekHash';
import { AuthService } from '../model/AuthService';

const TAG: string = 'Boot';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 初始化本地存储（异步，页面侧会 await 同一个 Promise）
    Store.init(this.context);

    // ★ 启动自检：DeepSeekHashV1 移植是否正确，直接决定 PoW 能否过。
    //   手表上无法单步调试，只能在 hilog 里看这一行结论。
    //   查看： hdc shell "hilog -x | grep Boot"
    const ok: boolean = DeepSeekHash.selfTest();
    console.info(TAG + ' selfTest=' + (ok ? 'PASS' : 'FAIL'));

    // ★ 预热设备 ID 同步缓存：让「冷启动后第一个请求」就能带上
    //   x-ds-device-id 头。否则那个请求是不带设备标识的，
    //   在风控敏感的网络出口下最容易被打回。
    AuthService.warmUp().then(() => {
      console.info(TAG + ' deviceId ready');
    }).catch((e: BusinessError) => {
      console.warn(TAG + ' deviceId warmUp failed: ' + e.message);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        return;
      }
      // 全屏沉浸，圆形表盘没有状态栏
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
      });

      // 读取实际屏幕尺寸，供圆形适配使用
      const rect: window.Rect = win.getWindowProperties().windowRect;
      Round.screenW = rect.width;
      Round.screenH = rect.height;

      // 手表常亮策略：保持屏幕
      win.setWindowKeepScreenOn(true).catch((e: BusinessError) => {
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
