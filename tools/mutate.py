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
]


def path_of(rel):
    return os.path.join(ETS, rel.replace('/', os.sep))


def backup_all():
    os.makedirs(BAK, exist_ok=True)
    for rel in set(m[2] for m in MUTATIONS):
        src = path_of(rel)
        dst = os.path.join(BAK, rel.replace('/', '__'))
        if not os.path.exists(dst):
            shutil.copy2(src, dst)


def restore(rel):
    src = os.path.join(BAK, rel.replace('/', '__'))
    if os.path.exists(src):
        shutil.copy2(src, path_of(rel))


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
    r = subprocess.run(
        ['node', os.path.join(ROOT, 'tools', 'api-protocol-test.mjs')],
        cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='ignore'
    )
    out = r.stdout + r.stderr
    got_pass = '全部通过' in out
    fails = [l for l in out.split('\n') if l.strip().startswith('✗')]
    return got_pass, fails, out


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
