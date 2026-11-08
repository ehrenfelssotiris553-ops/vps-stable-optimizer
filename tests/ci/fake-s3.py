#!/usr/bin/env python3
"""CI only: a small S3-compatible server on 127.0.0.1, just enough for restic.
Buckets are directories and objects files under ROOT, so a test can look at what
really arrived. A request signed with another access key is refused.

Usage: fake-s3.py ROOT ACCESS_KEY PORT
"""
import email.utils
import hashlib
import html
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

ROOT, ACCESS, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
NS = 'http://s3.amazonaws.com/doc/2006-03-01/'


def etag(path):
    with open(path, 'rb') as f:
        return '"%s"' % hashlib.md5(f.read()).hexdigest()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, code, body=b'', headers=(), length=None):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body) if length is None else length))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def error(self, code, name):
        body = ('<?xml version="1.0" encoding="UTF-8"?><Error><Code>%s</Code><Message>%s</Message></Error>' % (name, name)).encode()
        self.reply(code, body, [('Content-Type', 'application/xml')])

    def parse(self):
        """True when the request may go on; sets bucket, key, query and file."""
        url = urlsplit(self.path)
        self.query = parse_qs(url.query, keep_blank_values=True)
        parts = unquote(url.path).lstrip('/').split('/', 1)
        self.bucket, self.key = parts[0], parts[1] if len(parts) > 1 else ''
        if '..' in self.bucket or '..' in self.key.split('/'):
            self.error(400, 'InvalidRequest')
            return False
        self.dir = os.path.join(ROOT, self.bucket)
        self.file = os.path.join(self.dir, *self.key.split('/')) if self.key else self.dir
        if not self.bucket:     # not signed: the check that the server is up
            self.reply(200)
            return False
        if ('Credential=%s/' % ACCESS) not in self.headers.get('Authorization', ''):
            self.error(403, 'InvalidAccessKeyId')
            return False
        return True

    def body(self):
        """The object: over plain HTTP the client signs it in chunks."""
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self.headers.get('x-amz-content-sha256', '').startswith('STREAMING-'):
            return data
        out, at = bytearray(), 0
        while at < len(data):
            end = data.index(b'\r\n', at)
            size = int(data[at:end].split(b';')[0], 16)
            if size == 0:
                break
            out += data[end + 2:end + 2 + size]
            at = end + 2 + size + 2
        return bytes(out)

    def do_HEAD(self):
        if not self.parse():
            return
        if not self.key:
            return self.reply(200 if os.path.isdir(self.dir) else 404)
        if not os.path.isfile(self.file):
            return self.reply(404)
        self.reply(200, headers=self.meta(), length=os.path.getsize(self.file))

    def meta(self):
        return [('ETag', etag(self.file)), ('Last-Modified', email.utils.formatdate(os.path.getmtime(self.file), usegmt=True)),
                ('Content-Type', 'application/octet-stream'), ('Accept-Ranges', 'bytes')]

    def do_GET(self):
        if not self.parse():
            return
        if not self.key:
            if not os.path.isdir(self.dir):
                return self.error(404, 'NoSuchBucket')
            if 'location' in self.query:
                body = '<?xml version="1.0" encoding="UTF-8"?><LocationConstraint xmlns="%s">us-east-1</LocationConstraint>' % NS
                return self.reply(200, body.encode(), [('Content-Type', 'application/xml')])
            return self.listing()
        if not os.path.isfile(self.file):
            return self.error(404, 'NoSuchKey')
        with open(self.file, 'rb') as f:
            data = f.read()
        wanted = self.headers.get('Range')
        if not wanted:
            return self.reply(200, data, self.meta())
        first, last = wanted.split('=')[1].split('-')
        first, last = int(first), min(int(last) if last else len(data) - 1, len(data) - 1)
        self.reply(206, data[first:last + 1], self.meta() + [('Content-Range', 'bytes %d-%d/%d' % (first, last, len(data)))])

    def listing(self):
        prefix = self.query.get('prefix', [''])[0]
        delimiter = self.query.get('delimiter', [''])[0]
        items, common = [], set()
        for base, _, names in os.walk(self.dir):
            for name in names:
                path = os.path.join(base, name)
                key = os.path.relpath(path, self.dir).replace(os.sep, '/')
                if not key.startswith(prefix):
                    continue
                rest = key[len(prefix):]
                if delimiter and delimiter in rest:
                    common.add(prefix + rest.split(delimiter)[0] + delimiter)
                else:
                    items.append((key, path))
        out = ['<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="%s"><Name>%s</Name><Prefix>%s</Prefix>'
               '<KeyCount>%d</KeyCount><MaxKeys>1000000</MaxKeys><IsTruncated>false</IsTruncated>' % (NS, self.bucket, html.escape(prefix), len(items) + len(common))]
        for key, path in sorted(items):
            out.append('<Contents><Key>%s</Key><LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>%s</ETag><Size>%d</Size>'
                       '<StorageClass>STANDARD</StorageClass></Contents>' % (html.escape(key), html.escape(etag(path)), os.path.getsize(path)))
        for name in sorted(common):
            out.append('<CommonPrefixes><Prefix>%s</Prefix></CommonPrefixes>' % html.escape(name))
        out.append('</ListBucketResult>')
        self.reply(200, ''.join(out).encode(), [('Content-Type', 'application/xml')])

    def do_PUT(self):
        if not self.parse():
            return
        if not self.key:
            os.makedirs(self.dir, exist_ok=True)
            return self.reply(200, headers=[('Location', '/' + self.bucket)])
        if not os.path.isdir(self.dir):
            return self.error(404, 'NoSuchBucket')
        data = self.body()
        os.makedirs(os.path.dirname(self.file), exist_ok=True)
        with open(self.file + '.part', 'wb') as f:
            f.write(data)
        os.replace(self.file + '.part', self.file)
        self.reply(200, headers=[('ETag', etag(self.file))])

    def do_DELETE(self):
        if not self.parse():
            return
        if os.path.isfile(self.file):
            os.remove(self.file)
        self.reply(204)


ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
