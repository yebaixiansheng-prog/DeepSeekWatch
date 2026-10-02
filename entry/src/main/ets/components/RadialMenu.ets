/**
 * 圆环径向菜单（Radial Menu）—— 圆形表盘的核心导航
 *
 * ★ 2026-10-03 新增（用户要求「拆成独立页面 + 圆环菜单」）
 *
 * ## 为什么圆屏要用径向菜单
 *
 * 手表屏幕只有 466px，且**越靠下弦宽越窄**（见 RoundScreen.ets）。
 * 传统横向/纵向排布的导航栏在这个形状上必然吃亏：
 *   · 顶部一条 bar：占掉本就最金贵的纵向空间；
 *   · 底部一条 bar：y≥450 是系统手势区，可点高度只剩 ~30px，必然误触。
 *
 * 径向菜单把**导航本身**放进圆里：圆心周围一圈扇区，天然贴合屏幕形状，
 * 而且**八成的屏幕面积都被用作菜单项**，点到就是点到。
 *
 * ## 布局：不是图形学，是"把圆环切成 count 份"
 *
 * 本组件不用 Canvas / Path 画扇形（圆屏小、抗锯齿差、还要自己算触摸），
 * 而是用「**一圈等角摆放的按钮 + 中心一个圆形按钮**」：
 *
 *   · 每个菜单项是一个 **58×58vp 的圆角方块**，放在角度 `centerAngleOf(i,count)`
 *     半径 `R_ITEM` 的位置上；
 *   · 交互用正常的 `onClick` —— 命中判定交给 ArkUI，
 *     **不需要**自己按角度做 hit-test（那是纯 Web canvas 的做法）。
 *
 * ★ 那 `RadialHit` 为什么还要存在？
 *   因为**表冠驱动的选择**需要知道「当前转到第几项」，
 *   以及**将来若要改成绘制式扇形**时需要角度判定。
 *   更重要的是：`RadialHit.centerAngleOf` 是**渲染和判定的共同基准** ——
 *   摆了 4 个按钮，它们的角度必须与「表冠转 1 步 = 第几项」严格一致，
 *   否则会出现「表冠转到第二项高亮、手指点第二个却说第一项」的错位。
 *   把这个基准抽成纯函数并加测试（15.16 往返断言），是防这类错位的唯一办法。
 *
 * ## 圆屏约束（硬性，来自真机实测）
 *
 *   1vp = 2px。圆心 (233,233)px。安全半径 205px = 102.5vp。
 *   · `ITEM_R_VP = 56`：菜单项的径向位置。56vp = 112px，离圆心不算远，
 *     整个环的直径 = 56*2+58 = 170vp = 340px < 屏宽 466px，留足了边距；
 *   · 环上最低点 = 圆心 + 56 + 29 = 233+112+58 = 403px < 436（手势区硬上限）
 *     ✅ 底部菜单项**可点**，这是径向菜单相对底部 bar 的关键优势。
 *
 * ## 表冠
 *
 * 表冠旋转（`onDigitalCrown` 在页面级接收）→ `RadialMenuState.feed(steps)`
 * → 高亮项跟着变。中心按钮是「确定/进入」，点击即触发 `onPick(index)`。
 * 用户也可以**直接点**某一项（触摸热区是 58vp 的方块，够大）。
 */

import { Round, Typo, RadialHit, Unit } from '../common/RoundScreen';
import { Color, Radius, Motion, Opacity, Curve } from '../common/Theme';

/** 一个菜单项 */
export interface RadialItem {
  /** 图标（emoji 或单字符 —— 手表上没有图标字体，用字符最省体积） */
  icon: string;
  /** 文案（显示在图标下方或中心） */
  label: string;
}

/** 菜单项的边长（vp）—— 58vp = 116px，接近 96px 最小触控区，圆屏上很好点 */
const ITEM_SIZE_VP: number = 54;
/** 菜单项距圆心的半径（vp） */
const ITEM_R_VP: number = 58;

