"""AI 异常归因本地 mock：固定返回中文归因，落盘收到的 prompt 供断言。

用法：python3 exc_ai_mock.py [port]   （默认 46998）
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46998


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get('messages') or []
        text = ''
        for m in msgs:
            c = m.get('content')
            if isinstance(c, list):
                text += '\n'.join(str(x.get('text', '')) for x in c if isinstance(x, dict))
            else:
                text += str(c)
        with open('/tmp/exc_ai_last_prompt.txt', 'w', encoding='utf-8') as f:
            f.write(text)
        content = (
            '1. 结论：_requestByDio 在拿到响应后对空值做了强制解包，响应 JSON 缺少预期字段导致空值异常。\n'
            '2. 定位：example/lib/main.dart:153 的 Dio 请求回调附近；栈帧 #0 指向 _HomePageState._requestByDio。\n'
            '3. 修复建议：把 `data!` 改为可空判断，或在 setState 前校验 `response.data?["title"]`；\n'
            '   示例：`final title = response.data?["title"] as String? ?? "";`\n'
            '4. 需要补充：若仍复现，请提供请求响应体与 _message 的赋值代码。\n'
            '\n（本结论由本地 mock 生成，用于验证 AI 分析链路与上下文是否送达）'
        )
        resp = {'choices': [{'message': {'role': 'assistant', 'content': content}}]}
        data = json.dumps(resp, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    print(f'exc ai mock listening on 127.0.0.1:{PORT}')
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
