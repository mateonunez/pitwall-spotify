"""A fake Spotify, for the tests: the accounts service and the few Web API calls the plugin makes.

python3 fake_api.py <port> <log>: answers on 127.0.0.1:<port>, appends "METHOD /path" for each call to <log>.
Only the token "fresh" is accepted, so a stored expired token must be refreshed first.
"""
import http.server
import json
from pathlib import Path
import sys
import time
import urllib.parse

port, log = int(sys.argv[1]), sys.argv[2]
state = {"playing": True, "shuffle": False, "repeat": "off", "volume": 60, "context": None, "liked": set()}
TRACK = {"uri": "spotify:track:t1", "name": "Song #1 with a title long enough to be cut short", "duration_ms": 200000,
         "artists": [{"name": "The Band"}], "album": {"name": "First Album", "release_date": "2024-05-01"}}


class Fake(http.server.BaseHTTPRequestHandler):
    def answer(self, code, body=None):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        path = self.path.split("?")[0]
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        with open(log, "a") as f:
            f.write(f"{method} {path}\n")
        if path == "/api/token":
            return self.answer(200, {"access_token": "fresh", "expires_in": 3600})
        if self.headers.get("authorization") != "Bearer fresh":
            return self.answer(401, {"error": {"status": 401, "message": "expired"}})
        if path == "/v1/me":
            return self.answer(200, {"display_name": "Tester", "product": "premium"})
        offset = int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("offset", ["0"])[0])
        if offset and path in ("/v1/me/playlists", "/v1/playlists/listA/items"):
            until = time.monotonic() + 5
            while Path(log + ".hold").exists() and time.monotonic() < until:
                time.sleep(0.025)
        if path == "/v1/me/playlists":
            lists = [{"id": "listA", "name": "Night Drive", "owner": {"display_name": "DJ"}},
                     {"id": "listB", "name": "Lazy Sunday", "owner": None}]
            return self.answer(200, {"items": [lists[0 if offset == 0 else 1]],
                                     "next": f"http://{self.headers['Host']}{path}?offset=2" if offset == 0 else None})
        if path == "/v1/playlists/listA/items":
            items = [None, {"item": TRACK}, None, {"item": None}, {"item": dict(TRACK, name="Last Song")}]
            return self.answer(200, {"items": items[offset:offset+2],
                                     "next": f"http://{self.headers['Host']}{path}?offset=3" if offset == 0 else None})
        if path == "/v1/playlists/listB/items":
            return self.answer(403, {"error": {"message": "Forbidden"}})
        if path == "/v1/playlists/empty/items":
            return self.answer(200, {"items": [], "next": None})
        if path == "/v1/me/player" and method == "GET":
            until = time.monotonic() + 5
            while Path(log + ".slow-player").exists() and time.monotonic() < until:
                time.sleep(0.025)
            if Path(log + ".idle").exists():
                return self.answer(204)
            return self.answer(200, {"is_playing": state["playing"], "progress_ms": 50000, "item": TRACK,
                                     "device": {"name": "MacBook", "volume_percent": state["volume"]}, "shuffle_state": state["shuffle"],
                                     "repeat_state": state["repeat"], "context": state["context"]})
        if path == "/v1/me/player/queue":
            return self.answer(200, {"queue": [{"uri": "spotify:track:q1", "name": "Next One", "duration_ms": 180000,
                                                "artists": [{"name": "Other"}], "album": {"name": "B"}}]})
        if path == "/v1/me/player/recently-played":
            return self.answer(200, {"items": [{"played_at": "2026-11-22T10:00:00.000Z", "track": {
                "uri": "spotify:track:r1", "name": "Old Song", "duration_ms": 1000, "artists": [{"name": "Past"}], "album": {"name": "C"}}}]})
        if path.startswith("/v1/me/tracks"):  # as the real one does now
            return self.answer(403, {"error": {"status": 403, "message": "Forbidden"}})
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if path in ("/v1/me/library", "/v1/me/library/contains"):
            uri = params.get("uris", [""])[0]
            if method == "PUT":
                state["liked"].add(uri)
            if method == "DELETE":
                state["liked"].discard(uri)
            return self.answer(200, [uri in state["liked"]]) if method == "GET" else self.answer(204)
        if method == "PUT" and path == "/v1/me/player/shuffle" and params.get("state") in (["true"], ["false"]):
            state["shuffle"] = params["state"] == ["true"]
            return self.answer(204)
        if method == "PUT" and path == "/v1/me/player/repeat" and params.get("state") in (["off"], ["context"], ["track"]):
            state["repeat"] = params["state"][0]
            return self.answer(204)
        if method == "PUT" and path == "/v1/me/player/volume":
            state["volume"] = int(params["volume_percent"][0])
            return self.answer(204)
        if path == "/v1/me/player/pause":
            state["playing"] = False
            return self.answer(204)
        if path == "/v1/me/player/play":
            if body:
                context = json.loads(body).get("context_uri")
                state["context"] = {"uri": context} if context else None
                with open(log, "a") as f:
                    f.write(f"play {body.decode()}\n")
            state["playing"] = True
            return self.answer(204)
        if path in ("/v1/me/player/next", "/v1/me/player/previous", "/v1/me/library", "/v1/me/player/volume", "/v1/me/player/queue"):
            return self.answer(204)
        return self.answer(404, {"error": {"status": 404, "message": "unknown"}})

    def do_GET(self):
        self.handle_any("GET")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", port), Fake).serve_forever()
