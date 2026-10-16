"""P11 验证用 mock OpenAI 兼容服务：POST /v1/chat/completions 返回固定决策。

- 第一步（执行历史为空）：返回 tap(400,280) + wait + assertVisible(XBDialogInputDemo)
- 之后：返回 done=true
用法：python3 ai_mock.py [port]   （默认 46999）
"""
import json
import sys

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46999


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        user = body['messages'][-1]['content']
        text = user[0]['text'] if isinstance(user, list) else str(user)
        if '执行历史：无' in text:
            content = json.dumps({
                'done': False,
                'think': '首页可见，点击列表中的 XBDialogInputDemo 入口',
                'steps': [
                    {'type': 'tap', 'x': 400, 'y': 280},
                    {'type': 'wait', 'ms': 1200},
                    {'type': 'assertVisible', 'widget': 'XBDialogInputDemo'},
                ],
            }, ensure_ascii=False)
        else:
            content = json.dumps({
                'done': True,
                'think': '目标页面已可见，任务完成',
                'steps': [],
            }, ensure_ascii=False)
        resp = {'choices': [{'message': {'role': 'assistant', 'content': content}}]}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    print(f'mock ai listening on 127.0.0.1:{PORT}')
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
