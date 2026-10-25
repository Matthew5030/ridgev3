#!/usr/bin/env python3
"""Read-only local Ridge download origin, with immutable assets and byte ranges."""
import argparse,http.server,json,mimetypes,re,urllib.parse
from pathlib import Path

SOURCE=re.compile(r'^/world/sources/(world-[a-zA-Z0-9_-]+)/(section-[0-9a-f]{64}\.ridgepack|world\.json|overview-[0-9]+m(?:-[0-9a-f]{16})?\.json|paths(?:-connected-v[12]|-[0-9a-f]{16})?\.json|c[0-9]+-r[0-9]+(?:-terrain-[0-9a-f]{16})?(?:\.background)?\.rat\.zlib|c[0-9]+-r[0-9]+(?:-ground-[0-9a-f]{16})?\.map)$')
OTHER=[
 re.compile(r'^/world/region-packs/region-[0-9a-f]{64}\.ridgepack$'),
 re.compile(r'^/[a-zA-Z0-9_-]+/(?:pack\.json|overview\.png|cell-[0-9]+-[0-9]+-(?:1|2|4|8|16|32)m\.bin|map-[0-9]+-[0-9]+-(?:image|preview)\.png|graph-[0-9]+-[0-9]+\.json)$'),
 re.compile(r'^/ridge-adaptive-v[0-9]+-[a-zA-Z0-9_-]+/(?:pack\.json|index\.json|terrain(?:-z10-x[0-9]+-y[0-9]+)?\.ratpack|surroundings\.bin|context-source-(?:8|32)m\.bin|map-[0-9]+-[0-9]+-(?:image|preview)\.png|graph-[0-9]+-[0-9]+\.json)$'),
 re.compile(r'^/[a-zA-Z0-9_-]+/(?:adaptive\.json|mesh-[a-zA-Z0-9_-]+\.(?:rmesh|rat)\.zlib|boundary\.geojson|coverage-gaps\.geojson)$'),
 re.compile(r'^/uk-adaptive-0p5-v3/z10-x[0-9]+-y[0-9]+-adaptive-0p5/(?:adaptive\.json|terrain\.ratpack|boundary\.geojson|coverage-gaps\.geojson)$'),
 re.compile(r'^/uk-coarse-background-v2/(?:background\.json|z10-x[0-9]+-y[0-9]+\.height\.zlib)$')]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_HEAD(self):self.serve(False)
    def do_GET(self):self.serve(True)
    def serve(self,body):
        url=urllib.parse.urlsplit(self.path)
        path=urllib.parse.unquote(url.path)
        if '\\' in path or '\x00' in path or any(p in {'.','..'} for p in path.split('/')):self.send_error(404);return
        if path=='/health':self.text(b'Ridge downloads ready\n',body);return
        if path=='/':self.text(b'Ridge offline downloads\nConnect this address in Ridge Settings > Download server.\n',body);return
        if path.startswith('/north-york-moors-adaptive-0p5/'):self.send_error(410);return
        source=SOURCE.fullmatch(path)
        mutable=path in {'/catalog.json','/adaptive-catalog.json','/world/catalog.json','/uk-adaptive-0p5-v3/catalog.json'} or bool(source and source.group(2)=='world.json')
        if not mutable and not source and not any(p.fullmatch(path) for p in OTHER):self.send_error(404);return
        relative=path.lstrip('/')
        if path.startswith('/world/'):relative=self.server.world_name+'/'+path[len('/world/'):]
        target=self.server.root/relative
        try:
            stream=target.open('rb');stat=target.stat()
        except (OSError,ValueError):self.send_error(404);return
        with stream:
            size=stat.st_size;start,end=0,size-1;status=200
            if 'Range' in self.headers:
                match=re.fullmatch(r'bytes=(\d*)-(\d*)',self.headers['Range'])
                if not match or not any(match.groups()):self.invalid_range(size);return
                a,b=match.groups()
                if not a:start=max(0,size-int(b))
                else:start=int(a);end=min(size-1,int(b)) if b else size-1
                if start>=size or end<start:self.invalid_range(size);return
                status=206
            self.send_response(status);self.send_header('Content-Type',mimetypes.guess_type(target.name)[0] or 'application/octet-stream');self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Cache-Control','no-cache' if mutable else 'public, max-age=31536000, immutable')
            if status==206:self.send_header('Content-Range','bytes %d-%d/%d'%(start,end,size))
            self.end_headers()
            if body:
                stream.seek(start);remaining=end-start+1
                try:
                    while remaining:
                        data=stream.read(min(1024*1024,remaining))
                        if not data:break
                        self.wfile.write(data);remaining-=len(data)
                except (BrokenPipeError,ConnectionResetError):pass
    def invalid_range(self,size):
        self.send_response(416);self.send_header('Content-Range','bytes */%d'%size);self.send_header('Content-Length','0');self.end_headers()
    def text(self,data,body):
        self.send_response(200);self.send_header('Content-Type','text/plain');self.send_header('Content-Length',str(len(data)));self.end_headers()
        if body:self.wfile.write(data)
    def log_message(self,*args):pass
    def log_error(self,format,*args):
        print(json.dumps({'event':'http-error','client':self.client_address[0],
                          'method':self.command,'path':self.path,
                          'error':format % args}),flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--world-name',default='world-v1-2026-10-04');p.add_argument('--port',type=int,default=8787);p.add_argument('--bind',default='0.0.0.0');a=p.parse_args()
    server=http.server.ThreadingHTTPServer((a.bind,a.port),Handler);server.root=a.root;server.world_name=a.world_name;server.daemon_threads=True
    print('Ridge download server listening on %s:%s'%(a.bind,a.port),flush=True);server.serve_forever()

if __name__=='__main__':main()
