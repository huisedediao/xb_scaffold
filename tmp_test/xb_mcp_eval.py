"""最小 MCP HTTP 客户端：一条命令完成 initialize + tools/call。

用法：
  python3 tmp_test/xb_mcp_eval.py tools
  python3 tmp_test/xb_mcp_eval.py call xbume_eval '{"expr":"1+1"}'
"""
import json
import os
import sys
import time
import urllib.request

BASE = os.environ.get('MCP_URL', 'http://127.0.0.1:46141/mcp')
TOKEN = open(os.path.expanduser('~/.xb_ume_ide/mcp.token')).read().strip()
SID = None


def post(payload, timeout):
    global SID
    data = json.dumps(payload).encode()
    req = urllib.request.Request(BASE, data=data, method='POST')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Accept', 'application/json, text/event-stream')
    req.add_header('X-XBUME-Token', TOKEN)
    if SID:
        req.add_header('Mcp-Session-Id', SID)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        sid = r.headers.get('Mcp-Session-Id')
        if sid:
            SID = sid
        body = r.read().decode()
        if 'text/event-stream' in (r.headers.get('Content-Type') or ''):
            for line in body.splitlines():
                if line.startswith('data: '):
                    body = line[6:]
                    break
    return json.loads(body) if body.strip() else None


def rpc(method, params, timeout=600):
    return post({
        'jsonrpc': '2.0',
        'id': int(time.time() * 1000) % 100000,
        'method': method,
        'params': params or {},
    }, timeout)


def init():
    r = rpc('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'xb-verify', 'version': '1'},
    }, 60)
    post({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, 60)
    return r


def main():
    init()
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'tools'
    if cmd == 'tools':
        r = rpc('tools/list', {}, 60)
        tools = r['result']['tools']
        print('count=%d' % len(tools))
        for t in tools:
            print(t['name'])
        return
    if cmd == 'call':
        name = sys.argv[2]
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 600
        r = rpc('tools/call', {'name': name, 'arguments': args}, timeout)
        if r.get('error'):
            print('ERROR:', json.dumps(r['error'], ensure_ascii=False))
            return
        res = r['result']
        for c in res.get('content', []):
            if c.get('type') == 'text':
                print(c['text'])
            else:
                print('[%s]' % c.get('type'))
        if res.get('structuredContent'):
            print('STRUCTURED:', json.dumps(
                res['structuredContent'], ensure_ascii=False))
        print('isError=%s' % res.get('isError', False))
        return
    print('unknown command: %s' % cmd)


if __name__ == '__main__':
    main()