/**
 * 径向菜单
 *
 * 用法（页面里）：
 * ```
 * RadialMenu({
 *   items: [{icon:'＋',label:'新对话'}, ...],
 *   active: this.menu.index,
 *   open: this.menuOpen,
 *   onPick: (i) => this.onMenuPick(i),
 *   onClose: () => this.menuOpen = false
 * })
 * ```
 */
@Component
export struct RadialMenu {
  @Prop items: RadialItem[] = [];
  /** 当前高亮项（表冠驱动，也可能是悬停） */
  @Prop active: number = 0;
  /** 是否展开（收起时只显示中心按钮） */
  @Prop open: boolean = false;
  /** 选中某一项 */
  onPick: (index: number) => void = () => {
  };
  /** 关闭菜单（点中心按钮 / 点空白处） */
  onClose: () => void = () => {
  };

  build() {
    // ★ Stack 里所有子元素都以**父容器中心**为基准摆放，
    //   偏移用 `offset` 而不是 `position`：
    //   `position` 是相对父容器**左上角**定位，需要自己减掉一半宽高，
    //   在圆屏上极其容易算错（且圆屏没有"角"给你参考）。
    //   `offset` 是相对**自身位置**的位移，配合 Stack 的居中对齐，就是"极坐标"。
    Stack() {
      if (this.open) {
        // ---------- 展开态：一圈菜单项 ----------
        ForEach(this.items, (it: RadialItem, i: number) => {
          Column() {
            Text(it.icon)
              .fontSize(21)
              .fontColor(this.active === i ? Color.onPrimary : Color.text)
            Text(it.label)
              .fontSize(Typo.caption - 3)
              .fontColor(this.active === i ? Color.onPrimary : Color.textFaint)
              .maxLines(1)
              .margin({ top: 1 })
          }
          .width(ITEM_SIZE_VP)
          .height(ITEM_SIZE_VP)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Radius.card)
          .backgroundColor(this.active === i ? Color.primary : Color.surfaceAlt)
          .border({
            width: this.active === i ? 0 : 1,
            color: Color.border
          })
          // ★ 极坐标 → 笛卡尔：角度基准与 RadialHit 完全一致（0° = 正上方，顺时针）。
          //   算术全部委托给 `RadialHit.offsetOf`，**不在这里重写 cos/sin** ——
          //   重写一份就可能与判定用的基准漂移，而漂移的表现正是
          //   「点 A 却选中 B」，最难受也最难查。
          //
          // ★★ `.offset()` 在这版 SDK 上**只接受一个 `Position` 对象参数**，
          //   两参数重载 `offset(x, y)` 会报 `Expected 1 arguments, but got 2`。
          //   但直接用对象字面量 `{x: .., y: ..}` 又会报
          //   `Type '{x:number;y:number}' is not assignable to type 'Offset'`
          //
          //   两条报错夹击下的正解：用 `Position` 这个**内置类型**作类型标注 ——
          //   SDK 里 `offset(value: Position)`，而 `Position` 就是 `{x, y}`。
          //   之前报错是因为我没写类型标注，ArkTS 对无标注的对象字面量
          //   会用 `Offset`（`{dx, dy}`）去匹配，于是键名对不上。
          .offset(this.posOfIndex(i))
          .animation({ duration: Motion.base, curve: Curve.standard })
          .onClick(() => this.onPick(i))
        }, (it: RadialItem, i: number) => it.label + i.toString())

        // ---------- 展开态：中心关闭按钮 ----------
        Column() {
          Text('✕')
            .fontSize(Typo.body)
            .fontColor(Color.textSub)
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(Radius.pill)
        .backgroundColor(Color.surface)
        .border({ width: 1, color: Color.border })
        .onClick(() => this.onClose())
      } else {
        // ---------- 收起态：中心展开按钮 ----------
        Column() {
          Text('＋')
            .fontSize(22)
            .fontColor(Color.text)
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(Radius.pill)
        .backgroundColor(Color.surfaceAlt)
        .border({ width: 1, color: Color.border })
        .onClick(() => {
          // 收起态点它 = 展开。展开态由父组件通过 open 控制，
          // 这里用 onPick(-1) 作为一个明确的"请求展开"信号 ——
          // 传 -1 是因为它**不可能是合法索引**，父组件一眼能分清
          // 「用户选了第 0 项」和「用户要展开菜单」。
          this.onPick(-1);
        })
      }
    }
    .width(Unit.vp2px(ITEM_R_VP) * 2 + Unit.vp2px(ITEM_SIZE_VP))
    .height(Unit.vp2px(ITEM_R_VP) * 2 + Unit.vp2px(ITEM_SIZE_VP))
    .alignContent(Alignment.Center)
    .clip(false)
  }

  /**
   * 第 i 项的 offset（Position 对象）
   *
   * ★★ 这段代码的形状是被**两条编译错误夹出来**的，改之前务必读完：
   *
   *   · 写成 `.offset({x: .., y: ..})`（无类型标注的对象字面量）→
   *       `Type '{ x: number; y: number; }' is not assignable to type 'Offset'`
   *       （ArkTS 拿 `Offset` = `{dx, dy}` 去匹配，键名对不上）
   *   · 写成 `.offset(x, y)`（两参数重载）→
   *       `Expected 1 arguments, but got 2`（这版 SDK 只有一个重载）
   *
   *   正解：**把返回值显式标注为 `Position`**（内置的 `{x, y}` 类型），
   *   再传进去。ArkTS 就按 `Position` 重载匹配，两个错都没有了。
   *   这就是「ArkTS 不是 TS」的典型样本 —— 它不是"更严格的 TS"，
   *   而是**另一套类型系统**，重载解析规则不同。
   *
   * ★ 算术全部委托给 `RadialHit.offsetOf`，**不在这里重写 cos/sin** ——
   *   重写一份就可能与判定用的基准漂移，而漂移的表现正是
   *   「点 A 却选中 B」，最难受也最难查。
   *
   * ★ 取整到 1 位小数：保留全精度会产生 61.93029785 这种值，
   *   多次重绘累积下可能出现亚像素抖动（圆屏上肉眼可见）。1 位小数足够。
   */
  private posOfIndex(i: number): Position {
    const ang: number = RadialHit.centerAngleOf(i, this.items.length);
    const off: number[] = RadialHit.offsetOf(ang, Unit.vp2px(ITEM_R_VP));
    // vp 坐标逐轴取整到 1 位小数（四舍五入对**视觉位置**是对的方向：
    // 偏移量本身不是刚性约束，不会像宽度那样"多一点就被切"）。
    const x: number = Math.round(off[0] / Unit.density * 10) / 10;
    const y: number = Math.round(off[1] / Unit.density * 10) / 10;
    const p: Position = { x: x, y: y };
    return p;
  }
}

/**
 * ★ 半透明遮罩（展开菜单时压暗底下的内容）
 *
 * 单独抽出来是因为「点遮罩关闭」这个行为需要覆盖**整屏**，
 * 而 RadialMenu 本体只有 170vp 宽 —— 遮罩必须由页面铺满。
 * 页面用法：
 * ```
 * Stack() {
 *   this.Content()
 *   if (this.menuOpen) {
 *     RadialScrim({ onTap: () => this.menuOpen = false })
 *     RadialMenu({ ... })
 *   }
 * }
 * ```
 */
@Component
export struct RadialScrim {
  onTap: () => void = () => {
  };

  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.scrim)
      .onClick(() => this.onTap())
  }
}

/**
 * ★ 环形进度/高亮指示（菜单展开时，环绕在菜单项外侧的细环）
 *
 * 用 `Circle` 组件而不是自己画弧 —— ArkUI 的 Circle 在圆屏上抗锯齿更好，
 * 而且这个环**纯装饰**（不接收点击），所以不需要 Path 的精确控制。
 */
@Component
export struct RadialRing {
  /** 直径（vp） */
  @Prop diameterVp: number = 150;
  @Prop highlight: boolean = false;

  build() {
    Circle()
      .width(this.diameterVp)
      .height(this.diameterVp)
      .fill('#00000000')
      .stroke(this.highlight ? Color.primary : Color.border)
      .strokeWidth(1)
      .opacity(this.highlight ? Opacity.mid : Opacity.ghost)
  }
}
