#!/usr/bin/env python3
"""Local demo API for screenshots. Never connects to a real OpenLP server."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ITEMS = [
    ('Welcome', ['Welcome\nWe’re glad you’re here.']),
    ('Morning Light', ['A new day is beginning,\nThe morning fills the sky.\nWe gather here together,\nWith grateful hearts held high.',
                       'Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong.',
                       'In every quiet moment,\nIn every helping hand,\nWe find a little courage,\nAnd strength to understand.',
                       'Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong.']),
    ('Opening Prayer', ['A moment of reflection']),
    ('Community News', ['This week in our community']),
    ('Reading', ['Today’s reading']),
    ('A Place to Belong', ['There is room around this table,\nThere is welcome at the door.']),
    ('Message', ['Small acts of kindness']),
    ('Closing Prayer', ['Go in peace']),
    ('Thank You', ['Thank you for joining us.']),
]
state = {'item': 1, 'slide': 1, 'mode': 'show'}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path
        with lock:
            item, slide, mode = state['item'], state['slide'], state['mode']
            if path == '/api/service/list':
                result = {'items': [dict(id=str(i), title=title, selected=i == item) for i, (title, _) in enumerate(ITEMS)]}
            elif path == '/api/controller/live/text':
                title, slides = ITEMS[item]
                result = {'item': str(item), 'slides': [dict(text=text, title=title, selected=i == slide) for i, text in enumerate(slides)]}
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
    print('Demo OpenLP API: http://127.0.0.1:9431', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 9431), Handler).serve_forever()
