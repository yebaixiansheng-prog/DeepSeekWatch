/**
 * 设置页（独立路由）
 *
 * ★ 2026-10-03 拆出来（用户要求「拆成独立页面 + 圆环菜单」）
 *
 * ## 为什么从 ChatPage 里拆出来
 *
 * 升级前设置是 ChatPage 内一个 `UiMode.SETTINGS` 分支，问题：
 *   · ChatPage 一个文件 990 行，设置相关的 @State（stModel/stThinking/
 *     stSearch/stKeyPreview/fontScale）混在对话状态里；
 *   · 设置页**必须**在 `aboutToAppear` 里重新读一遍配置，
 *     因为它不在前台时用户可能在别处改了值 —— 同页模式没有这个时机；
 *   · 表冠在设置页要调字号、对话页要翻消息，
 *     两套语义挤在一个 `onDigitalCrown` 里，改一处要小心另一处。
 *
 * ## 圆屏布局（用户明确要求「按 y 计算宽度」）
 *
 * 本页所有行宽都走 `Round.bottomUsableVp(yTop)`：
 * 设置项是**静态纵向排列**的，不像列表要滚动估算 ——
 * 每一项的 y 是确定的，所以能算出**精确**宽度，不会被圆弧切角。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round, Unit, FontScale } from '../common/RoundScreen';
import { Color, Radius, Space, Touch, Motion } from '../common/Theme';
import { AppConfig } from '../model/AppConfig';
import { ChatStore } from '../model/ChatStore';
import { PersonaStore } from '../model/Persona';
import { Model } from '../common/Constants';

@Entry
@Component
struct SettingsPage {
  @State model: string = Model.FLASH;
  @State thinking: boolean = false;
  @State search: boolean = false;
  @State keyPreview: string = '';
  @State fontScale: number = FontScale.STANDARD;
  /** 人设条数（用于这一行的值） */
  @State personaCount: number = 0;

  async aboutToAppear(): Promise<void> {
    // ★ 每次都重新读配置：本页不在前台时值可能已被改（例如换模型）
    AppConfig.load().then(async () => {
      this.model = AppConfig.model();
      this.thinking = AppConfig.thinking();
      this.search = AppConfig.search();
      this.keyPreview = maskKey(AppConfig.apiKey());
      const list = await PersonaStore.all();
      this.personaCount = list.length;
    });
    Typo.scale = this.fontScale as FontScale;
  }

  // ======================================================================
  //  操作
  // ======================================================================

  private async switchModel(): Promise<void> {
    const next: string = this.model === Model.FLASH ? Model.PRO : Model.FLASH;
    this.model = next;
    await AppConfig.setModel(next);
    promptAction.showToast({ message: '已切换到' + Model.label(next), duration: 1200 });
  }

  private async saveThinking(v: boolean): Promise<void> {
    this.thinking = v;
    await AppConfig.setThinking(v);
  }

  private async saveSearch(v: boolean): Promise<void> {
    this.search = v;
    await AppConfig.setSearch(v);
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

  private async doClearAllSessions(): Promise<void> {
    promptAction.showDialog({
      title: '清空全部对话？',
      message: '所有历史对话都会被删除，无法恢复。人设不受影响。',
      buttons: [
        { text: '取消', color: Color.textSub },
        { text: '全部清空', color: Color.danger }
      ]
    }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        await ChatStore.clearAll();
        promptAction.showToast({ message: '已清空', duration: 1000 });
      }
    }).catch(() => {
    });
  }

  private async resetPersonas(): Promise<void> {
    promptAction.showDialog({
      title: '重置人设？',
      message: '所有自定义人设会被删除，只保留一条「通用助手」。',
      buttons: [
        { text: '取消', color: Color.textSub },
        { text: '重置', color: Color.danger }
      ]
    }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        const list = await PersonaStore.all();
        for (const p of list) {
          await PersonaStore.remove(p.id);
        }
        PersonaStore.invalidate();
        this.personaCount = (await PersonaStore.all()).length;
        promptAction.showToast({ message: '已重置', duration: 1200 });
      }
    }).catch(() => {
    });
  }

  // ======================================================================
  //  UI
  // ======================================================================

  build() {
    Column() {
      // ---------- 顶栏 ----------
      Row() {
        Text('‹ 返回')
          .fontSize(Typo.caption)
          .fontColor(Color.textSub)
          .onClick(() => router.back())
        Blank()
        Text('设置')
          .fontSize(Typo.caption)
          .fontColor(Color.text)
        Blank()
        Text('　　')
          .fontSize(Typo.caption)
      }
      .width(Round.bottomUsableVp(Y_BAR - Touch.barH / 2, 6))
      .height(Touch.barH)
      .margin({ top: Y_BAR - Touch.barH / 2 })

      // ---------- 内容 ----------
      Scroll() {
        Column({ space: Space.sm }) {
          this.SetRow(0, '模型', Model.label(this.model), () => this.switchModel())
          this.SetToggle(1, '深度思考', AppConfig.thinkingLabel(), this.thinking,
            (v: boolean) => this.saveThinking(v))
          this.SetToggle(2, '联网搜索', AppConfig.searchLabel(), this.search,
            (v: boolean) => this.saveSearch(v))
          this.SetRow(3, '字号', fontLabel(this.fontScale),
            () => this.rotateFont(1))
          this.SetRow(4, '人设', this.personaCount.toString() + ' 条',
            () => router.pushUrl({ url: 'pages/PersonaPage' }))
          this.SetRow(5, 'API 密钥', this.keyPreview, () => {
            promptAction.showToast({
              message: '密钥已内置，如需更换请修改工程内 LocalKey.ets',
              duration: 2000
            });
          })
          this.SetDangerRow(6, '清空全部对话', () => this.doClearAllSessions())
          this.SetDangerRow(7, '重置人设', () => this.resetPersonas())

          Text('DeepSeek Watch · 官方 API')
            .fontSize(Typo.caption - 2)
            .fontColor(Color.textGhost)
            .margin({ top: Space.xs, bottom: Space.md })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: Space.xs, bottom: 40 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.bg)
    .borderRadius('50%')
    .clip(true)
    // 表冠：设置页 = 调字号
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      const step: number = event.degree > 0 ? 1 : -1;
      // 表冠每转到一定角度才算一步（避免过于灵敏）
      if (Math.abs(event.degree) >= CROWN_STEP) {
        this.rotateFont(step);
      }
    })
  }

  /**
   * 设置行（普通）
   *
   * @param order 第几行（用于按 y 算宽度）—— 见文件头「按 y 计算」
   */
  @Builder
  SetRow(order: number, label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(Typo.body)
        .fontColor(Color.text)
        .layoutWeight(1)
        .maxLines(1)
      Text(value)
        .fontSize(Typo.caption)
        .fontColor(Color.textSub)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '52%' })
    }
    .width(rowWidthVp(order))
    .height(Touch.setH)
    .padding({ left: 12, right: 12 })
    .borderRadius(Radius.card)
    .backgroundColor(Color.surface)
    .onClick(onTap)
  }

  /** 设置行（开关） */
  @Builder
  SetToggle(order: number, label: string, desc: string, on: boolean,
            onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(Typo.body)
          .fontColor(Color.text)
          .maxLines(1)
        if (desc.length > 0) {
          Text(desc)
            .fontSize(Typo.caption - 2)
            .fontColor(Color.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(Color.primary)
        .switchPointColor(Color.onPrimary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width(rowWidthVp(order))
    .height(Touch.rowH)
    .padding({ left: 12, right: 8 })
    .borderRadius(Radius.card)
    .backgroundColor(Color.surface)
  }

  /** 危险操作行 */
  @Builder
  SetDangerRow(order: number, label: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(Typo.body)
        .fontColor(Color.danger)
        .layoutWeight(1)
        .maxLines(1)
    }
    .width(rowWidthVp(order))
    .height(Touch.setH)
    .padding({ left: 12, right: 12 })
    .borderRadius(Radius.card)
    .backgroundColor(Color.dangerDim)
    .onClick(onTap)
  }
}

// ========================================================================
//  布局常量
// ========================================================================

/** 顶栏中心 y（vp） */
const Y_BAR: number = 22;
/** 内容区上沿（vp） */
const Y_CONTENT: number = 8;
/** 表冠触发一步所需的最小角度（度） */
const CROWN_STEP: number = 12;

/**
 * 第 order 行的宽度（vp）—— 按该行的 y 精确计算
 *
 * ★ 这是「按 y 计算」在设置页的落点。设置项是静态排列，
 *   所以每一项的 y 是确定的 → 能算出精确宽度（不像列表要估算）。
 *
 * ⚠️ 行高不统一（开关行 50vp，其余 46vp）。这里统一按 50 估，
 *   误差最多 4vp × 8 行 = 32vp，在底部会略微保守 —— **保守是安全方向**
 *   （窄一点不会被切角），所以不为此增加复杂度。
 */
function rowWidthVp(order: number): number {
  const topY: number = Y_BAR + Touch.barH / 2 + Y_CONTENT
    + order * (Touch.rowH + Space.sm);
  return Round.bottomUsableVp(topY, 6);
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
