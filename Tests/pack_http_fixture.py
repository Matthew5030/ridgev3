"""Local fault-injection proxy for resumable pack transfer integration tests."""
import http.server
import os
import sys
import time
import urllib.request
from urllib.parse import urlsplit, urlunsplit


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        request = urlsplit(self.path)
        upstream = urlsplit(os.environ.get('RIDGE_TEST_SERVER', 'http://127.0.0.1:8787'))
        with urllib.request.urlopen(urlunsplit((upstream.scheme, upstream.netloc, request.path, '', ''))) as response:
            data = response.read()
        start = int(self.headers.get('Range', 'bytes=0-').split('=')[1].split('-')[0])
        if request.query == 'ignore-range':
            start = 0
        self.send_response(206 if start else 200)
        self.send_header('Content-Length', len(data) - start)
        if start:
            self.send_header('Content-Range', f'bytes {start}-{len(data)-1}/{len(data)}')
        self.end_headers()
        try:
            for offset in range(start, len(data), 65536):
                self.wfile.write(data[offset:offset + 65536])
                self.wfile.flush()
                if request.query == 'slow':
                    time.sleep(0.005)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as file:
    file.write(str(server.server_port))
server.serve_forever()
