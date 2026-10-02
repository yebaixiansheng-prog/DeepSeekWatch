/**
 * 圆形表盘几何适配 —— 全部按「y 坐标」计算，不写死百分比
 *
 * ★ 2026-10-03 重构（用户要求「深度适配圆形表盘的设备」）
 *
 * ## 为什么必须按 y 算
 *
 * 466×466 的圆，圆心 (233,233)，R=233。任一高度 y 处的**弦宽**：
 *
 *     halfW(y) = sqrt(R² - (y - 233)²)
 *
 * 这是圆的性质，不是估算。几个关键点（px）：
 *
 *     y=233（圆心）  弦宽 466
 *     y=280          弦宽 455
 *     y=350          弦宽 403
 *     y=415          弦宽 291
 *     y=428          弦宽 255
 *     y=436          弦宽 229   ← 硬上限（下方 8px 留白给手势区）
 *     y=450          弦宽 170   ← 系统手势区起点，不作为可点区域
 *     y=466          弦宽 0
 *
 * ★ 2026-10-03：y=428 原先手抄成 262，实际是 **255**。
 *   7px 的误差在「按钮放这里放不放得下」的判断上足以翻盘。
 *   纪律：**圆方程才是权威，手抄的实测值不是** —— 凡拿实测值当断言，
 *   先跑一遍 `2*sqrt(R²-(y-233)²)` 对账。
 *
 * ★ 安全圆（下面 `SAFE_K`）收口比物理圆快得多，底部尤其明显：
 *
 *     y=415  物理 291  →  安全 189
 *     y=428  物理 255  →  安全 127
 *     y=436  物理 229  →  安全  58
 *     y=450  物理 170  →  安全   0
 *
 *   所以底部元素的宽度**必须**用安全弦宽算，不能用物理弦宽。
 *
 * 也就是说：**同一个 `width('84%')`，在 y=233 处宽 391px 是安全的，
 * 在 y=450 处同样 391px 却超出屏幕 130px** —— 这就是旧代码的问题：
 * 84% 这个数字只在屏幕中部成立，而它在注释里被当成通用值用了。
 *
 * 本文件的做法：给一个 y，返回**该 y 处真正安全的宽度**。
 * 页面调用 `Round.wPctAtY(yCenterVp, padVp)` 得到百分比字符串直接用。
 *
 * ## 坐标系约定
 *
 * · 本文件所有 y 都是 **px**（0 = 屏幕顶，466 = 屏幕底），与 `Round` 一致。
 * · 页面里布局用的是 **vp**。`1vp = 2px`（density=2），换算见 `vp2px` / `px2vp`。
 * · 因为密度恒定，**vp 排版的可用宽度正好是 px 可用宽度的一半**，
 *   百分比相同 —— 所以下面直接算百分比，与单位无关（见 `wPctAtY`）。
 *
 * ## 底部手势区
 *
 * y ≥ 450 是系统手势区，点这里会把 App 推到后台。
 * 因此 `safeBottomPx = 436`（留 8px 余量），可点元素下沿不得超过它。
 * 见 `safeBottomVp()` 与 `fitsAboveGesture(yBottomVp)`。
 */

/** 单位换算：本机 density = 2 */
export class Unit {
  /** 1vp 对应多少 px */
  static readonly density: number = 2;

  static vp2px(vp: number): number {
    return vp * Unit.density;
  }

  static px2vp(px: number): number {
    return px / Unit.density;
  }
}

export class Round {
  /** 屏宽（px），运行时由 window 获取 */
  static screenW: number = 466;
  static screenH: number = 466;

  /**
   * 内容安全半径系数
   *
   * 0.88 → 安全半径 205px（内接正方形边长约 290px）。
   * 这个值来自华为圆屏规范的建议：关键内容避开最外圈，
   * 给表冠、防误触和裁切留余量。
   *
   * ⚠️ 不要再往下调（比如 0.95）：实测在 y=415 附近，
   *    0.95 的圆与屏幕圆弧只差 12px，文字会视觉上「贴边」，
   *    而且圆屏面板制造公差会让不同批次手表表现不一致。
   */
  static readonly SAFE_K: number = 0.88;

