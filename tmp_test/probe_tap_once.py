"""点一次 Login Demo 后分时刻观察路由栈，确认 push 是否真的生效。"""
import base64
import json
import os
import subprocess
import sys
import time

PKG = '/Users/xiexianbin/dev/git/github/xb_scaffold/xb_ume'


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
        return json.loads(self.proc.stdout.readline())

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


def items(r):
    return (r.get('structuredContent') or {}).get('items') or []


def main():
    uri = sys.argv[sys.argv.index('--uri') + 1]
    c = Client()
    try:
        c.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                             'clientInfo': {'name': 'p', 'version': '0'}})
        c.rpc('tools/list')
        c.call('xbume_use_session', {'sessionId': f's{uri}'})
        print('stack0:', text_of(c.call('xbume_route_stack', {})))

        ld = c.call('xbume_find_widget', {'by': 'text', 'value': 'Login Demo', 'exact': True})
        cand = [it for it in items(ld) if (it.get('bounds') or {}).get('x', 9999) < 800]
        if not cand:
            print('!! 首页没有 Login Demo 按钮')
            return 1
        ref = cand[0]['ref']
        print('tap ref', ref, cand[0]['bounds'])
        print('tap:', text_of(c.call('xbume_tap', {'ref': ref, 'waitMs': 0})))
        for t in (100, 400, 1200):
            time.sleep(t / 1000.0)
            print(f'+{t}ms stack:', text_of(c.call('xbume_route_stack', {})))
        et = c.call('xbume_find_widget', {'by': 'type', 'value': 'EditableText', 'limit': 5})
        for it in items(et):
            print('  editable ref', it['ref'], it['bounds'])
        shot = c.call('xbume_screenshot', {'savePath': '/tmp/after_tap.png'})
        for cc in shot.get('content', []):
            if cc.get('type') == 'image':
                with open('/tmp/after_tap.png', 'wb') as f:
                    f.write(base64.b64decode(cc['data']))
                print('shot saved')
    finally:
        c.close()


if __name__ == '__main__':
    main()
