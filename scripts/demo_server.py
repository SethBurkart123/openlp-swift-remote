#!/usr/bin/env python3
"""Local demo API for screenshots. Never connects to a real OpenLP server."""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from pathlib import Path

ITEMS = [
    ('Welcome', ['Welcome\nWe’re glad you’re here.']),
    ('Morning Light', ['A new day is beginning,\nThe morning fills the sky.\nWe gather here together,\nWith grateful hearts held high.',
                       'Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong.',
                       'In every quiet moment,\nIn every helping hand,\nWe find a little courage,\nAnd strength to understand.',
                       'Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong.']),
    ('Opening Prayer', ['A moment of reflection']),
    ('Big Buck Bunny', ['Big Buck Bunny']),
    ('Reading', ['Today’s reading']),
    ('A Place to Belong', ['There is room around this table,\nThere is welcome at the door.']),
    ('Message', ['Small acts of kindness']),
    ('Closing Prayer', ['Go in peace']),
    ('Thank You', ['Thank you for joining us.']),
]
PLUGINS = ['custom', 'songs', 'custom', 'media', 'bibles', 'songs', 'custom', 'custom', 'custom']
media_state = {'playing': False, 'position': 64000, 'start': 0, 'duration': 634000, 'seekable': True}
state = {'item': 1, 'slide': 1, 'mode': 'show'}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        action = urlsplit(self.path).path.rsplit('/', 1)[-1]
        if not self.path.startswith('/api/controller/live/media/') or action not in ('play', 'pause', 'stop', 'seek'):
            self.send_error(404); return
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        with lock:
            if str(state['item']) != data.get('item') or state['item'] != 3:
                self.send_error(409); return
            if action in ('play', 'pause'): media_state['playing'] = action == 'play'
            if action == 'stop': media_state.update(playing=False, position=0)
            if action == 'seek': media_state['position'] = max(0, min(int(data['position']), media_state['duration']))
        self.send_response(202); self.end_headers(); self.wfile.write(b'{"results":{"success":true}}')

    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path
        if path == '/images/big-buck-bunny.png':
            data = (Path(__file__).resolve().parent.parent / 'docs/demo/big-buck-bunny.png').read_bytes()
            self.send_response(200); self.send_header('Content-Type', 'image/png'); self.end_headers(); self.wfile.write(data); return
        with lock:
            item, slide, mode = state['item'], state['slide'], state['mode']
            if path == '/api/service/list':
                result = {'items': [dict(id=str(i), title=title, selected=i == item, plugin=PLUGINS[i]) for i, (title, _) in enumerate(ITEMS)]}
            elif path == '/api/controller/live/text':
                title, slides = ITEMS[item]
                result = {'item': str(item), 'slides': [dict(text=text, title=title, selected=i == slide) for i, text in enumerate(slides)]}
                if item == 3:
                    result['slides'][0]['img'] = '/images/big-buck-bunny.png'
                    result['media'] = dict(item='3', **media_state)
            elif path == '/api/poll':
                result = dict(blank=mode == 'blank', theme=mode == 'theme', display=mode == 'desktop')
            elif path in ('/api/service/set', '/api/controller/live/set'):
                try:
                    index = int(json.loads(parse_qs(url.query)['data'][0])['request']['id'])
                    limit = len(ITEMS) if path == '/api/service/set' else len(ITEMS[item][1])
                    if not 0 <= index < limit:
                        raise ValueError('Invalid index')
                except (KeyError, ValueError, TypeError):
                    self.send_error(400); return
                if path == '/api/service/set':
                    state.update(item=index, slide=0)
                else:
                    state['slide'] = index
                result = {'success': True}
            elif path.startswith('/api/display/') and path.rsplit('/', 1)[-1] in ('blank', 'theme', 'desktop', 'show'):
                state['mode'] = path.rsplit('/', 1)[-1]
                result = {'success': True}
            elif path in ('/api/service/direction/next', '/api/service/direction/previous', '/api/controller/live/next', '/api/controller/live/previous'):
                delta = 1 if path.endswith('next') else -1
                if '/service/' in path:
                    state.update(item=max(0, min(len(ITEMS) - 1, item + delta)), slide=0)
                else:
                    state['slide'] = max(0, min(len(ITEMS[item][1]) - 1, slide + delta))
                result = {'success': True}
            else:
                self.send_error(404); return
        body = json.dumps({'results': result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Isolated OpenLP demo API')
    parser.add_argument('--host', default='127.0.0.1', help='Listening address; use 0.0.0.0 for phone testing')
    args = parser.parse_args()
    print(f'Demo OpenLP API: http://{args.host}:9431', flush=True)
    ThreadingHTTPServer((args.host, 9431), Handler).serve_forever()