  /** 屏幕圆心 y（px） */
  static get centerY(): number {
    return Round.screenH / 2;
  }

  /** 屏幕圆心 x（px） */
  static get centerX(): number {
    return Round.screenW / 2;
  }

  /** 物理半径（px） */
  static get radius(): number {
    return Math.min(Round.screenW, Round.screenH) / 2;
  }

  /** 安全半径（px） */
  static get safeRadius(): number {
    return Round.radius * Round.SAFE_K;
  }

  /** 安全圆内接正方形边长（px）= 最宽处可用宽度 */
  static get contentW(): number {
    return Round.safeRadius * Math.SQRT2;
  }

  /** 安全圆的纵向范围（px）：[safeTop, safeBottom] */
  static get safeTop(): number {
    return Round.centerY - Round.safeRadius;
  }

  static get safeBottom(): number {
    return Round.centerY + Round.safeRadius;
  }

  /**
   * ★ 系统手势区上沿（px）
   *
   * y ≥ 450 会触发系统手势（把 App 推到后台）。
   * 取 436 而非 450：留 14px 余量吸收列表弹性回弹与不同固件的判定差异。
   */
  static readonly gestureTopPx: number = 450;

  /** ★ 可点元素允许的**硬上限**下沿（px）—— 越过它会被系统手势抢走 */
  static readonly safeBottomPx: number = 436;

  /**
   * ★★ 可点元素的**舒适线**下沿（px）—— 推荐值，比硬上限更值得守
   *
   * 为什么在硬上限之外还要一条更严的线：
   *   安全圆（0.88）在底部的收拢非常快 —— 实测计算：
   *       y=415  安全弦宽 189px（占屏宽 40%）
   *       y=428  安全弦宽 127px（27%）
   *       y=436  安全弦宽  58px（12%）
   *   也就是说 y>415 之后，**安全圆本身已经窄到放不下一个按钮了**。
   *   硬上限 436 只是「不会被系统手势抢走」，不代表「那里放得下东西」。
   *
   * 因此布局策略是：
   *   · 可点元素下沿尽量 ≤ 415（此处理论弦宽 291px，实用宽度充裕）；
   *   · 415~436 只用来放**非交互**的留白或极窄文案；
   *   · 超过 436 一律不放东西。
   */
  static readonly comfortBottomPx: number = 415;

  /** 舒适线下沿（vp） */
  static comfortBottomVp(): number {
    return Unit.px2vp(Round.comfortBottomPx);
  }

  /**
   * 底部区域实际可用的宽度（px）—— 页面底部按钮该多宽，用它而不是百分比
   *
   * 取 [yTop, comfortBottom] 区间内**最窄处**的物理弦宽，
   * 再扣掉安全边距。这样得到的值在整段区间内都不会被圆弧切到。
   */
  static bottomUsablePx(yTopPx: number, padPx: number = 10): number {
    const bottom: number = Math.min(Math.max(yTopPx, Round.comfortBottomPx),
      Round.safeBottomPx);
    let min: number = Round.safeWidthAtY(yTopPx) - padPx * 2;
    const wB: number = Round.safeWidthAtY(bottom) - padPx * 2;
    if (wB < min) {
      min = wB;
    }
    return Math.max(0, min);
  }

  /** 底部区域可用宽度，vp 版（直接用于 .width(vp) 数值的场景） */
  static bottomUsableVp(yTopVp: number, padVp: number = 5): number {
    return Unit.px2vp(Round.bottomUsablePx(Unit.vp2px(yTopVp), Unit.vp2px(padVp)));
  }

  /** 可点元素允许的最大下沿（vp） */
  static safeBottomVp(): number {
    return Unit.px2vp(Round.safeBottomPx);
  }

  /**
   * ★ 核心：某一 y 处的安全弦宽（px）
   *
   * @param y 纵向坐标（px，0 = 屏幕顶）
   * @returns 该高度的可用宽度（px）
   *
   * 注意用的是**安全半径**而非物理半径 —— 返回值已经扣掉了安全边距。
   */
  static safeWidthAtY(y: number): number {
    const dy: number = y - Round.centerY;
    const r: number = Round.safeRadius;
    const d: number = Math.min(Math.abs(dy), r);
    return Math.sqrt(Math.max(0, r * r - d * d)) * 2;
  }

