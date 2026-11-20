#!/usr/bin/env python3
"""Loopback-only original PDF/HTML fixtures for manually testing the Chrome extension."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def pdf_fixture():
    text = b'BT /F1 22 Tf 54 748 Td (PaperDesk Browser Import Test) Tj 0 -40 Td /F1 12 Tf (An original local fixture. No personal document is used.) Tj 0 -24 Td (Import this PDF from Chrome, then return to this page.) Tj ET'
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        b'<< /Length ' + str(len(text)).encode() + b' >>\nstream\n' + text + b'\nendstream',
    ]
    result = b'%PDF-1.4\n'
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(result))
        result += str(index).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
    xref = len(result)
    result += b'xref\n0 6\n0000000000 65535 f \n'
    for offset in offsets[1:]:
        result += f'{offset:010} 00000 n \n'.encode()
    result += f'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return result


PDF = pdf_fixture()
HTML = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>PaperDesk 浏览器导入测试</title>
<style>body{font:16px -apple-system,sans-serif;max-width:820px;margin:48px auto;color:#25433e;background:#f8faf7}h1{font-size:28px}p{line-height:1.8}a{color:#235c55}iframe{width:100%;height:480px;border:1px solid #d6e1dc;border-radius:10px;margin-top:20px}</style>
<h1>PaperDesk 浏览器导入测试</h1><p>此页面仅在本机提供原创测试 PDF，用于验证扩展识别和导入，不包含个人文献。</p>
<p><a href="/fixture.pdf" type="application/pdf">打开测试 PDF</a> · <a href="/download?id=sample" type="application/pdf">无后缀 PDF 链接</a> · <a href="/not-a-pdf">普通网页（应拒绝导入）</a></p>
<iframe src="/fixture.pdf" title="PaperDesk 原创测试 PDF"></iframe></html>'''.encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path in ['/fixture.pdf', '/download']:
            body, content_type = PDF, 'application/pdf'
        elif path == '/':
            body, content_type = HTML, 'text/html; charset=utf-8'
        elif path == '/not-a-pdf':
            body, content_type = b'<html><title>Not a PDF</title><p>HTML must not be imported as PDF.</p></html>', 'text/html'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18766)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'Browser PDF fixture: http://127.0.0.1:{server.server_port}/', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
