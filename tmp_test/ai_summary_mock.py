"""AI 总结端到端验证用 mock OpenAI 兼容服务（POST /v1/chat/completions）。

- system 含「分析员」→ 返回结构化总结 JSON（覆盖 20 次要求，实际仅 1 轮，如实标未达标）
- 否则执行阶段 → 第一轮直接 done=true
用法：python3 ai_summary_mock.py [port]（默认 46998）
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46998


def summary_json():
    return json.dumps({
        'verdict': '指令要求连续测 20 次，实际仅执行 1 轮，未达标（成功率无法按 20 次计算）',
        'requirements': [
            {'requirement': '进入播放页', 'status': 'unknown',
             'evidence': '记录中仅有轮 1 的路由/页面文本，未出现播放页证据'},
            {'requirement': '播放成功或失败算一次', 'status': 'partial',
             'evidence': '轮 1 无播放类步骤，成功/失败判定依据不足'},
            {'requirement': '连续测 20 次', 'status': 'unmet',
             'evidence': '运行记录只有轮 1 共 1 次，距离 20 次还差 19 次'},
            {'requirement': '计算播放成功率', 'status': 'unknown',
             'evidence': '没有 20 次播放的成功/失败记录，无法计算'},
        ],
        'metrics': [
            {'name': '执行轮数', 'value': '1', 'basis': '轮 1（共 1 轮）'},
            {'name': '目标次数', 'value': '20', 'basis': '指令「连续测 20 次」'},
            {'name': '成功率', 'value': '无法计算', 'basis': '有效播放记录 0 次 / 目标 20 次'},
        ],
        'summary': '需求理解：进入播放页后，每次播放无论成功或失败计 1 次，连续 20 次后统计成功率。\n'
                   '实际执行：本次运行仅 1 轮，记录中没有播放成功或失败的计数证据。\n'
                   '结论：未达到 20 次要求，成功率无法计算；建议补充播放页定位与成功/失败判定断言后重跑。',
        'issues': ['执行轮数不足：1 轮 vs 要求 20 次', '缺少播放成功/失败判定断言'],
        'confidence': 'low',
    }, ensure_ascii=False)


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get('messages') or []
        sys_text = ''
        for m in msgs:
            c = m.get('content')
            if m.get('role') == 'system' and isinstance(c, str):
                sys_text = c
                break
        user = msgs[-1].get('content') if msgs else ''
        text = user if isinstance(user, str) else str(user)
        with open('/tmp/ai_summary_mock_last.txt', 'w', encoding='utf-8') as f:
            f.write('SYSTEM:\n' + sys_text + '\n\nUSER:\n' + text)
        if '分析员' in sys_text:
            content = summary_json()
        else:
            content = json.dumps({
                'done': True,
                'think': '页面已就绪，按当前目标确认完成',
                'steps': [],
            }, ensure_ascii=False)
        data = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': content}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    print(f'mock listening :{PORT}', flush=True)
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