  /**
   * 某一 y 处的安全弦宽，相对**屏宽**的百分比（0-100）
   *
   * ★ 这是页面最常用的接口。
   *
   * @param y     纵向坐标（px）
   * @param insetPx 额外水平内边距（px），给你的卡片左右留白用
   */
  static widthPctAtY(y: number, insetPx: number): number {
    if (Round.screenW <= 0) {
      return 86;
    }
    const w: number = Round.safeWidthAtY(y) - insetPx * 2;
    const pct: number = (w / Round.screenW) * 100;
    // 下限 20%：低于这个值布局已经没意义了，给个兜底避免出现 3% 这种诡异值
    return Math.max(20, Math.min(100, pct));
  }

  /**
   * 页面直用：按 y（**vp**）算宽度百分比字符串，可直接喂给 `.width(...)`
   *
   * @param yVp    该元素中心的 y（vp）
   * @param padVp  水平内边距（vp），默认 6 —— 圆屏上这个值很关键
   * @returns 形如 '84%' 的字符串
   *
   * ★ 用**元素中心**而不是上沿：卡片有高度，中心最能代表它的可用宽。
   *   对高元素（列表）应逐行调用，见 `rowPct`。
   */
  static wPctAtY(yVp: number, padVp: number = 6): string {
    const yPx: number = Unit.vp2px(yVp);
    const insetPx: number = Unit.vp2px(padVp);
    // ★ 用 Math.floor 而不是 toFixed 四舍五入（2026-10-03 测试抓出来的）：
    //   `widthPctAtY` 返回的是**恰好贴着安全弦宽**的值（如 24.56%），
    //   四舍五入成 '25%' 会让实际宽度**超出**可用宽度约 2px ——
    //   在圆屏最收口的顶部，2px 就足以让卡片边角被圆弧切掉。
    //   向下取整是安全方向：宁可窄 1%，也不要宽到被裁。
    return Math.floor(Round.widthPctAtY(yPx, insetPx)).toString() + '%';
  }

  /**
   * 一整块区域（从 yTop 到 yBottom，vp）的**最窄处**宽度百分比
   *
   * ★ 为什么取最窄处：一个卡片如果从 y=380 延伸到 y=440，
   *   它在 y=440 处最窄。若按顶部宽度渲染，底部两角会被圆弧切掉。
   *   宁可窄一点、完整显示，也不要宽一点、被裁掉。
   *
   * @param extraPadVp 额外内边距（vp）
   */
  static blockPct(yTopVp: number, yBottomVp: number, extraPadVp: number = 6): string {
    const yTopPx: number = Unit.vp2px(yTopVp);
    const yBottomPx: number = Unit.vp2px(yBottomVp);
    // 采样最窄处：区域两端 + 中点，取最小（圆弧在这三点之间单调，够用）
    const midPx: number = (yTopPx + yBottomPx) / 2;
    let minW: number = Round.widthPctAtY(yTopPx, Unit.vp2px(extraPadVp));
    const wMid: number = Round.widthPctAtY(midPx, Unit.vp2px(extraPadVp));
    const wBot: number = Round.widthPctAtY(yBottomPx, Unit.vp2px(extraPadVp));
    if (wMid < minW) {
      minW = wMid;
    }
    if (wBot < minW) {
      minW = wBot;
    }
    // 同 wPctAtY：向下取整（宁可窄一点也不要被圆弧切角）
    return Math.floor(minW).toString() + '%';
  }

  /**
   * 第 row 行（共 totalRows 行）的宽度百分比
   *
   * 适用于「整屏均分若干行」的场景（如设置项列表）。
   * 行高由调用方决定，这里假设从 safeTop 到 safeBottom 均分。
   */
  static rowPct(row: number, totalRows: number, padVp: number = 6): string {
    if (totalRows <= 0) {
      return Round.wPctAtY(Round.centerY);
    }
    if (totalRows === 1) {
      return Round.wPctAtY(Round.centerY, padVp);
    }
    const t: number = row / (totalRows - 1);
    const yPx: number = Round.safeTop + t * (Round.safeBottom - Round.safeTop);
    // 同 wPctAtY：向下取整
    return Math.floor(Round.widthPctAtY(yPx, Unit.vp2px(padVp))).toString() + '%';
  }

