"""P13 重试机制验证用 mock：全局前 2 次请求返回 HTTP 500，之后走 ai_mock.py 同款三段剧本。
预期：GUI 轮 0 内重试 2 次后成功（retries=2），任务不被打断，最终 done。
用法：python3 ai_mock_retry.py [port]   （默认 46999）
"""
import json
import sys

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46999
FAIL_TIMES = 2
calls = {'n': 0}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        calls['n'] += 1
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n)) if n else {}
        if calls['n'] <= FAIL_TIMES:
            print(f'req#{calls["n"]}: FAIL non-json reply')
            resp = {'choices': [{'message': {'role': 'assistant',
                    'content': '抱歉，我这次没能生成有效决策，请重试。'}}]}
            data = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        user = body['messages'][-1]['content']
        text = user[0]['text'] if isinstance(user, list) else str(user)
        with open('/tmp/ai_mock_retry_text.txt', 'w', encoding='utf-8') as f:
            f.write(text)
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
        elif 'assertText=OK' not in text and 'assertVisible=OK' in text:
            content = json.dumps({
                'done': False,
                'think': '已进入目标页，用数据层证据确认',
                'steps': [
                    {'type': 'assertText', 'contains': 'show'},
                ],
            }, ensure_ascii=False)
        else:
            content = json.dumps({
                'done': True,
                'think': '任务完成',
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
    print(f'mock retry listening on 127.0.0.1:{PORT}')
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
