#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
注入测试（mutation testing）—— 故意改坏源码，确认测试变红

★ 为什么必须做（来自 skills/offline-regression-testing）：
   「从没红过的检查等于没有检查」。
   测试全绿可能是**真的都对**，也可能是**断言根本没覆盖到那条路径**。
   唯一能区分两者的办法：故意改坏一处，看测试是否报警，再还原。

用法：
  python tools/mutate.py list                 # 列出所有注入点
  python tools/mutate.py run <id>             # 注入第 id 个并跑测试
  python tools/mutate.py all                  # 全部依次注入 + 跑 + 还原
  python tools/mutate.py restore              # 还原全部
"""
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ETS = os.path.join(ROOT, 'entry', 'src', 'main', 'ets')
BAK = os.path.join(ROOT, 'tmp', 'mutate_bak')

# 注入点定义：(id, 说明, 相对路径, 原文, 替换文)
# ★ 每条都对应「一个真实可能犯的错误」，不是随便乱改
MUTATIONS = [
    (
        'thinking-dropped',
        '把 thinking 字段删掉（靠省略关闭思考 → 实际是开启，首字延迟极长）',
        'model/ApiClient.ets',
        """    // ★ 必须显式关闭思考模式，不能靠省略（省略=默认开启，实测）
    out.push('"thinking":{"type":"' + (req.thinking ? Thinking.ON : Thinking.OFF) + '"}');""",
        """    // [INJECTED] 删掉 thinking 字段
    if (req.thinking) {
      out.push('"thinking":{"type":"enabled"}');
    }""",
    ),
    (
        'sse-no-crlf',
        'SSE 分隔符不认 CRLF（部分服务端用 \\r\\n\\r\\n，会整条流解析不出来）',
        'model/ApiClient.ets',
        "    const b: number = this.buf.indexOf('\\r\\n\\r\\n');",
        "    const b: number = -1; // [INJECTED] 不认 CRLF",
    ),
    (
        'sse-no-buffer',
        'SSE 不做跨块缓冲（HTTP 分块边界会切碎 JSON，必须缓冲）',
        'model/ApiClient.ets',
        """  feed(chunk: string): string[] {
    this.buf += chunk;""",
        """  feed(chunk: string): string[] {
    this.buf = chunk; // [INJECTED] 不累积缓冲""",
    ),
    (
        'tool-args-overwrite',
        '工具参数不累加而是覆盖（arguments 是分片下发的，必须拼接）',
        'model/ApiClient.ets',
        """        const ar: Object = fn['arguments'];
        if (typeof ar === 'string') {
          cur.arguments += (ar as string);
        }""",
        """        const ar: Object = fn['arguments'];
        if (typeof ar === 'string') {
          cur.arguments = (ar as string); // [INJECTED] 覆盖而非累加
        }""",
    ),
    (
        'err-auth-collapsed',
        '鉴权失败与网络失败合并成同一文案（用户不知道该做什么）',
        'model/ApiClient.ets',
        """    if (status === 401 || status === 403) {
      return { code: ErrCode.AUTH, message: ErrMsg.AUTH };
    }""",
        """    if (status === 401 || status === 403) {
      return { code: ErrCode.AUTH, message: ErrMsg.NETWORK }; // [INJECTED] 文案复用
    }""",
    ),
    (
        'reasoning-sent-back',
        'reasoning 回传给 API（官方 API 不接受该字段，会 400）',
        'model/ApiClient.ets',
        """    parts.push('"content":' + JSON.stringify(m.content));
    return '{' + parts.join(',') + '}';""",
        """    parts.push('"content":' + JSON.stringify(m.content));
    if (m.reasoning !== undefined) {
      parts.push('"reasoning":' + JSON.stringify(m.reasoning));
    }
    return '{' + parts.join(',') + '}';""",
    ),
    (
        'trim-breaks-tool-pair',
        '裁剪时不管 tool 消息的配对关系（会产生孤立 tool → 400）',
        'model/ChatStore.ets',
        """  while (start > from && msgs[start].role === Role.TOOL) {
    start--;
  }""",
        """  // [INJECTED] 不做回溯""",
    ),
    (
        'trim-hanging-toolcalls',
        '裁剪时不处理末尾悬挂的 tool_calls（工具结果还没回来就发出去 → 400）',
        'model/ChatStore.ets',
        """  let end: number = msgs.length;
  while (end > start) {
    const last: ChatMsg = msgs[end - 1];
    const hasCalls: boolean = last.role === Role.ASSISTANT
      && last.toolCalls !== undefined
      && (last.toolCalls as ToolCall[]).length > 0;
    if (hasCalls) {
      end--;
    } else {
      break;
    }
  }""",
        """  // [INJECTED] 不处理悬挂 tool_calls
  const end: number = msgs.length;""",
    ),
    (
        'validator-blind',
        '校验器对孤立 tool 视而不见（等于把校验器废掉，测试必须能发现）',
        'model/ChatStore.ets',
        """      const at: number = pending.indexOf(id);
      if (at < 0) {
        errs.push('#' + i.toString() + ' tool(id=' + id + ') 没有对应的 assistant tool_calls');
      } else {
        pending.splice(at, 1);
      }""",
        """      // [INJECTED] 不校验 id 配对
      const at: number = pending.indexOf(id);
      if (at >= 0) {
        pending.splice(at, 1);
      }""",
    ),
    (
        'search-returns-junk',
        '解析器不校验链接（会把导航栏当成搜索结果）',
        'model/SearchService.ets',
        """    // 过滤明显无效的条目：没有链接的一律丢弃
    if (url.length === 0) {
      continue;
    }""",
        """    // [INJECTED] 不校验链接""",
    ),
    # ------------------------------------------------------------------
    #  以下为「人设 + 圆屏」新增功能的注入点（2026-10-03）
    # ------------------------------------------------------------------
    (
        'persona-inject-on-empty',
        '空 prompt 也插一条空 system（会让「未绑定人设」的会话行为改变，服务端可能拒绝）',
        'model/ChatStore.ets',
        """  const out: ChatMsg[] = [];
  if (prompt.trim().length > 0) {
    out.push({ role: Role.SYSTEM, content: prompt, ts: Date.now() });
  }""",
        """  const out: ChatMsg[] = [];
  // [INJECTED] 不判空，无条件插 system
  out.push({ role: Role.SYSTEM, content: prompt, ts: Date.now() });""",
    ),
    (
        'persona-inject-mutates-arg',
        '注入时原地改入参（ArkUI @State 会不刷新，且调用方数据被污染）',
        'model/ChatStore.ets',
        """  const out: ChatMsg[] = [];
  if (prompt.trim().length > 0) {
    out.push({ role: Role.SYSTEM, content: prompt, ts: Date.now() });
  }
  for (const m of msgs) {
    out.push(m);
  }
  return out;""",
        """  // [INJECTED] 原地改入参并返回同一个数组
  if (prompt.trim().length > 0) {
    msgs.unshift({ role: Role.SYSTEM, content: prompt, ts: Date.now() });
  }
  return msgs;""",
    ),
    (
        'persona-field-skipped',
        '拼装 prompt 时漏掉「语气」字段（四个自定义字段必须都在，用户填了却看不见）',
        'model/Persona.ets',
        """  appendSeg(segs, '语气', p.tone);""",
        """  // [INJECTED] 漏掉语气字段""",
    ),
    (
        'persona-empty-field-not-omitted',
        '空字段不省略（会输出「## 语气\\n无」，模型会真的去扮演「无」）',
        'model/Persona.ets',
        """  const v: string = value.trim();
  if (v.length === 0) {
    return;
  }
  out.push('## ' + label);
  out.push(v);""",
        """  // [INJECTED] 不跳过空字段
  out.push('## ' + label);
  out.push(value.trim().length > 0 ? value.trim() : '无');""",
    ),
    (
        'persona-id-collision',
        '新建人设的 id 只用时间戳（同毫秒连建两条会撞号，后一条被当成更新）',
        'model/Persona.ets',
        """  PersonaSeq.n++;
  return {
    id: 'p' + now.toString() + '_' + PersonaSeq.n.toString(),""",
        """  // [INJECTED] 去掉自增序号，只留时间戳
  return {
    id: 'p' + now.toString(),""",
    ),
    (
        'persona-session-legacy-broken',
        '读会话时不兼容缺少 personaId 的老数据（老用户升级后会话全读不出）',
        'model/ChatStore.ets',
        """        messages: msgs,
        // ★ 老会话没有这个键 → str() 返回空串 → 自动向前兼容
        personaId: str(o['personaId'])""",
        """        messages: msgs,
        // [INJECTED] 老数据没这个键 → 直接取出来是 undefined，破坏了 Session 契约
        personaId: o['personaId'] as string""",
    ),
    (
        'round-pct-ignores-y',
        '宽度百分比不按 y 算（回到写死 86%，圆屏底部会被圆弧切掉）',
        'common/RoundScreen.ets',
        """    const yPx: number = Unit.vp2px(yVp);
    const insetPx: number = Unit.vp2px(padVp);
    // ★ 用 Math.floor 而不是 toFixed 四舍五入（2026-10-03 测试抓出来的）：""",
        """    const yPx: number = Round.centerY; // [INJECTED] 忽略传入的 y
    const insetPx: number = Unit.vp2px(padVp);
    // ★ 用 Math.floor 而不是 toFixed 四舍五入（2026-10-03 测试抓出来的）：""",
    ),
    (
        'round-safe-circle-wrong',
        '安全圆系数不生效（用物理半径当安全半径，底部元素会越界）',
        'common/RoundScreen.ets',
        """    const r: number = Round.safeRadius;""",
        """    const r: number = Round.radius; // [INJECTED] 用了物理半径""",
    ),
    # ---- 以下 5 个注入点覆盖 2026-10-03 新增的「径向菜单 + 人设切换」----
    # 没有这些点，新增的 90 多项测试就有一半永远不可能被发现是"假绿"。
    (
        'radial-angle-not-normalized',
        '极角不归一化（3 点钟方向会得到 -270°，扇区判定全错）',
        'common/RoundScreen.ets',
        """    return ((deg + 90) % 360 + 360) % 360;""",
        """    return deg + 90; // [INJECTED] 没归一化到 [0,360)""",
    ),
    (
        'radial-angle-offset-90',
        '角度基准错 90°（以 3 点钟为 0° —— 点上方会选中右边那项）',
        'common/RoundScreen.ets',
        """    return ((deg + 90) % 360 + 360) % 360;""",
        """    return ((deg + 180) % 360 + 360) % 360; // [INJECTED] 基准错 90°""",
    ),
    (
        'radial-hit-ignores-ring',
        '命中判定忽略环形约束（圆心附近也算命中，中心按钮抢不到点击）',
        'common/RoundScreen.ets',
        """    const d: number = Math.sqrt(dx * dx + dy * dy);
    if (d < innerR || d > outerR) {
      return -1;
    }""",
        """    const d: number = Math.sqrt(dx * dx + dy * dy);
    // [INJECTED] 环形约束被去掉，整个屏幕都算命中
    if (false) {
      return -1;
    }""",
    ),
    (
        'radial-offset-not-inverse',
        'offsetOf 与 angleOf 不互逆（菜单项画的位置与判定角度对不上）',
        'common/RoundScreen.ets',
        """    const rad: number = (angleDeg - 90) * Math.PI / 180;
    return [Math.cos(rad) * radius, Math.sin(rad) * radius];""",
        """    const rad: number = angleDeg * Math.PI / 180; // [INJECTED] 少了 -90，不再互逆
    return [Math.cos(rad) * radius, Math.sin(rad) * radius];""",
    ),
    (
        'menu-feed-ignores-open',
        '表冠在菜单收起时也生效（会改到用户看不见的选中项）',
        'common/RoundScreen.ets',
        """    if (steps === 0 || this.count <= 0 || !this.open) {
      return false;
    }""",
        """    if (steps === 0 || this.count <= 0) {
      return false;
    }""",
    ),
    (
        'persona-switch-clears-history',
        '换人设时清空历史（用户会觉得"换个人设把我聊天记录弄没了"）',
        'model/ChatStore.ets',
        """    s.personaId = personaId;
    await ChatStore.save(s);
    return true;
  }""",
        """    s.personaId = personaId;
    s.messages = []; // [INJECTED] 顺带清空历史
    await ChatStore.save(s);
    return true;
  }""",
    ),
    (
        'persona-fresh-always',
        '换人设时无脑建议开新对话（连"没人设→绑上"这种升级场景也提示）',
        'model/ChatStore.ets',
        """  if (oldP === null || newP === null) {
    return false;
  }
  if (oldP.id === newP.id) {
    return false;
  }
  return !isBlankPersona(oldP) && !isBlankPersona(newP);""",
        """  return true; // [INJECTED] 无脑建议开新对话""",
    ),
    (
        'persona-index-not-redundant',
        '索引里不冗余存 personaId（历史列表要加载全部消息体才知道人设）',
        'model/ChatStore.ets',
        """        count: s.messages.length,
        personaId: s.personaId
      });""",
        """        count: s.messages.length,
        personaId: '' // [INJECTED] 索引里不存人设
      });""",
    ),
]