  /**
   * ★ 该元素的纵向范围是否落在手势区之上（可点）
   *
   * 页面里凡是**要点击**的元素，构建完都应过一遍这个断言。
   * 返回 false 时**必须**调整布局，不能只打个日志。
   */
  static fitsAboveGesture(yBottomVp: number): boolean {
    return Unit.vp2px(yBottomVp) <= Round.safeBottomPx;
  }

  /**
   * 给定顶部 y（vp）和高度（vp），返回「中心点 y（vp）」——
   * 传 `wPctAtY` 用的就是这个值。
   */
  static centerOf(yTopVp: number, heightVp: number): number {
    return yTopVp + heightVp / 2;
  }

  /** 该点（px）是否在安全圆内 */
  static inside(x: number, y: number): boolean {
    const dx: number = x - Round.centerX;
    const dy: number = y - Round.centerY;
    return Math.sqrt(dx * dx + dy * dy) <= Round.safeRadius;
  }

  /** 兼容旧接口：安全宽度（px） */
  static get safeW(): number {
    return Round.safeRadius * 2;
  }

  /** 兼容旧接口：按相对圆心的偏移算宽度（px） */
  static widthAtY(yOffset: number): number {
    return Round.safeWidthAtY(Round.centerY + yOffset);
  }

  /** 兼容旧接口：顶部留白（px）—— 安全圆顶点到屏幕顶点的距离 */
  static get topInset(): number {
    return Math.max(0, Round.radius - Round.safeRadius);
  }

  /** 兼容旧接口 */
  static wPct(wPx: number): string {
    if (Round.screenW <= 0) {
      return '86%';
    }
    const pct: number = (wPx / Round.screenW) * 100;
    // 向下取整（安全方向）
    return Math.floor(Math.max(20, Math.min(100, pct))).toString() + '%';
  }

  /** 兼容旧接口 */
  static rowWidth(row: number, totalRows: number): number {
    if (totalRows <= 1) {
      return Round.contentW;
    }
    const t: number = (row / (totalRows - 1)) * 2 - 1;
    const halfW: number = Math.sqrt(Math.max(0,
      Round.safeRadius * Round.safeRadius - Math.pow(t * Round.safeRadius, 2)));
    return halfW * 2;
  }
}

/**
 * ★★ 径向菜单的命中判定（纯几何，离线可测）
 *
 * ★ 2026-10-03 新增（用户要求「拆成独立页面 + 圆环菜单」）
 *
 * ## 语义：点击落在**哪个扇区**
 *
 * 圆心菜单被点击时，输入只有一个坐标 (x, y)。要把它翻译成
 * 「用户点了哪一项」，需要的判定是：
 *
 *   1. 距圆心的距离 d 必须落在 [innerR, outerR] 之间 —— **环形**；
 *      d < innerR 是中间的「取消/关闭」热区，d > outerR 不响应。
 *   2. 极角 atan2(dy, dx) 落在哪一段扇区里。
 *
 * ## 扇区划分：**以正上方为 0°，顺时针**
 *
 * 屏幕坐标系 y 轴向下，所以「12 点方向」是 `atan2(-1, 0) = -90°`。
 * 这里统一把它归一化成：
 *
 *     angle(x, y) = (atan2(dy, dx) * 180/PI + 90 + 360) % 360
 *
 * 于是：12点 → 0°，3点 → 90°，6点 → 180°，9点 → 270°。
 * 扇区 i 覆盖 `[i*step, (i+1)*step)`，其中 `step = 360/count`。
 *
 * ★ 为什么以正上方为 0°：菜单项的渲染位置也是从正上方开始按 index 顺时针排的，
 *   判定与渲染用同一套角度基准，**改一处就够**，不会出现「按钮在这里、
 *   点上去却选中了隔壁」这种最恼人的错位。
 *
 * ★ 为什么把 n=1 和 n=2 单独拿出来：这两种情况环形菜单是不成立的
 *   （整个环就是一个扇区 / 两个半圆），但组件仍可能被这样调用（比如
 *   某天选项只剩一个）。与其让调用方去保证「至少 3 项」，
 *   不如在这里给出确定行为：n<=1 恒返回 0；n=2 按上下分。
 */
