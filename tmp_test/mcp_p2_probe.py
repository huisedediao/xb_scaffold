"""P2 设备层实测：xbume_devices → app_launch(flutter-run) → 操作 → terminate。

用法：
  python3 tmp_test/mcp_p2_probe.py --step devices
  python3 tmp_test/mcp_p2_probe.py --step launch --cwd /path/to/example
  python3 tmp_test/mcp_p2_probe.py --step terminate --pid 12345
"""
import json
import os
import subprocess
import sys
import time

ROOT = '/Users/xiexianbin/dev/git/github/xb_scaffold'
PKG = os.path.join(ROOT, 'xb_ume')


class Client:
    def __init__(self, extra_args=None, path=None):
        args = ['dart', 'run', 'bin/mcp.dart', '--tool-groups', 'all']
        if extra_args:
            args += extra_args
        env = os.environ.copy()
        if path:
            env['PATH'] = path
        self.proc = subprocess.Popen(args, cwd=PKG, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1,
                                     env=env)
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
            err = self.proc.stderr.read() if self.proc.stderr else ''
            raise RuntimeError('server closed: ' + err[-800:])
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


def show(tag, r, n=900):
    print(f'\n=== {tag} {"ERR" if r.get("isError") else "OK"} ===')
    print(text_of(r)[:n])


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    step = arg('--step', 'devices')
    backend = arg('--backend')
    extra = ['--device-backend', backend] if backend else None
    c = Client(extra, path=arg('--path'))
    try:
        c.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                             'clientInfo': {'name': 'p2', 'version': '0'}})
        tl = c.rpc('tools/list')
        names = [t['name'] for t in (tl.get('result') or {}).get('tools', [])]
        print(f'tools/list: {len(names)}')
        expect = ['xbume_devices', 'xbume_app_launch', 'xbume_app_install',
                  'xbume_app_uninstall', 'xbume_app_terminate', 'xbume_press_key',
                  'xbume_native_tap', 'xbume_crash_list', 'xbume_crash_get']
        missing = [e for e in expect if e not in names]
        print('缺工具:', missing or '无')

        show('xbume_devices', c.call('xbume_devices', {}))

        if step == 'launch':
            cwd = arg('--cwd', os.path.join(PKG, 'example'))
            show('xbume_app_launch(flutter-run)',
                 c.call('xbume_app_launch', {'deviceId': 'macos', 'cwd': cwd,
                                             'waitVm': True, 'timeoutMs': 240000}), 1200)
            show('路由栈', c.call('xbume_route_stack', {}))
            fw = c.call('xbume_find_widget', {'by': 'type', 'value': 'ElevatedButton',
                                              'limit': 3})
            show('find_widget', fw, 400)
            items = (fw.get('structuredContent') or {}).get('items') or []
            if items:
                show('tap', c.call('xbume_tap', {'ref': items[0]['ref'], 'waitMs': 500}))
                show('路由栈(click 后)', c.call('xbume_route_stack', {}))
                c.call('xbume_navigate', {'back': True})
            show('crash_list(macos 非 adb 设备，应给出可读错误)',
                 c.call('xbume_crash_list', {'deviceId': 'macos'}), 400)
        elif step == 'terminate':
            pid = int(arg('--pid'))
            show('terminate(无 confirm)', c.call('xbume_app_terminate', {'pid': pid}), 400)
            show('terminate(confirm)', c.call('xbume_app_terminate', {'pid': pid,
                                                                     'confirm': True}), 400)
    finally:
        c.close()


if __name__ == '__main__':
    main()
