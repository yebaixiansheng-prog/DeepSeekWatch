/**
 * 圆形表盘几何适配
 *
 * 设计要点（华为官方圆形屏规范）：
 * 1. 手表实际只显示"内切圆"区域，四角内容会被裁掉
 * 2. 关键信息必须落在内切圆内，安全区半径 = 屏宽/2 * 0.88
 * 3. 正文 12-14fp，标题 16-20fp（手表字号必须比手机小）
 * 4. 触控区最小 96px × 96px
 */

export class Round {
  /** 屏宽（px），运行时由 window 获取 */
  static screenW: number = 466;
  static screenH: number = 466;

  /** 内切圆半径 */
  static get radius(): number {
    return Math.min(Round.screenW, Round.screenH) / 2;
  }

  /**
   * 安全半径：内容不越界系数 0.88
   * 官方建议关键内容避开边缘，留出表冠/防误触余量
   */
  static get safeRadius(): number {
    return Round.radius * 0.88;
  }

  /** 内容可用宽度（安全圆内接正方形边长） */
  static get contentW(): number {
    return Round.safeRadius * Math.SQRT2;
  }

  /**
   * 宽度百分比换算：把 px 宽度转成相对屏宽的百分比字符串
   *
   * 圆形屏上直接用 '86%' 这类固定百分比并不安全 ——
   * 同一个百分比在顶部/底部区域会越出圆弧。这里统一走 px → %，
   * 保证所有横向尺寸都以「安全圆」为基准计算。
   */
  static wPct(wPx: number): string {
    if (Round.screenW <= 0) {
      return '86%';
    }
    const pct: number = (wPx / Round.screenW) * 100;
    return Math.max(20, Math.min(100, pct)).toFixed(0) + '%';
  }

  /** 安全宽度（px），即安全圆内的最大可用横向尺寸 */
  static get safeW(): number {
    return Round.safeRadius * 2;
  }

  /**
   * 第 row 行（0-based）可用的水平宽度（px）
   * 越靠近顶部/底部，可用宽度越窄 —— 这是圆形屏排版的核心
   * @param row 行索引
   * @param totalRows 总行数
   */
  static rowWidth(row: number, totalRows: number): number {
    if (totalRows <= 1) {
      return Round.contentW;
    }
    // 将该行映射到 [-1, 1] 的纵向位置
    const t: number = (row / (totalRows - 1)) * 2 - 1;
    // 圆方程 x = sqrt(r^2 - (t*r)^2)
    const halfW: number = Math.sqrt(Math.max(0,
      Round.safeRadius * Round.safeRadius - Math.pow(t * Round.safeRadius, 2)));
    return halfW * 2;
  }

  /**
   * 计算某一纵向偏移处的可用内容宽度
   * @param yOffset 相对圆心的纵向偏移（px），正=向下
   */
  static widthAtY(yOffset: number): number {
    const r: number = Round.safeRadius;
    const d: number = Math.min(Math.abs(yOffset), r);
    return Math.sqrt(Math.max(0, r * r - d * d)) * 2;
  }

  /**
   * 顶部安全内边距（px）
   *
   * 圆形屏顶部圆弧收得很快，如果内容从 y=0 开始排布，
   * 第一行会被切掉两角。这里给出「圆心正上方第一行」的建议留白。
   */
  static get topInset(): number {
    // 安全圆顶点到屏幕顶点的距离
    return Math.max(0, Round.radius - Round.safeRadius);
  }

  /** 该点是否在安全圆内 */
  static inside(x: number, y: number): boolean {
    const cx: number = Round.screenW / 2;
    const cy: number = Round.screenH / 2;
    const dx: number = x - cx;
    const dy: number = y - cy;
    return Math.sqrt(dx * dx + dy * dy) <= Round.safeRadius;
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
}