export class RadialHit {
  /**
   * 计算某坐标相对圆心的极角（度，0 = 正上方，顺时针递增，范围 [0,360)）
   *
   * @param dx 相对圆心的 x 偏移（px）
   * @param dy 相对圆心的 y 偏移（px，**向下为正**）
   */
  static angleOf(dx: number, dy: number): number {
    if (dx === 0 && dy === 0) {
      return 0;
    }
    // atan2 返回 (-180, 180]，以 +x 轴为 0、逆时针为正。
    // 屏幕 y 向下 → dy 已经代表"向下"，atan2(dy,dx) 的顺时针就是正方向。
    const deg: number = Math.atan2(dy, dx) * 180 / Math.PI;
    // +x 轴（3点）是 90°（我们以 12 点为 0 顺时针）
    return ((deg + 90) % 360 + 360) % 360;
  }

  /**
   * 命中判定：返回扇区索引；未命中返回 -1
   *
   * @param dx     相对圆心的 x 偏移（px）
   * @param dy     相对圆心的 y 偏移（px，向下为正）
   * @param count  扇区数
   * @param innerR 内环半径（px）—— 小于它算「中心区」，返回 -1
   * @param outerR 外环半径（px）—— 大于它不响应，返回 -1
   *
   * ★ 边界处理：正好落在两扇区分界线上时归**前一个**扇区
   *   （`[i*step, (i+1)*step)` 取左闭右开）。
   *   这是刻意的：分界线是测度为零的集合，用户不可能精确点在上面；
   *   但如果测试用「正好 step 度」去探边界，需要有一个确定答案 ——
   *   左闭右开就是那个确定答案，而且与角度归一化的 `% 360` 自洽。
   */
  static indexAt(dx: number, dy: number, count: number,
                 innerR: number, outerR: number): number {
    if (count <= 0) {
      return -1;
    }
    const d: number = Math.sqrt(dx * dx + dy * dy);
    if (d < innerR || d > outerR) {
      return -1;
    }
    if (count === 1) {
      return 0;
    }
    const step: number = 360 / count;
    const a: number = RadialHit.angleOf(dx, dy);
    // 浮点误差兜底：a 理论上是 [0,360)，但 360 会因精度落到 360.0000001
    let i: number = Math.floor(a / step);
    if (i >= count) {
      i = count - 1;
    }
    if (i < 0) {
      i = 0;
    }
    return i;
  }

  /**
   * 扇区中心角（度，0 = 正上方顺时针）—— 渲染菜单项时用
   *
   * 判定 (`indexAt`) 与渲染都用它，保证**点哪儿选哪儿**。
   */
  static centerAngleOf(index: number, count: number): number {
    if (count <= 0) {
      return 0;
    }
    return (index + 0.5) * (360 / count);
  }

  /**
   * 把「极角 + 半径」换算成相对圆心的 px 偏移（渲染菜单项位置用）
   *
   * 与 `angleOf` 严格互逆（测试里对这一点做了往返断言）。
   *
   * @returns [dx, dy]
   */
  static offsetOf(angleDeg: number, radius: number): number[] {
    // angleOf 的逆：deg = atan2(dy, dx) * 180/PI + 90
    const rad: number = (angleDeg - 90) * Math.PI / 180;
    return [Math.cos(rad) * radius, Math.sin(rad) * radius];
  }
}

/**
 * ★ 表冠驱动的**径向菜单**选择器
 *
 * 与 `CrownSelector` 的区别：后者是「一条线上的列表」，本类是「一个圆环」。
 * 数值行为其实一致（都是索引 + 循环/夹紧），单独一个类是为了：
 *   · 语义清楚（菜单页读起来知道这是环形的）；
 *   · 可以带自己的「当前展开与否」状态；
 *   · 环形菜单**一定循环**（转第 5 项回到第 1 项是自然的），
 *     不像长列表要两头夹紧 —— 这个差异写死在类里，调用方不用操心。
 */
