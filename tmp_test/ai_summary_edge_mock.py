"""AI 总结异常路径 mock：验证「解析失败重试 + 覆盖自检补全」。

总结请求按计数返回：
  第 1 次 -> 非 JSON（触发解析失败重试）
  第 2 次 -> 合法 JSON 但缺「20」（触发覆盖自检）
  第 3 次 -> 完整 JSON（成功）
执行阶段 -> 第一轮 done=true。
用法：python3 ai_summary_edge_mock.py [port]（默认 46997）；计数文件 /tmp/ai_summary_edge_count
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 46997
COUNT_FILE = '/tmp/ai_summary_edge_count'
LOG_FILE = '/tmp/ai_summary_edge_log.txt'


def full_summary():
    return {
        'verdict': '20 次中成功 17 次，成功率 85%',
        'requirements': [
            {'requirement': '连续测 20 次', 'status': 'met', 'evidence': '轮 2-21 共 20 次'},
            {'requirement': '计算播放成功率', 'status': 'met', 'evidence': '成功 17 / 总 20'},
        ],
        'metrics': [
            {'name': '总次数', 'value': '20', 'basis': '轮 2-21 各一次'},
            {'name': '成功率', 'value': '85%', 'basis': '成功 17 / 总 20'},
        ],
        'summary': '已完成 20 次播放统计，成功率 85%。',
        'issues': ['3 次播放失败'],
        'confidence': 'high',
    }


def no_coverage_summary():
    return {
        'verdict': '已执行播放测试',
        'requirements': [
            {'requirement': '进入播放页', 'status': 'met', 'evidence': '路由 /play'},
        ],
        'metrics': [
            {'name': '总次数', 'value': '若干', 'basis': '未逐轮计数'},
        ],
        'summary': '执行了播放测试，但未逐轮统计。',
        'issues': [],
        'confidence': 'low',
    }


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get('messages') or []
        sys_text = next((m.get('content') for m in msgs
                         if m.get('role') == 'system' and isinstance(m.get('content'), str)), '')
        user = msgs[-1].get('content') if msgs else ''
        if not isinstance(user, str):
            user = str(user)
        if '分析员' not in sys_text:
            content = json.dumps({'done': True, 'think': '完成任务', 'steps': []}, ensure_ascii=False)
        else:
            count = 1
            if os.path.exists(COUNT_FILE):
                count = int(open(COUNT_FILE).read().strip() or '0') + 1
            open(COUNT_FILE, 'w').write(str(count))
            with open(LOG_FILE, 'a', encoding='utf-8') as f:
                f.write(f'--- summary call {count} ---\n{user[-400:]}\n')
            if count == 1:
                content = '这不是 JSON，只有一段文字'
            elif count == 2:
                content = json.dumps(no_coverage_summary(), ensure_ascii=False)
            else:
                content = json.dumps(full_summary(), ensure_ascii=False)
        data = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': content}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    print(f'edge mock listening :{PORT}', flush=True)
    HTTPServer(('127.0.0.1', PORT), H).serve_forever()
