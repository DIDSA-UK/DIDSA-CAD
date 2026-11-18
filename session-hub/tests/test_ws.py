"""The hub over real WebSockets (Starlette's test client): the handshake key, /health, a presenter and an observer exchanging state,
and the latest-wins send queue a slow receiver gets."""

import asyncio
import json

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.api import WsConnection, create_app
from app.hub import Hub

KEY = "test-hub-key"
MODEL = {"kind": "backend", "root_part_id": "root-1", "rev": 1}


@pytest.fixture
def client():
    return TestClient(create_app(Hub(), KEY, tick_s=3600))


def _until(ws, kind):
    for _ in range(20):
        message = ws.receive_json()
        if message["t"] == kind:
            return message
    raise AssertionError(f"no {kind}")


def test_health_needs_the_key(client):
    assert client.get("/health").status_code == 401
    body = client.get("/health", headers={"X-API-Key": KEY}).json()
    assert body["status"] == "ok" and body["proto"] == 1 and body["rooms"] == 0


def test_a_wrong_key_is_refused_at_the_handshake(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws", headers={"X-API-Key": "wrong"}) as ws:
            ws.receive_json()


def test_presenter_and_observer_over_websockets(client):
    with client.websocket_connect("/ws", headers={"X-API-Key": KEY}) as presenter:
        presenter.send_json({"t": "host", "proto": 1, "name": "Alex", "device": "quest", "model": MODEL,
                             "backend_url": "https://cad.example.test", "view_token": "tok"})
        welcome = _until(presenter, "welcome")
        code = welcome["room"]["code"]
        assert client.get("/health", headers={"X-API-Key": KEY}).json()["rooms"] == 1

        with client.websocket_connect("/ws") as observer:
            observer.send_json({"t": "join", "proto": 1, "code": code, "name": "Sam", "device": "phone"})
            joined = _until(observer, "welcome")
            assert joined["view_token"] == "tok" and joined["you"]["role"] == "observer"
            assert _until(presenter, "joined")["participant"]["name"] == "Sam"

            presenter.send_json({"t": "poses", "full": True, "items": [{"path": "a", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]}]})
            assert _until(observer, "poses")["items"][0]["path"] == "a"

            observer.send_bytes(bytes([1, 0, 0, 1, 0]) + b"opus")
            assert presenter.receive_bytes() == bytes([1, 2, 0, 1, 0]) + b"opus"

            observer.send_json({"t": "ping", "n": 5})
            assert _until(observer, "pong")["n"] == 5

            presenter.send_json({"t": "end"})
            assert _until(observer, "end")["reason"] == "ended"


def test_an_observer_without_a_code_gets_an_error_and_is_closed(client):
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "join", "proto": 1, "code": "ZZZZZZ"})
        assert ws.receive_json()["code"] == "bad_code"
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


class _SlowSocket:
    def __init__(self):
        self.out = []

    async def send_text(self, text):
        self.out.append(json.loads(text))

    async def send_bytes(self, data):
        self.out.append(data)

    async def close(self, code):
        self.out.append(("closed", code))


def test_a_slow_receiver_gets_the_latest_state_not_a_backlog():
    now = [100.0]
    socket = _SlowSocket()

    class _Ws:
        client = None

    conn = WsConnection(_Ws(), lambda: now[0])
    conn.websocket = socket
    from app.hub import merge_poses

    conn.send({"t": "presence", "from": 2, "n": 1}, key=("presence", 2))
    conn.send({"t": "poses", "full": False, "items": [{"path": "a", "xf": [1]}]}, key="poses", merge=merge_poses)
    conn.send({"t": "presence", "from": 2, "n": 2}, key=("presence", 2))
    conn.send({"t": "poses", "full": False, "items": [{"path": "b", "xf": [2]}]}, key="poses", merge=merge_poses)
    conn.send({"t": "joined"})
    conn.send_voice(b"old", at=99.0)  # 1 s old when sent: dropped
    conn.send_voice(b"new", at=100.0)
    conn.close(1000)
    asyncio.run(conn.pump())

    kinds = [m["t"] if isinstance(m, dict) else m for m in socket.out]
    assert kinds == ["presence", "poses", "joined", b"new", ("closed", 1000)]
    assert socket.out[0]["n"] == 2
    assert {i["path"] for i in socket.out[1]["items"]} == {"a", "b"}