def path_of(rel):
    return os.path.join(ETS, rel.replace('/', os.sep))


def backup_all():
    """
    备份所有会被注入的文件

    ★★ 这里修过一个**会毁掉工作**的 Bug（2026-10-03，真事故）：
      原来是 `if not os.path.exists(dst): shutil.copy2(...)` ——
      意思是「备份**只做一次**，以后永远用第一次那版」。
      后果：我把源码改好之后跑注入测试，`restore_all()` 会把文件
      **还原成第一次备份的那个旧版本**，新写的代码**静默消失**。
      当时的表现是「刚加的 injectSystem 不见了」，排查了很久才想到是脚本干的。

    现在改成：**每次运行都重新备份**（备份的永远是「本次运行前的状态」），
    并且写完校验一次，确保备份成功再开始注入。
    """
    os.makedirs(BAK, exist_ok=True)
    for rel in set(m[2] for m in MUTATIONS):
        src = path_of(rel)
        dst = os.path.join(BAK, rel.replace('/', '__'))
        shutil.copy2(src, dst)
        # ★ 写完读回校验：备份是最后的安全网，它必须真的对
        a = io.open(src, encoding='utf-8').read()
        b = io.open(dst, encoding='utf-8').read()
        if a != b:
            raise RuntimeError('备份校验失败（内容不一致）: ' + rel)


