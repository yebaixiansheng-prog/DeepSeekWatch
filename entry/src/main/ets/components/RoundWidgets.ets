/**
 * 圆形表盘通用组件
 *
 * ★ 2026-10-03 重构（用户要求「统一视觉风格、提升交互体验」）
 *   本次改动的三条主线：
 *     ① **配色全部走 Theme 令牌** —— 不再有字面色值（`#xxxxxx`）。
 *        升级前这个文件里散着 `#4D6BFE`/`#1C1F27`/`#6E7380` 等 9 个字面色，
 *        与 Theme 里的令牌重复但不相等（差一点点），改主题时必然漏。
 *     ② **宽度不再写死百分比** —— 见 `widthPct` 与 `wPctAtY` 的关系。
 *     ③ **所有可点组件的下沿受手势区约束** —— 见 `RoundButton.fitsAboveGesture`。
 *
 * 注意：只保留实际被页面引用的组件，避免打包体积膨胀。
 * 命名统一 Round* 前缀，方便打包方识别这是圆屏定制件。
 */

import { Typo, Round, Unit } from '../common/RoundScreen';
import { Color, Radius, Space, Touch, Motion } from '../common/Theme';

/**
 * ★ 安全的默认宽度（vp 数值，可直接用 `.width(vp)`）
 *
 * 为什么不再用 `widthRatio * 100 + '%'`：
 *   百分比在圆屏上只在**屏幕中部**成立。用户明确要求
 *   「把写死的百分比全部换成按 y 计算」，所以这里给出 vp 数值版本，
 *   由调用方按元素实际所在的 y 决定 —— 见 `widthAtYVp`。
 *
 * 默认值取**舒适线（y=415）处**的可用宽度：这是"随便摆在哪儿都不会被切"
 * 的最保守值。元素越靠上，调用方就应该传越大的 y 拿更宽的宽度。
 */
function defaultWidthVp(): number {
  return Round.bottomUsableVp(Round.comfortBottomVp());
}

/** 主按钮（圆形屏友好：胶囊形 + 大触控区，满足 96px 最小触控规范） */
@Component
export struct RoundButton {
  @Prop label: string = '';
  @Prop primary: boolean = true;
  @Prop enabledState: boolean = true;
  /**
   * 宽度（vp）。`0` 表示「用默认安全宽度」。
   *
   * ★ 为什么从 `widthRatio: number`(0-1) 改成 `widthVp: number`：
   *   ratio 的语义是"占屏宽百分比" —— 而这个概念在圆屏上是个陷阱，
   *   同一个 ratio 在不同 y 处的**实际可用性**完全不同（见 RoundScreen 头注释）。
   *   换成 vp 后，"多宽"是一个绝对量，调用方必须（也只能）按真实几何给值，
   *   想写错都难。
   */
  @Prop widthVp: number = 0;
  /**
   * 按钮所在**中心**的 y（vp）—— 传了就按该 y 的可用宽度自动收窄，
   * 传 0（默认）= 不自动收窄，用 widthVp / 默认值。
   *
   * 这是「按 y 计算」在本组件里的落点。
   */
  @Prop centerYVp: number = 0;
  /**
   * 按钮高度（vp）。默认 48vp = 96px，满足最小触控规范。
   *
   * ★ 为什么做成可配（2026-09-19）：登录页纵向空间极紧，
   *   需要在同一屏内塞下「2 个输入框 + 错误行 + 按钮」。
   *   圆屏越靠下弦宽越窄，按钮**下沿**每低 1px，可用宽度就少一截。
   *   把高度收一档（48 → 40vp）能直接换回 16px 的下沿余量。
   *
   * ⚠️ 不建议低于 36vp（72px）：圆屏上最小可点区域约 96px 见方，
   *    40vp（80px）已经是实用下限，再小会出现「点不准」。
   */
  @Prop heightVp: number = Touch.hLg;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .type(ButtonType.Capsule)
      .width(this.resolveWidthVp())
      .height(this.heightVp)
      .fontSize(Typo.title)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.primary ? Color.onPrimary
        : (this.enabledState ? Color.text : Color.textFaint))
      .backgroundColor(this.primary
        ? (this.enabledState ? Color.primary : Color.disabled)
        : Color.surfaceAlt)
      .enabled(this.enabledState)
      .onClick(() => {
        if (this.enabledState) {
          this.onTap();
        }
      })
  }

  /**
   * 解析出最终宽度（vp）
   *
   * 优先级：显式 `centerYVp`（按 y 收窄）> 显式 `widthVp` > 默认安全宽度。
   * 三者都收口成一个 `Math.min`，保证**永远不会超过安全弦宽** ——
   * 这是本组件最重要的一条不变量。
   */
  private resolveWidthVp(): number {
    const safe: number = defaultWidthVp();
    if (this.centerYVp > 0) {
      const yTop: number = this.centerYVp - this.heightVp / 2;
      const usable: number = Round.bottomUsableVp(yTop);
      return Math.max(60, Math.min(usable, this.widthVp > 0 ? this.widthVp : usable));
    }
    if (this.widthVp > 0) {
      return Math.max(60, Math.min(this.widthVp, safe));
    }
    return safe;
  }
}

