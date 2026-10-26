"""定点复现：Login Demo → 输入 → back，打印每步真实返回。"""
import json
import os
import subprocess
import sys

ROOT = '/Users/xiexianbin/dev/git/github/xb_scaffold'
PKG = os.path.join(ROOT, 'xb_ume')


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(['dart', 'run', 'bin/mcp.dart'], cwd=PKG,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
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


def text_of(r):
    for c in r.get('content', []):
        if c.get('type') == 'text':
            return c.get('text', '')
    return ''


def show(tag, r, n=600):
    print(f'\n=== {tag} {"ERR" if r.get("isError") else "OK"} ===')
    print(text_of(r)[:n])


def items(r):
    return (r.get('structuredContent') or {}).get('items') or []


def main():
    uri = sys.argv[sys.argv.index('--uri') + 1] if '--uri' in sys.argv else None
    c = Client()
    try:
        c.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                             'clientInfo': {'name': 'probe', 'version': '0'}})
        c.rpc('tools/list')
        show('use_session', c.call('xbume_use_session', {'sessionId': f's{uri}'}))
        show('route_stack(now)', c.call('xbume_route_stack', {}))
        # 先回到 /
        for i in range(3):
            r = c.call('xbume_navigate', {'back': True})
            if r.get('isError'):
                print(f'back#{i} -> {text_of(r)[:200]}')
                break
            print(f'back#{i} -> ok')
        show('route_stack(after reset)', c.call('xbume_route_stack', {}))

        ld = c.call('xbume_find_widget', {'by': 'text', 'value': 'Login Demo', 'exact': True})
        # 可能有多个同名文本（首页按钮 / 登录页 AppBar 标题），取窗口内最靠左的那个
        li = [it for it in items(ld) if (it.get('bounds') or {}).get('x', 9999) < 800]
        li.sort(key=lambda it: (it.get('bounds') or {}).get('y', 0))
        if not li:
            print('!! 找不到 Login Demo')
            return 1
        show('tap(Login Demo)', c.call('xbume_tap', {'ref': li[0]['ref'], 'waitMs': 700}))
        et = c.call('xbume_find_widget', {'by': 'type', 'value': 'EditableText', 'limit': 3})
        ei = items(et)
        show('find(EditableText)', et, 300)
        if ei:
            show('tap(EditableText)', c.call('xbume_tap', {'ref': ei[0]['ref'], 'waitMs': 400}))
            show('input', c.call('xbume_input', {'text': 'hello-xb-ume'}))
        show('route_stack(before back)', c.call('xbume_route_stack', {}))
        show('navigate(back)', c.call('xbume_navigate', {'back': True}))
        show('route_stack(after back)', c.call('xbume_route_stack', {}))
    finally:
        c.close()


if __name__ == '__main__':
    main()
