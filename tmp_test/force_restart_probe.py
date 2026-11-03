#!/usr/bin/env python3
"""实测：xbume_app_launch(force:true) 是否等价 GUI 调试页「停止」+「启动 / 复用」。

对应用户场景：有些修改必须重新运行才能验证（pubspec / 原生 / main() 初始化）。

流程（macOS example，不碰手机）：
  1. 起 MCP 服务（stdio，--tool-groups all）
  2. app_launch 首次拉起（构建 macOS app，慢）
  3. app_launch 再调一次 -> 期望 reused=true（等价「复用」按钮）
  4. 改 example/lib/main.dart 的启动标记 v1 -> v2（模拟「必须重启才生效」的改动）
  5. app_launch force:true -> 期望 reused=false + 新 pid（等价「停止」+「启动」）
  6. debug_output action=log 读落盘日志，确认新进程输出 v2
  7. 收尾：debug_control stop 停掉自己起的会话，还原 main.dart

用法：python3 tmp_test/force_restart_probe.py
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'xb_ume')
EXAMPLE = os.path.join(ROOT, 'example')
MAIN = os.path.join(EXAMPLE, 'lib', 'main.dart')
MARK = '[[FORCE_PROBE]]'


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(
            ['dart', 'run', 'bin/mcp.dart', '--tool-groups', 'all'],
            cwd=PKG,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self.seq = 0

    def rpc(self, method, params=None):
        self.seq += 1
        msg = {'jsonrpc': '2.0', 'id': self.seq, 'method': method}
        if params is not None:
            msg['params'] = params
        self.proc.stdin.write(json.dumps(msg) + '\n')
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError('MCP server closed')
        return json.loads(line)

    def call(self, name, args=None):
        r = self.rpc('tools/call', {'name': name, 'arguments': args or {}})
        if 'error' in r:
            return {'isError': True, 'content': [{'type': 'text',
                                                  'text': f"rpc error: {r['error']}"}]}
        return r.get('result', {})

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def text_of(result):
    for c in result.get('content', []):
        if c.get('type') == 'text':
            return c.get('text', '')
    return ''


def sc_of(result):
    return result.get('structuredContent') or {}


def show(name, r, limit=900):
    tag = 'ERROR' if r.get('isError') else 'OK'
    print(f'\n=== {name} [{tag}] ===')
    print(text_of(r)[:limit])
    sc = sc_of(r)
    if sc:
        print(f'  structured: { {k: sc[k] for k in list(sc)[:12]} }')


def set_mark(version):
    """把启动标记写成指定版本（放在 main() 第一行，只有新进程才会打印）。"""
    src = open(MAIN, encoding='utf-8').read()
    lines = src.split('\n')
    out = []
    for line in lines:
        if MARK in line:
            continue
        out.append(line)
        if line.strip() == 'void main() {':
            out.append(f"  debugPrint('{MARK} boot {version}');")
    open(MAIN, 'w', encoding='utf-8').write('\n'.join(out))
    print(f'  main.dart 启动标记 -> {version}')


def restore_main():
    subprocess.run(['git', 'checkout', '--', MAIN], cwd=ROOT, check=False)
    print('  main.dart 已还原')


def launch(c, force, timeout_ms=600000):
    return c.call('xbume_app_launch', {
        'deviceId': 'macos',
        'via': 'flutter-run',
        'cwd': EXAMPLE,
        'target': 'lib/main.dart',
        'platform': 'macos',
        'waitVm': True,
        'force': force,
        'timeoutMs': timeout_ms,
    })


def main():
    set_mark('v1')
    c = Client()
    sid = None
    try:
        c.rpc('initialize', {
            'protocolVersion': '2025-06-18',
            'capabilities': {},
            'clientInfo': {'name': 'force-probe', 'version': '0'},
        })

        t0 = time.time()
        r1 = launch(c, False)
        show(f'① 首次启动（{time.time() - t0:.0f}s）', r1)
        sc1 = sc_of(r1)
        pid1 = sc1.get('pid')
        sid = sc1.get('sessionId')

        r2 = launch(c, False)
        show('② 再调一次（期望 reused=true）', r2)
        pid2 = sc_of(r2).get('pid')

        set_mark('v2')
        t1 = time.time()
        r3 = launch(c, True)
        show(f'③ force:true 重启（{time.time() - t1:.0f}s）', r3)
        sc3 = sc_of(r3)
        pid3 = sc3.get('pid')
        sid = sc3.get('sessionId') or sid

        r4 = c.call('xbume_debug_output', {
            'action': 'log', 'keyword': MARK, 'lines': 400, 'sessionId': sid,
        })
        show('④ 读落盘日志找新启动标记', r4, limit=1200)
        log_text = text_of(r4)

        print('\n--- 判定 ---')
        print(f'pid: 首次={pid1}  复用={pid2}  重启后={pid3}')
        print(f'reused: 首次={sc1.get("reused")}  第二次={sc_of(r2).get("reused")}  '
              f'force={sc3.get("reused")}')
        print(f'v2 出现在日志: {"是" if "boot v2" in log_text else "否"}')
        ok = (sc1.get('reused') is False
              and sc_of(r2).get('reused') is True
              and sc3.get('reused') is False
              and pid3 != pid1
              and 'boot v2' in log_text)
        print(f'结论: {"PASS" if ok else "FAIL"}')
        return 0 if ok else 1
    finally:
        if sid:
            print('\n--- 收尾：停掉本次拉起的会话 ---')
            show('stop', c.call('xbume_debug_control', {'action': 'stop', 'sessionId': sid}))
        c.close()
        restore_main()


if __name__ == '__main__':
    sys.exit(main())
