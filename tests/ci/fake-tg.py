"""A stand-in for the Telegram Bot API, on 127.0.0.1 only (CI). getUpdates
answers one message from chat 424242; sendMessage appends the chat and the
text to LOG. Usage: fake-tg.py LOG PORT"""
import http.server
import json
import sys
import urllib.parse

log, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.answer()

    def do_POST(self):
        self.answer()

    def answer(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode('utf-8') if length else urllib.parse.urlparse(self.path).query
        if '/getUpdates' in self.path:
            out = {'ok': True, 'result': [{'update_id': 1, 'message': {'chat': {'id': 424242, 'type': 'private'}, 'text': 'hi'}}]}
        elif '/sendMessage' in self.path:
            form = urllib.parse.parse_qs(body)
            with open(log, 'a', encoding='utf-8') as f:
                f.write('chat=%s\n%s\n--\n' % (form.get('chat_id', [''])[0], form.get('text', [''])[0]))
            out = {'ok': True, 'result': {}}
        else:
            out = {'ok': False, 'description': 'Not Found'}
        # Compact, as Telegram writes it.
        data = json.dumps(out, separators=(',', ':')).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
