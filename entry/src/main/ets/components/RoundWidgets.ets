import { Typo } from '../common/RoundScreen';

/**
 * 圆形表盘通用组件
 *
 * 注意：只保留实际被页面引用的组件，避免打包体积膨胀。
 * 命名统一 Round* 前缀，方便打包方识别这是圆屏定制件。
 */

/** 主按钮（圆形屏友好：胶囊形 + 大触控区，满足 96px 最小触控规范） */
@Component
export struct RoundButton {
  @Prop label: string = '';
  @Prop primary: boolean = true;
  @Prop enabledState: boolean = true;
  /** 宽度占屏比（0-1），由页面按安全圆传入 */
  @Prop widthRatio: number = 0.62;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .type(ButtonType.Capsule)
      .width((this.widthRatio * 100).toFixed(0) + '%')
      .height(48)
      .fontSize(Typo.title)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.primary ? '#FFFFFF' : '#C8CCD4')
      .backgroundColor(this.primary
        ? (this.enabledState ? '#4D6BFE' : '#2A2E3A')
        : '#1C1F27')
      .enabled(this.enabledState)
      .onClick(() => {
        if (this.enabledState) {
          this.onTap();
        }
      })
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
  @Prop widthRatio: number = 0.84;
  @Link on: boolean;
  onChange: (v: boolean) => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(Typo.body)
          .fontColor('#E8EAED')
          .maxLines(1)
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(Typo.caption - 1)
            .fontColor('#6E7380')
            .maxLines(1)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor('#4D6BFE')
        .switchPointColor('#FFFFFF')
        .onChange((v: boolean) => {
          // 只上报，不写回 this.on（父级是唯一数据源）
          this.onChange(v);
        })
    }
    .width((this.widthRatio * 100).toFixed(0) + '%')
    // ⚠️ 466 圆形屏上 1vp = 2px，高度写 58 就是 116px，两行开关就把浮层撑爆了。
    //    46vp(=92px) 是「触控够大 + 浮层放得下」的折中。
    .height(46)
    .padding({ left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor('#12141A')
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
  @Prop widthRatio: number = 0.84;
  @Link selected: number;
  onSelect: (index: number) => void = () => {
  };

  build() {
    Row() {
      ForEach(this.items, (item: string, idx: number) => {
        Text(item)
          .fontSize(Typo.body)
          .fontWeight(this.selected === idx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selected === idx ? '#FFFFFF' : '#8A8F9A')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.selected === idx ? '#4D6BFE' : Color.Transparent)
          .onClick(() => {
            // 已是当前项则不重复触发
            if (this.selected === idx) {
              return;
            }
            this.onSelect(idx);
          })
      }, (item: string, idx: number) => item + idx.toString())
    }
    .width((this.widthRatio * 100).toFixed(0) + '%')
    .padding(3)
    .borderRadius(23)
    .backgroundColor('#16181F')
  }
}
