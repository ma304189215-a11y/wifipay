#!/usr/bin/env python3
"""WIFIPAY 后端服务 —— 前后端分离模式专用
只用 Python3 标准库，无外部依赖。
"""
import http.server, socketserver, json, os, time, secrets
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, 'data', 'db.json')
WWW  = os.path.join(ROOT, 'www')
KEY  = os.environ.get('WP_KEY', 'changeme')
PORT = int(os.environ.get('WP_PORT', '9000'))

DEF = {
    'plans': [
        {'id':'p60','title':'1 小时','price':1,'minutes':60},
        {'id':'p1440','title':'1 天','price':5,'minutes':1440},
        {'id':'p10080','title':'7 天','price':20,'minutes':10080},
    ],
    'codes': {}, 'devices': {}, 'orders': [],
    'settings': {'title':'欢迎使用本店 WiFi','trial_minutes':30},
}

def load():
    try:
        with open(DATA) as f: return json.load(f)
    except Exception:
        return json.loads(json.dumps(DEF))

def save(d):
    os.makedirs(os.path.dirname(DATA), exist_ok=True)
    tmp = DATA + '.tmp'
    with open(tmp,'w') as f: json.dump(d, f, ensure_ascii=False, indent=1)
    os.replace(tmp, DATA)

def grant(d, mac, minutes, note=''):
    now = time.time()
    cur = d['devices'].get(mac, {}).get('exp', 0)
    d['devices'][mac] = {'exp': max(cur, now) + minutes*60, 'note': note}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *a): pass

    def send(self, code, body, ctype='text/plain; charset=utf-8'):
        b = body.encode('utf-8') if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def json(self, obj, code=200):
        self.send(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query); p = u.path
        if p == '/cgi-bin/wifipay':
            act = (q.get('act') or [''])[0]
            p = {'plans':'/api/plans','status':'/api/status','trial':'/api/trial',
                 'redeem':'/api/redeem','whoami':'/api/status'}.get(act, '/api/plans')

        if p == '/api/sync':
            if self.headers.get('X-WP-Key') != KEY: return self.send(403, 'forbidden')
            d = load(); now = time.time()
            out = ['#WIFIPAY-SYNC-1']
            for mac, dev in d['devices'].items():
                if dev.get('exp', 0) > now:
                    out.append("%s\t%d\t%s" % (mac, int(dev['exp']), dev.get('note','')))
            return self.send(200, '\n'.join(out))

        if p == '/api/plans':  return self.json(load()['plans'])
        if p == '/api/status':
            mac = (q.get('mac') or [''])[0].lower()
            d = load(); now = time.time()
            dev = d['devices'].get(mac)
            remain = max(0, int(dev['exp'] - now)) if dev else 0
            return self.json({'mac':mac,'remain':remain,'state':'ok' if remain else 'none'})
        if p == '/api/trial':
            mac = (q.get('mac') or [''])[0].lower()
            if not mac: return self.json({'ok':False,'msg':'没拿到设备 MAC'})
            d = load()
            flag = os.path.join(ROOT,'data','trial_'+mac.replace(':',''))
            if os.path.exists(flag): return self.json({'ok':False,'msg':'今天已经试用过了'})
            open(flag,'w').close()
            grant(d, mac, int(d['settings'].get('trial_minutes',30)), 'trial')
            save(d); return self.json({'ok':True})
        if p == '/api/redeem':
            mac = (q.get('mac') or [''])[0].lower()
            code = (q.get('code') or [''])[0].strip().upper()
            d = load(); c = d['codes'].get(code)
            if not c: return self.json({'ok':False,'msg':'兑换码无效'})
            if c.get('used'): return self.json({'ok':False,'msg':'已被使用'})
            c['used'] = int(time.time()); c['used_by'] = mac
            grant(d, mac, int(c['minutes']), 'code'); save(d)
            return self.json({'ok':True})

        if p == '/': p = '/index.html'
        fp = os.path.join(WWW, p.lstrip('/'))
        if os.path.isfile(fp):
            ext = os.path.splitext(fp)[1]
            ct = {'.html':'text/html; charset=utf-8','.js':'application/javascript; charset=utf-8',
                  '.css':'text/css; charset=utf-8','.json':'application/json','.png':'image/png',
                  '.jpg':'image/jpeg'}.get(ext,'application/octet-stream')
            with open(fp,'rb') as f: return self.send(200, f.read(), ct)
        return self.send(404, 'not found')

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b'{}'
        try: body = json.loads(raw.decode('utf-8'))
        except Exception: body = {}
        if urlparse(self.path).path == '/api/admin/codes':
            if self.headers.get('X-WP-Key') != KEY: return self.json({'ok':False}, 403)
            d = load(); plan = body.get('plan','p60'); cnt = min(int(body.get('count',10)), 500)
            pm = {x['id']:x for x in d['plans']}.get(plan, d['plans'][0])
            out = []
            for _ in range(cnt):
                c = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(10))
                d['codes'][c] = {'minutes': pm['minutes'], 'plan': plan, 'used': 0}
                out.append(c)
            save(d); return self.json({'ok':True,'codes':out})
        return self.json({'ok':False,'msg':'unknown'})

socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(('0.0.0.0', PORT), H).serve_forever()
