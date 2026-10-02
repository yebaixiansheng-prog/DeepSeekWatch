/**
 * 设计令牌（Design Tokens）—— 全应用唯一的颜色/圆角/间距/动效出口
 *
 * ★ 2026-10-03 新增（用户要求「统一视觉风格、更现代直观」）
 *
 * 为什么必须抽出来：
 *   升级前的配色**散落在 3 个文件里**，同一个语义有 5 种写法 ——
 *   比如「次要文字」在 ChatPage 里就有 `#8A8F9A` / `#6E7380` /
 *   `#5A5F6B` / `#4A4F5A` / `#3E434E` 五种色值。
 *   这不是「细微的层次差异」，是**没有层次**：改一次主题要翻五个文件，
 *   而且改不全。任何新页面都会再引入第六种。
 *
 * 纪律：
 *   · 页面里**不出现任何字面色值**（`#xxxxxx`）。
 *     需要新语义 → 先在这里加一个令牌，再用它的名字。
 *   · 令牌命名按**用途**而非外观（`textSub` 而不是 `gray2`）——
 *     后者在换主题时会变成谎言。
 *
 * 圆屏可读性（来自真机实测，不是拍脑袋）：
 *   466px 圆屏在强光下对比度衰减明显，正文与背景的亮度差必须够大。
 *   本文件的 text/bg 对比度约 14:1（WCAG AAA 要求 7:1），
 *   即使是 textSub 也有约 6:1。
 */

/** 颜色令牌 */
export class Color {
  /** 屏幕底色（纯黑：OLED 手表省电，且圆屏裁切后边缘无痕） */
  static readonly bg: string = '#000000';

  /** 一级容器（卡片、输入框、列表项） */
  static readonly surface: string = '#12141A';
  /** 二级容器（浮层、选中态背景、次级卡片） */
  static readonly surfaceAlt: string = '#16181F';
  /** 三级容器（内嵌块，如思考内容区） */
  static readonly surfaceSunken: string = '#0E1014';
  /** 分隔线 / 描边 */
  static readonly border: string = '#242833';

  /** 主色（品牌蓝，用于主按钮、强调、光标、开关） */
  static readonly primary: string = '#4D6BFE';
  /** 主色浅色（用于正文高亮、图标） */
  static readonly primaryText: string = '#7B93FF';
  /** 主色深色（用户气泡背景 —— 比 primary 暗一档，白字才压得住） */
  static readonly primaryDeep: string = '#3352CC';
  /** 主色极暗（选中项的柔和背景） */
  static readonly primaryDim: string = '#1B2140';

  /** 主文字（正文、标题） */
  static readonly text: string = '#E8EAED';
  /** 次要文字（说明、值、时间戳） */
  static readonly textSub: string = '#8A8F9A';
  /** 弱化文字（占位符、辅助说明） */
  static readonly textFaint: string = '#5A5F6B';
  /** 极弱文字（页脚、版本号） */
  static readonly textGhost: string = '#3E434E';
  /** 主色底上的文字（永远用纯白，不用 text —— 蓝色底上 text 会偏灰） */
  static readonly onPrimary: string = '#FFFFFF';

  /** 危险色（删除、清空） */
  static readonly danger: string = '#FF6B6B';
  /** 危险色的容器背景 */
  static readonly dangerDim: string = '#1A1214';

  /** 成功色（搜索完成、保存成功） */
  static readonly success: string = '#3DD68C';

  /** 禁用态的填充 */
  static readonly disabled: string = '#2A2E3A';
  /** 遮罩（径向菜单展开时压暗背景） */
  static readonly scrim: string = '#CC000000';
}

/** 圆角令牌（vp） */
export class Radius {
  /** 胶囊（按钮、输入框、圆形图标按钮） */
  static readonly pill: number = 999;
  /** 卡片 */
  static readonly card: number = 14;
  /** 小卡片 / 气泡 */
  static readonly small: number = 12;
  /** 内嵌块 */
  static readonly chip: number = 8;
}

/** 间距令牌（vp）—— 圆屏纵向空间极紧，取值必须克制 */
export class Space {
  /** 4 —— 紧邻元素（图标与文字） */
  static readonly xs: number = 4;
  /** 6 —— 同组元素 */
  static readonly sm: number = 6;
  /** 10 —— 组间 */
  static readonly md: number = 10;
  /** 16 —— 区块间 */
  static readonly lg: number = 16;
}

/** 触控尺寸（vp）—— 华为圆屏规范：最小触控区 96px = 48vp */
export class Touch {
  /** 大按钮高（48vp = 96px，达标） */
  static readonly hLg: number = 48;
  /** 中按钮高（40vp = 80px，实用下限） */
  static readonly hMd: number = 40;
  /** 小按钮 / 图标按钮高（36vp = 72px，仅用于非关键操作） */
  static readonly hSm: number = 36;
  /** 列表项高 */
  static readonly rowH: number = 50;
  /** 设置项高 */
  static readonly setH: number = 46;
  /** 顶栏高 */
  static readonly barH: number = 34;
}

/** 透明度令牌（动效与层级用，避免各处写魔法数字） */
export class Opacity {
  static readonly full: number = 1.0;
  static readonly high: number = 0.85;
  static readonly mid: number = 0.6;
  static readonly low: number = 0.35;
  static readonly ghost: number = 0.18;
}

/** 动效时长（ms）—— 手表动效要快，超过 250ms 会显得迟钝 */
export class Motion {
  /** 微反馈（按压、开关） */
  static readonly fast: number = 120;
  /** 常规切换（页面元素进出） */
  static readonly base: number = 200;
  /** 大动作（径向菜单展开） */
  static readonly slow: number = 260;
}

/** 曲线（ArkUI 字符串形式，供 animateTo / animation 使用） */
export class Curve {
  /** 标准缓动：进场快、收尾缓 */
  static readonly standard: string = 'cubic-bezier(0.2, 0, 0.2, 1)';
  /** 强调缓动：用于径向菜单这类需要「弹一下」的动作 */
  static readonly emphasized: string = 'cubic-bezier(0.05, 0.7, 0.1, 1)';
}