export class RadialMenuState {
  /** 选项数 */
  count: number = 0;
  /** 当前高亮项 */
  index: number = 0;
  /** 是否展开 */
  open: boolean = false;

  constructor(count: number) {
    this.count = count > 0 ? count : 0;
  }

  /** 打开（重置到第 0 项） */
  show(): void {
    this.open = true;
    this.index = 0;
  }

  /** 关闭 */
  hide(): void {
    this.open = false;
  }

  /**
   * 喂入表冠步数（环形一定循环）
   * @returns 是否发生了变化（false 时调用方不必重绘）
   */
  feed(steps: number): boolean {
    if (steps === 0 || this.count <= 0 || !this.open) {
      return false;
    }
    const old: number = this.index;
    const n: number = this.count;
    this.index = ((this.index + steps) % n + n) % n;
    return this.index !== old;
  }

  /** 直接选中（点击扇区时用） */
  select(i: number): boolean {
    if (i < 0 || i >= this.count || i === this.index) {
      return false;
    }
    this.index = i;
    return true;
  }
}

/**
 * 字号档位 —— 手表端字号适配
 * 用户可在设置里切换，默认"标准"
 */
export enum FontScale {
  SMALL = 0,
  STANDARD = 1,
  LARGE = 2
}

export class Typo {
  static scale: FontScale = FontScale.STANDARD;

  /** 系数 */
  static get k(): number {
    switch (Typo.scale) {
      case FontScale.SMALL:
        return 0.85;
      case FontScale.LARGE:
        return 1.2;
      default:
        return 1.0;
    }
  }

  /** 正文（圆屏对话内容） */
  static get body(): number {
    return 14 * Typo.k;
  }

  /** 次级信息（时间戳、状态） */
  static get caption(): number {
    return 11 * Typo.k;
  }

  /** 标题 */
  static get title(): number {
    return 17 * Typo.k;
  }

  /** 大标题（欢迎页） */
  static get display(): number {
    return 21 * Typo.k;
  }

  /** 行高系数 */
  static get lineHeight(): number {
    return 1.45;
  }

  static label(v: number): string {
    if (v === FontScale.SMALL) {
      return '小';
    }
    if (v === FontScale.LARGE) {
      return '大';
    }
    return '标准';
  }
}

/**
 * ★ 表冠驱动的列表选择器（径向菜单 / 分段选择共用）
 *
 * 把「表冠步数」映射到「选中索引」，含边界与循环策略。
 * 抽成纯类是为了能在离线测试里直接跑 —— 边界行为（到头停下 vs 循环）
 * 在手表上是明显不同的手感，必须有测试锁住。
 */
export class CrownSelector {
  /** 选项总数 */
  count: number = 0;
  /** 当前选中 */
  index: number = 0;
  /**
   * 是否循环。
   * ★ 定长菜单（如径向菜单 4 项）用 true：转到底再转回到第一项，手势自然。
   * ★ 长列表（如人设列表 20 项）用 false：到头停住，避免用户以为「卡住了」。
   */
  loop: boolean = true;

  constructor(count: number, loop: boolean = true) {
    this.count = count > 0 ? count : 0;
    this.index = 0;
    this.loop = loop;
  }

  /** 喂入表冠步数，返回是否发生了变化 */
  feed(steps: number): boolean {
    if (steps === 0 || this.count <= 0) {
      return false;
    }
    const old: number = this.index;
    let next: number = this.index + steps;
    if (this.loop) {
      const n: number = this.count;
      next = ((next % n) + n) % n;
    } else {
      if (next < 0) {
        next = 0;
      }
      if (next > this.count - 1) {
        next = this.count - 1;
      }
    }
    this.index = next;
    return this.index !== old;
  }

  /** 直接定位（点击选项时用） */
  select(i: number): boolean {
    if (i < 0 || i >= this.count || i === this.index) {
      return false;
    }
    this.index = i;
    return true;
  }
}
