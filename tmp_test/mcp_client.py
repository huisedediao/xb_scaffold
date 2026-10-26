#!/usr/bin/env python3
"""MCP stdio 端到端冒烟：单进程连续调用核心工具并打印摘要。

用法：
  python3 tmp_test/mcp_client.py [--uri 58829]
"""
import base64
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'xb_ume')
OUT = os.path.join(ROOT, 'tmp_test')


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(
            ['dart', 'run', 'bin/mcp.dart'],
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
            raise RuntimeError('server closed')
        return json.loads(line)

    def call(self, name, args=None):
        r = self.rpc('tools/call', {'name': name, 'arguments': args or {}})
        if 'error' in r:
            return {'__rpc_error': r['error']}
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


def summarize(name, result):
    is_err = result.get('isError') is True
    sc = result.get('structuredContent') or {}
    txt = text_of(result)
    print(f'\n=== {name} {"[ERROR]" if is_err else "OK"} ===')
    if txt:
        print(txt[:1200])
    if sc:
        keys = list(sc.keys())
        print(f'  structured keys: {keys}')


def save_shot(result, path):
    for c in result.get('content', []):
        if c.get('type') == 'image':
            raw = base64.b64decode(c['data'])
            with open(path, 'wb') as f:
                f.write(raw)
            print(f'  截图已保存 {path} ({len(raw)} bytes)')
            return True
    return False


def main():
    uri = None
    if '--uri' in sys.argv:
        uri = sys.argv[sys.argv.index('--uri') + 1]
    c = Client()
    try:
        init = c.rpc('initialize', {
            'protocolVersion': '2025-06-18',
            'capabilities': {},
            'clientInfo': {'name': 'smoke', 'version': '0'},
        })
        print('initialize:', json.dumps(init.get('result', {}), ensure_ascii=False))

        tools = c.rpc('tools/list')
        names = [t['name'] for t in tools['result']['tools']]
        print(f'tools/list: {len(names)} -> {", ".join(names)}')

        s = c.call('xbume_sessions', {})
        summarize('xbume_sessions', s)
        sessions = (s.get('structuredContent') or {}).get('sessions') or []
        if not sessions:
            print('!! 没有会话，先启动 example：cd xb_ume/example && flutter run -d macos')
            return 1
        sid = uri and f's{uri}' or sessions[0]['id']
        summarize('xbume_use_session', c.call('xbume_use_session', {'sessionId': sid}))

        shot = c.call('xbume_screenshot', {'savePath': os.path.join(OUT, 'mcp_shot.png')})
        summarize('xbume_screenshot', shot)
        save_shot(shot, os.path.join(OUT, 'mcp_shot.png'))

        summarize('xbume_route_stack', c.call('xbume_route_stack', {}))

        fw = c.call('xbume_find_widget', {'by': 'type', 'value': 'ElevatedButton', 'limit': 5})
        summarize('xbume_find_widget(type=ElevatedButton)', fw)
        items = (fw.get('structuredContent') or {}).get('items') or []

        # 1) 按文本定位并点击 Push Route（→ /detail），再返回
        ft = c.call('xbume_find_widget', {'by': 'text', 'value': 'Push Route', 'exact': True})
        titems = (ft.get('structuredContent') or {}).get('items') or []
        if titems:
            summarize('xbume_tap(Push Route)', c.call('xbume_tap', {'ref': titems[0]['ref'], 'waitMs': 700}))
            summarize('xbume_route_stack(/detail)', c.call('xbume_route_stack', {}))
            summarize('xbume_navigate(back)', c.call('xbume_navigate', {'back': True}))
        else:
            print('!! 未找到 Push Route 文本，跳过导航用例')

        # 2) Add Log → console 应新增一条
        al = c.call('xbume_find_widget', {'by': 'text', 'value': 'Add Log', 'exact': True})
        alitems = (al.get('structuredContent') or {}).get('items') or []
        if alitems:
            summarize('xbume_tap(Add Log)', c.call('xbume_tap', {'ref': alitems[0]['ref'], 'waitMs': 300}))
            summarize('xbume_console(after add)', c.call('xbume_console', {'keyword': 'hello', 'limit': 3}))

        # 3) Dio Request → network 应新增一条
        dr = c.call('xbume_find_widget', {'by': 'text', 'value': 'Dio Request', 'exact': True})
        dritems = (dr.get('structuredContent') or {}).get('items') or []
        if dritems:
            summarize('xbume_tap(Dio Request)', c.call('xbume_tap', {'ref': dritems[0]['ref'], 'waitMs': 1200}))
            summarize('xbume_network(limit 3)', c.call('xbume_network', {'limit': 3}))

        # 3.5) 输入：Login Demo → 点输入框 → 写文本 → 校验
        ld = c.call('xbume_find_widget', {'by': 'text', 'value': 'Login Demo', 'exact': True})
        lditems = (ld.get('structuredContent') or {}).get('items') or []
        if lditems:
            summarize('xbume_tap(Login Demo)', c.call('xbume_tap', {'ref': lditems[0]['ref'], 'waitMs': 700}))
            et = c.call('xbume_find_widget', {'by': 'type', 'value': 'EditableText', 'limit': 3})
            summarize('xbume_find_widget(type=EditableText)', et)
            eitems = (et.get('structuredContent') or {}).get('items') or []
            if eitems:
                summarize('xbume_tap(EditableText)',
                          c.call('xbume_tap', {'ref': eitems[0]['ref'], 'waitMs': 400}))
                summarize('xbume_input', c.call('xbume_input', {'text': 'hello-xb-ume'}))
                vf = c.call('xbume_find_widget', {'by': 'text', 'value': 'hello-xb-ume', 'exact': True})
                summarize('xbume_find_widget(verify typed)', vf)
            summarize('xbume_navigate(back from login)', c.call('xbume_navigate', {'back': True}))

        # 4) 方向滑动
        summarize('xbume_swipe(down)', c.call('xbume_swipe', {'direction': 'down', 'distance': 200}))
        summarize('xbume_swipe(up)', c.call('xbume_swipe', {'direction': 'up', 'distance': 200}))

        # 5) 内联场景：断言可见 → 点 Push Route → 路由 /detail → 返回
        sc = c.call('xbume_scenario_run', {
            'steps': [
                {'type': 'assertVisible', 'widget': 'ElevatedButton'},
                {'type': 'tap', 'x': 616, 'y': 88},
                {'type': 'wait', 'ms': 600},
                {'type': 'assertRoute', 'name': '/detail'},
                {'type': 'back'},
                {'type': 'wait', 'ms': 600},
                {'type': 'assertRoute', 'name': '/'},
            ],
            'continueOnFail': False,
        })
        summarize('xbume_scenario_run(inline)', sc)
        run_id = (sc.get('structuredContent') or {}).get('runId')
        for _ in range(30):
            st = c.call('xbume_scenario_status', {'runId': run_id} if run_id else {})
            if 'running' in (st.get('structuredContent') or {}) and not st['structuredContent']['running']:
                break
            import time
            time.sleep(0.5)
        summarize('xbume_scenario_status', st)
        summarize('xbume_report', c.call('xbume_report', {'runId': run_id} if run_id else {}))

        summarize('xbume_scenario_list', c.call('xbume_scenario_list', {}))

        # 错误路径：未选择会话 / 未知工具 / 参数缺失
        summarize('xbume_tap(no target)', c.call('xbume_tap', {}))
        bad = c.rpc('tools/call', {'name': 'not_exist', 'arguments': {}})
        print('\n=== unknown tool ===')
        print(json.dumps(bad.get('error', {}), ensure_ascii=False)[:300])
        return 0
    finally:
        c.close()


if __name__ == '__main__':
    sys.exit(main())
