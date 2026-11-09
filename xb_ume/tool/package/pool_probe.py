#!/usr/bin/env python3
"""分发版池入口冒烟：initialize → initialized → tools/call，验证 router 能拉起 worker。

用法：python3 tmp_test/pool_probe.py <home> [port]
"""
import json
import os
import sys
import urllib.request

home = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 46150
base = 'http://127.0.0.1:%d/mcp' % port
token = open(os.path.join(home, 'mcp.token')).read().strip()
sid = 'probe-pool-1'


def rpc(method, params=None, rid=1):
    body = {'jsonrpc': '2.0', 'method': method}
    if rid is not None:
        body['id'] = rid
    if params is not None:
        body['params'] = params
    req = urllib.request.Request(
        base,
        data=json.dumps(body).encode(),
        method='POST',
        headers={
            'Content-Type': 'application/json',
            'X-XBUME-Token': token,
            'Mcp-Session-Id': sid,
            'Accept': 'application/json, text/event-stream',
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read().decode()
        ctype = r.headers.get('Content-Type', '')
    if ctype.startswith('text/event-stream'):
        out = []
        for line in raw.splitlines():
            if line.startswith('data:'):
                out.append(line[5:].strip())
        raw = out[-1] if out else ''
    return json.loads(raw) if raw.strip() else None


init = rpc('initialize', {
    'protocolVersion': '2025-06-18',
    'capabilities': {},
    'clientInfo': {'name': 'pool-probe', 'version': '0'},
})
print('initialize:', init['result']['serverInfo'])
rpc('notifications/initialized', None, rid=None)

res = rpc('tools/call', {'name': 'xbume_sessions', 'arguments': {}}, rid=2)
if 'error' in res:
    print('call error:', res['error'])
else:
    content = res['result'].get('content') or []
    text = content[0].get('text', '') if content else ''
    print('call ok, payload head:', text[:200].replace('\n', ' '))
