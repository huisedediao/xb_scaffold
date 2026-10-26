"""验证「元素候选 + tapRef」用的 mock OpenAI 兼容服务。

- 第一轮：从消息里的元素候选表挑一个带文本的 ref，返回 tapRef + wait；
- 第二轮：done=true。
每次请求的 user 文本落盘 /tmp/ai_elements_last_text.txt，便于核对候选表内容。
用法：python3 ai_elements_mock.py [port]（默认 46998）
"""
import json
import re
import sys

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46998
CAND = re.compile(r'^- #(\d+) (\S+)(?: "([^"]*)")? \((\d+),(\d+) (\d+)×(\d+)\)(?: ← (\S+))?$')


def pick_ref(text):
    """挑第一个有文本的候选（没有就退化为 #0）。"""
    for line in text.split('\n'):
        m = CAND.match(line.strip())
        if not m:
            continue
        ref, typ, label = m.group(1), m.group(2), m.group(3) or ''
        if label:
            return int(ref), typ, label
    m = CAND.match(next((l.strip() for l in text.split('\n') if CAND.match(l.strip())), ''))
    if m:
        return int(m.group(1)), m.group(2), ''
    return None


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        user = body['messages'][-1]['content']
        text = user[0]['text'] if isinstance(user, list) else str(user)
        with open('/tmp/ai_elements_last_text.txt', 'w', encoding='utf-8') as f:
            f.write(text)
        if text.startswith('目标：'):
            with open('/tmp/ai_elements_last_round.txt', 'w', encoding='utf-8') as f:
                f.write(text)
        if '执行历史：无' in text:
            hit = pick_ref(text)
            if hit is None:
                steps = [{'type': 'tap', 'x': 10, 'y': 10}]
                think = '候选表为空，退化为坐标点击'
            else:
                ref, typ, label = hit
                steps = [
                    {'type': 'tapRef', 'ref': ref, 'expectType': typ},
                    {'type': 'wait', 'ms': 800},
                ]
                think = '按元素候选点击 #%d %s「%s」' % (ref, typ, label)
            content = json.dumps({'done': False, 'think': think, 'steps': steps},
                                 ensure_ascii=False)
        else:
            content = json.dumps({'done': True, 'think': 'tapRef 已执行，任务完成',
                                  'steps': []}, ensure_ascii=False)
        data = json.dumps({'choices': [{'message': {'role': 'assistant',
                                                    'content': content}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    print('mock listening on %d' % PORT, flush=True)
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
