#!/usr/bin/env python3
"""Local-only integration fixture. Responses are explicitly simulated, not model-generated."""
import argparse
import json
import re
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_error(404)
            return
        self.send_json({"data": [{"id": "paperdesk-local-fixture"}]})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.server.request_log:
            with self.server.request_log.open("a", encoding="utf-8") as log:
                log.write(json.dumps(payload, ensure_ascii=False) + "\n")
        last = payload["messages"][-1]["content"]
        image_count = 0
        if isinstance(last, list):
            image_count = sum(part.get("type") == "image_url" for part in last)
            last = "\n".join(part.get("text", "") for part in last if part.get("type") == "text")
        if last == "Connection test. Reply with only OK.":
            answer = "OK（本地模拟连接测试）"
        else:
            refs = list(dict.fromkeys(re.findall(r"\[(p\d+[bs]\d+)\]", last)))
            pages = list(dict.fromkeys(re.findall(r"\[(?:p\d+[bs]\d+)\] PDF 第 (\d+) 页", last)))
            prior = len([m for m in payload["messages"][:-1] if m["role"] in ("user", "assistant")])
            answer = ("这是本地模拟服务的验证回复，并非真实模型分析。\n\n"
                      f"本轮收到第 {'、'.join(pages)} 页的正文片段，历史对话 {prior} 条。\n\n"
                      "当前页面的原文已经随问题传入，连续追问和引用定位可继续验证。 "
                      + (f"[{refs[0]}]" if refs else ""))
            visuals = list(dict.fromkeys(re.findall(r"\[visual:(p\d+)\]", last)))
            if visuals:
                answer += (f"\n\n## 原文配图验证\n\n本轮收到 {image_count} 张页面图片。下面展示原始 PDF 页面，可放大或回到原文核对。"
                           f"\n\n[visual:{visuals[0]}]\n\n"
                           "| 核对项 | 内容 |\n| --- | --- |\n| 来源 | 原文 PDF 页面 |\n| 性质 | 本地模拟回复 |\n\n"
                           r"公式仍可显示：\(R=\frac{BC}{BC+KL}\)。")
        if not payload.get("stream"):
            self.send_json({"choices": [{"message": {"role": "assistant", "content": answer}}]})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for start in range(0, len(answer), 3):
                event = {"choices": [{"index": 0, "delta": {"content": answer[start:start + 3]}}]}
                self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.04)
            self.wfile.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--request-log", type=Path, help="Optional local QA payload log; use only with demo documents")
    options = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", options.port), FixtureHandler)
    server.request_log = options.request_log
    print(f"Local fixture listening on http://127.0.0.1:{server.server_port}/v1", flush=True)
    server.serve_forever()