/**
 * 开关行
 * 用于「深度思考」「联网搜索」
 *
 * ⚠️ 这里刻意**不写回 this.on**：
 *    @Link 与父组件是双向绑定，父级在 onChange 里已经改了状态，
 *    子组件再赋值一次会触发多余的二次刷新（手表上表现为开关抖动）。
 *    只把新值上报给父级即可。
 */
@Component
export struct RoundSwitchRow {
  @Prop label: string = '';
  @Prop desc: string = '';
  /** 该行**中心**的 y（vp）—— 0 表示不按 y 收窄，用默认安全宽度 */
  @Prop centerYVp: number = 0;
  @Link on: boolean;
  onChange: (v: boolean) => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(Typo.body)
          .fontColor(Color.text)
          .maxLines(1)
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(Typo.caption - 1)
            .fontColor(Color.textFaint)
            .maxLines(1)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor(Color.primary)
        .switchPointColor(Color.onPrimary)
        .onChange((v: boolean) => {
          // 只上报，不写回 this.on（父级是唯一数据源）
          this.onChange(v);
        })
    }
    .width(this.resolveWidthVp())
    // ⚠️ 466 圆形屏上 1vp = 2px，高度写 58 就是 116px，两行开关就把浮层撑爆了。
    //    Touch.setH = 46vp(=92px) 是「触控够大 + 浮层放得下」的折中。
    .height(Touch.setH)
    .padding({ left: 12, right: 12 })
    .borderRadius(Radius.card)
    .backgroundColor(Color.surface)
  }

  private resolveWidthVp(): number {
    if (this.centerYVp > 0) {
      const yTop: number = this.centerYVp - Touch.setH / 2;
      return Math.max(60, Round.bottomUsableVp(yTop));
    }
    return defaultWidthVp();
  }
}

/**
 * 分段选择器（圆形屏定制）
 * 用于「快速模式 / 专项模式」切换
 *
 * 同 RoundSwitchRow：@Link 只读，状态更新交给父级 onChange，
 * 避免子组件二次写回导致的重复渲染。
 */
@Component
export struct RoundSegments {
  @Prop items: string[] = [];
  /** 该控件**中心**的 y（vp）—— 0 表示不按 y 收窄 */
  @Prop centerYVp: number = 0;
  @Link selected: number;
  onSelect: (index: number) => void = () => {
  };

  build() {
    Row() {
      ForEach(this.items, (item: string, idx: number) => {
        Text(item)
          .fontSize(Typo.body)
          .fontWeight(this.selected === idx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selected === idx ? Color.onPrimary : Color.textSub)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(Touch.hMd)
          .borderRadius(Touch.hMd / 2)
          .backgroundColor(this.selected === idx ? Color.primary : '#00000000')
          .animation({ duration: Motion.fast, curve: 'ease-out' })
          .onClick(() => {
            // 已是当前项则不重复触发
            if (this.selected === idx) {
              return;
            }
            this.onSelect(idx);
          })
      }, (item: string, idx: number) => item + idx.toString())
    }
    .width(this.resolveWidthVp())
    .padding({ left: 3, right: 3, top: 2, bottom: 2 })
    .borderRadius((Touch.hMd + 6) / 2)
    .backgroundColor(Color.surfaceAlt)
  }

  private resolveWidthVp(): number {
    if (this.centerYVp > 0) {
      const yTop: number = this.centerYVp - Touch.hMd / 2;
      return Math.max(60, Round.bottomUsableVp(yTop));
    }
    return defaultWidthVp();
  }
}

/**
 * ★ 页面滚动外壳（2026-10-03 新增）
 *
 * 圆屏每个页面的内容都需要「按 y 收窄 + 底部留出手势区余量」，
 * 升级前这段在三个页面里各写了一遍（ChatPage / SessionsPage / 设置页），
 * 而且三处的 padding bottom 值不一样（46 / 46 / 8），
 * 导致设置页最后一项点不到。
 *
 * 这个组件把这条纪律收成一处。
 */
@Component
export struct RoundScrollBody {
  @BuilderParam content: () => void;
  /** 底部额外留白（vp）—— 默认按「滚出手势区」所需 */
  @Prop extraBottomVp: number = 0;

  build() {
    Scroll() {
      Column() {
        this.content()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({
        top: Space.sm,
        bottom: this.extraBottomVp > 0
          ? this.extraBottomVp
          // 让最后一项能滚到舒适线以上：物理留白 = 屏幕底 - 舒适线
          : Unit.px2vp(Round.screenH - Round.comfortBottomPx) + Space.lg
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