def restore(rel):
    src = os.path.join(BAK, rel.replace('/', '__'))
    if os.path.exists(src):
        shutil.copy2(src, path_of(rel))
        return True
    print('  ✗ 还原失败（没有备份）: ' + rel)
    return False


def restore_all():
    for rel in set(m[2] for m in MUTATIONS):
        restore(rel)


def apply_mutation(m):
    mid, desc, rel, old, new = m
    p = path_of(rel)
    s = io.open(p, encoding='utf-8').read()
    if old not in s:
        print('  ✗ 锚点未找到，注入失败: ' + mid)
        return False
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    return True


def run_tests():
    """
    跑**全部**离线测试套件

    ★ 2026-10-03：原先只跑 api-protocol-test.mjs，导致「注入点落在
      Persona / RoundScreen 里」时**永远来不及被捕获** —— 注入是生效了，
      但没有任何测试去看那两个文件，脚本就会报「未被捕获」，
      而那**不代表测试无效**，只代表测试没跑到。
      所以这里必须把所有套件都跑一遍，任何一个红灯都算「被捕获」。
    """
    suites = ['api-protocol-test.mjs', 'persona-round-test.mjs']
    any_fail = False
    all_out = []
    for name in suites:
        r = subprocess.run(
            ['node', os.path.join(ROOT, 'tools', name)],
            cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='ignore'
        )
        out = r.stdout + r.stderr
        all_out.append('# ' + name + '\n' + out)
        # 套件自身崩了（非 0 且不是断言失败）也算被捕获
        if r.returncode != 0 or '全部通过' not in out:
            any_fail = True

    out = '\n'.join(all_out)
    fails = [l for l in out.split('\n') if l.strip().startswith('✗')]
    return (not any_fail), fails, out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    cmd = sys.argv[1]
    backup_all()

    if cmd == 'list':
        for i, m in enumerate(MUTATIONS):
            print('%2d  %-26s %s' % (i, m[0], m[1]))
        return

    if cmd == 'restore':
        restore_all()
        print('已还原全部注入')
        return

    if cmd == 'all':
        bad = 0
        for i, m in enumerate(MUTATIONS):
            restore_all()
            if not apply_mutation(m):
                bad += 1
                continue
            ok_green, fails, out = run_tests()
            status = '✅ 被捕获' if not ok_green else '❌ 未捕获（假绿！）'
            print('%2d  %-26s %s' % (i, m[0], status))
            if not ok_green:
                for f in fails[:4]:
                    print('        ' + f.strip())
            else:
                bad += 1
            restore_all()
        print()
        if bad == 0:
            print('★ 全部 %d 个注入都被捕获，测试有效。' % len(MUTATIONS))
        else:
            print('★★ 有 %d 个注入**未被捕获** —— 这些路径的测试是假绿，必须补断言。' % bad)
            sys.exit(1)
        return

    if cmd == 'run':
        i = int(sys.argv[2])
        restore_all()
        m = MUTATIONS[i]
        if not apply_mutation(m):
            return
        print('注入: ' + m[0] + ' — ' + m[1])
        ok_green, fails, out = run_tests()
        print('测试结果: ' + ('全绿（★ 未捕获！）' if ok_green else '变红（被捕获 ✓）'))
        for f in fails[:8]:
            print('  ' + f.strip())
        restore_all()
        print('已还原')
        return

    print(__doc__)


if __name__ == '__main__':
    main()
