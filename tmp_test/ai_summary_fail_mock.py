"""AI 总结降级验证用 mock：总结始终返回非 JSON（验证重试耗尽后的降级展示）。"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46996


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get('messages') or []
        sys_text = next((m.get('content') for m in msgs
                         if m.get('role') == 'system' and isinstance(m.get('content'), str)), '')
        content = ('总结服务暂时不可用，无法输出 JSON' if '分析员' in sys_text
                   else json.dumps({'done': True, 'think': '完成任务', 'steps': []}, ensure_ascii=False))
        data = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': content}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    print(f'fail mock listening :{PORT}', flush=True)
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
