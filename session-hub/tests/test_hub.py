"""The hub's rules with no sockets: a fake connection records what the hub queued, a settable clock moves time.
Covers the plan's P1 tests (a scripted presenter and two observers, late join, presenter drops and returns) and the scope's extras
(forbidden messages, wrong codes, muted voice, room limits)."""

import json

import pytest

from app.hub import PALETTE, PRESENTER_ONLY, Hub, Limits, merge_poses


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FakeConn:
    def __init__(self, remote="10.0.0.1"):
        self.remote = remote
        self.sent = []
        self.voice = []
        self.closed = None

    def send(self, message, key=None, merge=None):
        self.sent.append(message)

    def send_voice(self, frame, at):
        self.voice.append(frame)

    def close(self, code=1000):
        self.closed = code

    def of(self, kind):
        return [m for m in self.sent if m.get("t") == kind]

    def last(self, kind):
        found = self.of(kind)
        assert found, f"no {kind} in {[m.get('t') for m in self.sent]}"
        return found[-1]


XF = [1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 20, 30]
MODEL = {"kind": "backend", "root_part_id": "root-1", "rev": 3, "quality": 0.5, "tier": "full"}


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def hub(clock):
    return Hub(clock=clock)


def say(hub, conn, **message):
    hub.on_text(conn, json.dumps(message))


def host(hub, name="Alex"):
    conn = FakeConn("192.168.1.2")
    hub.on_open(conn, has_key=True)
    say(hub, conn, t="host", proto=1, name=name, device="quest", client="test", model=MODEL,
        backend_url="https://cad.example.test", view_token="tok-1", view_expires_at=5000.0)
    return conn, conn.last("welcome")


def join(hub, code, name="Sam", remote="10.0.0.9"):
    conn = FakeConn(remote)
    hub.on_open(conn, has_key=False)
    say(hub, conn, t="join", proto=1, code=code, name=name, device="phone")
    return conn


def test_a_presenter_and_two_observers(hub):
    presenter, welcome = host(hub)
    code = welcome["room"]["code"]
    assert len(code) == 6 and not set(code) & set("0O1IL")
    assert welcome["you"] == {"id": 1, "name": "Alex", "colour": PALETTE[0], "role": "presenter"}
    assert "view_token" not in welcome and "backend_url" not in welcome

    a = join(hub, code.lower(), "Sam")
    b = join(hub, f"{code[:3]}-{code[3:]}", "Kim")
    wa = a.last("welcome")
    assert wa["you"]["role"] == "observer" and wa["you"]["id"] == 2 and wa["you"]["colour"] == PALETTE[1]
    assert wa["backend_url"] == "https://cad.example.test" and wa["view_token"] == "tok-1"
    assert wa["snapshot"]["model"] == MODEL and wa["snapshot"]["rev"] == 3
    assert b.last("welcome")["you"]["id"] == 3
    assert presenter.last("joined")["participant"]["name"] == "Kim"
    assert a.last("joined")["participant"]["name"] == "Kim"

    say(hub, presenter, t="poses", seq=1, full=False, items=[{"path": "occ-1", "xf": XF}])
    say(hub, presenter, t="doc_changed", seq=2, rev=4, parts=["p-1"])
    for observer in (a, b):
        poses = observer.last("poses")
        assert poses["from"] == 1 and poses["items"][0]["xf"] == XF and isinstance(poses["at"], int)
        assert observer.last("doc_changed")["rev"] == 4
    assert not presenter.of("poses")  # never echoed

    say(hub, a, t="presence", head=[0, 1600, 0, 0, 0, 0, 1], hands=[None, None])
    assert presenter.last("presence")["from"] == 2 and b.last("presence")["from"] == 2
    assert not a.of("presence")


def test_an_observer_cannot_send_presenter_state(hub):
    presenter, welcome = host(hub)
    a = join(hub, welcome["room"]["code"])
    b = join(hub, welcome["room"]["code"], "Kim")
    for kind in sorted(PRESENTER_ONLY):
        say(hub, a, t=kind, items=[], rev=99, hidden=[], id=1, view_token="evil", locked=True)
    assert not b.of("poses") and not b.of("doc_changed") and not b.of("token") and not b.of("end")
    assert not presenter.of("left")
    assert a.closed is None  # dropped and counted, not disconnected
    room = hub.rooms[welcome["room"]["code"]]
    assert room.participants[2].ignored == len(PRESENTER_ONLY)
    assert room.rev == 3 and not room.locked


def test_a_late_joiner_gets_the_latest_state(hub):
    presenter, welcome = host(hub)
    code = welcome["room"]["code"]
    early = join(hub, code)
    say(hub, presenter, t="poses", full=True, items=[{"path": "a", "xf": XF}, {"path": "b", "xf": XF}])
    say(hub, presenter, t="poses", items=[{"path": "b", "xf": [*XF[:9], 0, 0, 0]}])
    say(hub, presenter, t="visibility", hidden=["a"])
    say(hub, presenter, t="section", on=True, point=[0, 0, 5], normal=[0, 0, 1])
    say(hub, presenter, t="place", xf=XF)
    say(hub, presenter, t="status", activity="design_table", detail="Shaft")
    say(hub, presenter, t="doc_changed", rev=7, parts=["p"], hidden_feature_ids=["f-1"])
    say(hub, presenter, t="doc_changed", rev=5, parts=["p"])  # out of order: the newest rev stays
    say(hub, early, t="mark", id="m1", kind="share", target={"path": "a"}, ttl_s=0)
    say(hub, early, t="mark", id="m2", kind="ping", target={"point": [0, 0, 0]}, ttl_s=3)
    say(hub, early, t="presence", head=[0, 1600, 0, 0, 0, 0, 1], hands=[None, None])

    late = join(hub, code, "Late")
    snap = late.last("welcome")["snapshot"]
    assert {p["path"]: p["xf"] for p in snap["poses"]} == {"a": XF, "b": [*XF[:9], 0, 0, 0]}
    assert snap["visibility"]["hidden"] == ["a"]
    assert snap["section"]["normal"] == [0, 0, 1]
    assert snap["place"]["xf"] == XF
    assert snap["status"]["detail"] == "Shaft"
    assert snap["rev"] == 7 and snap["hidden_feature_ids"] == ["f-1"]
    assert [m["id"] for m in snap["marks"]] == ["m1"]  # a ping is not kept
    assert snap["marks"][0]["colour"] == PALETTE[1]
    assert "2" in snap["presence"]


def test_a_new_model_clears_poses_and_visibility(hub):
    presenter, welcome = host(hub)
    say(hub, presenter, t="poses", full=True, items=[{"path": "a", "xf": XF}])
    say(hub, presenter, t="visibility", hidden=["a"])
    say(hub, presenter, t="model", source={"kind": "demo", "path": "res://demo/rocket.glb"}, title="Rocket")
    late = join(hub, welcome["room"]["code"])
    snap = late.last("welcome")["snapshot"]
    assert snap["model"]["kind"] == "demo" and snap["model"]["title"] == "Rocket"
    assert snap["poses"] == [] and snap["visibility"] is None


def test_the_presenter_drops_and_comes_back_then_the_room_ends_after_ten_minutes(clock):
    hub = Hub(clock=clock, limits=Limits(silent_s=10_000))  # the observer stays quiet through the wait
    presenter, welcome = host(hub)
    code = welcome["room"]["code"]
    a = join(hub, code)
    hub.on_close(presenter)
    assert a.last("left") == {"t": "left", "id": 1, "reason": "dropped"}

    clock.now += 300
    hub.tick()
    back = FakeConn()
    hub.on_open(back, has_key=True)
    say(hub, back, t="resume", proto=1, resume=welcome["resume"])
    again = back.last("welcome")
    assert again["you"]["id"] == 1 and again["you"]["role"] == "presenter" and again["room"]["code"] == code
    assert a.last("joined")["resumed"] is True

    hub.on_close(back)
    clock.now += 601
    hub.tick()
    assert a.last("end")["reason"] == "presenter_gone" and a.closed == 1000
    assert code not in hub.rooms
    late = FakeConn()
    hub.on_open(late, has_key=True)
    say(hub, late, t="resume", proto=1, resume=welcome["resume"])
    assert late.last("error")["code"] == "resume_expired"


def test_resuming_as_presenter_needs_the_key(hub):
    presenter, welcome = host(hub)
    hub.on_close(presenter)
    thief = FakeConn()
    hub.on_open(thief, has_key=False)
    say(hub, thief, t="resume", proto=1, resume=welcome["resume"])
    assert thief.last("error")["code"] == "not_allowed"


def test_hosting_needs_the_key_and_the_protocol(hub):
    conn = FakeConn()
    hub.on_open(conn, has_key=False)
    say(hub, conn, t="host", proto=1, name="X", model=MODEL, backend_url="u", view_token="t")
    assert conn.last("error")["code"] == "not_allowed" and conn.closed == 4000
    old = FakeConn()
    hub.on_open(old, has_key=True)
    say(hub, old, t="host", proto=2, model=MODEL)
    assert old.last("error")["code"] == "proto_unsupported"
    first = FakeConn()
    hub.on_open(first, has_key=True)
    say(hub, first, t="poses", items=[])
    assert first.last("error")["code"] == "not_allowed"
    bad = FakeConn()
    hub.on_open(bad, has_key=True)
    say(hub, bad, t="host", proto=1, model={"kind": "backend"})
    assert bad.last("error")["code"] == "bad_message"


def test_ten_wrong_codes_and_the_address_is_refused(hub, clock):
    _, welcome = host(hub)
    for _ in range(10):
        wrong = join(hub, "ZZZZZZ", remote="203.0.113.5")
        assert wrong.last("error")["code"] == "bad_code"
    right = join(hub, welcome["room"]["code"], remote="203.0.113.5")
    assert right.last("error")["code"] == "rate_limited"
    assert join(hub, welcome["room"]["code"], remote="203.0.113.6").of("welcome")
    clock.now += 601
    hub.tick()
    assert join(hub, welcome["room"]["code"], remote="203.0.113.5").of("welcome")


def test_room_full_locked_and_remove(hub):
    presenter, welcome = host(hub)
    code = welcome["room"]["code"]
    observers = [join(hub, code, f"O{i}") for i in range(6)]
    assert all(o.of("welcome") for o in observers)
    assert join(hub, code, "Seventh").last("error")["code"] == "room_full"

    say(hub, presenter, t="remove", id=2)
    assert observers[0].last("error")["code"] == "removed" and observers[0].closed == 4003
    assert observers[1].last("left") == {"t": "left", "id": 2, "reason": "removed"}
    gone = FakeConn()
    hub.on_open(gone, has_key=False)
    say(hub, gone, t="resume", proto=1, resume=observers[0].last("welcome")["resume"])
    assert gone.last("error")["code"] == "resume_expired"

    say(hub, presenter, t="lock", locked=True)
    assert observers[1].last("lock")["locked"] is True
    assert join(hub, code, "Late").last("error")["code"] == "room_locked"
    newcomer_ids = {o.last("welcome")["you"]["id"] for o in observers}
    assert newcomer_ids == {2, 3, 4, 5, 6, 7}


def test_voice_is_relayed_with_the_hub_s_sender_id_and_dropped_when_muted(hub):
    presenter, welcome = host(hub)
    a = join(hub, welcome["room"]["code"])
    b = join(hub, welcome["room"]["code"], "Kim")
    hub.on_bytes(a, bytes([1, 99, 0, 7, 0]) + b"opus")
    assert presenter.voice == [bytes([1, 2, 0, 7, 0]) + b"opus"] and b.voice == presenter.voice and a.voice == []
    say(hub, presenter, t="mute_all")
    hub.on_bytes(a, bytes([1, 0, 0, 8, 0]) + b"opus")
    assert len(b.voice) == 1
    assert [p["muted"] for p in b.last("roster")["participants"] if p["id"] == 2] == [True]
    hub.on_bytes(presenter, bytes([1, 0, 0, 1, 0]) + b"opus")  # the presenter is not muted by Mute all
    assert b.voice[-1][1] == 1
    hub.on_bytes(a, bytes([2, 0, 0, 9, 0]) + b"opus")  # an unknown frame version is ignored
    say(hub, a, t="voice_state", muted=False, talking=True)
    hub.on_bytes(a, bytes([1, 0, 0, 10, 0]) + b"opus")
    assert b.voice[-1][1] == 2


def test_limits_on_size_and_rate(hub):
    _, welcome = host(hub)
    a = join(hub, welcome["room"]["code"])
    hub.on_text(a, json.dumps({"t": "presence", "pad": "x" * 70_000}))
    assert a.last("error")["code"] == "too_big"
    b = join(hub, welcome["room"]["code"], "Kim")
    for _ in range(301):
        say(hub, b, t="hand", up=True)
    assert b.last("error")["code"] == "rate_limited"


def test_keepalive_and_silent_drop(hub, clock):
    presenter, welcome = host(hub)
    a = join(hub, welcome["room"]["code"])
    clock.now += 10
    hub.tick()
    assert a.of("ping") and presenter.of("ping")
    say(hub, presenter, t="pong", n=1)
    clock.now += 21
    hub.tick()
    assert a.closed == 1001
    assert presenter.last("left") == {"t": "left", "id": 2, "reason": "dropped"}
    silent = FakeConn()
    hub.on_open(silent, has_key=False)
    clock.now += 11
    hub.tick()
    assert silent.last("error")["code"] == "not_allowed"


def test_marks_hand_leave_and_end(hub):
    presenter, welcome = host(hub)
    code = welcome["room"]["code"]
    a = join(hub, code)
    say(hub, a, t="mark", id="m1", kind="share", target={"path": "occ-1", "face": 4}, ttl_s=0)
    assert presenter.last("mark")["colour"] == PALETTE[1] and presenter.last("mark")["from"] == 2
    say(hub, a, t="hand", up=True)
    assert [p["hand"] for p in presenter.last("roster")["participants"] if p["id"] == 2] == [True]
    say(hub, presenter, t="marks_clear")
    assert hub.rooms[code].marks == {}
    say(hub, a, t="mark", id="m2", kind="share", target={"path": "occ-1"}, ttl_s=0)
    say(hub, a, t="leave")
    assert a.closed == 1000 and presenter.last("left")["reason"] == "left"
    assert hub.rooms[code].marks == {}
    say(hub, presenter, t="end")
    assert code not in hub.rooms and presenter.last("end")["reason"] == "ended"


def test_a_renewed_token_reaches_observers_and_late_joiners(hub):
    presenter, welcome = host(hub)
    a = join(hub, welcome["room"]["code"])
    say(hub, presenter, t="token", view_token="tok-2", view_expires_at=9000.0)
    assert a.last("token")["view_token"] == "tok-2"
    assert join(hub, welcome["room"]["code"], "Late").last("welcome")["view_token"] == "tok-2"


def test_queued_poses_merge_for_a_slow_receiver():
    first = {"t": "poses", "full": False, "items": [{"path": "a", "xf": [1]}, {"path": "b", "xf": [1]}]}
    second = {"t": "poses", "full": False, "items": [{"path": "b", "xf": [2]}]}
    merged = merge_poses(first, second)
    assert {i["path"]: i["xf"] for i in merged["items"]} == {"a": [1], "b": [2]} and merged["full"] is False
    full = {"t": "poses", "full": True, "items": [{"path": "c", "xf": [3]}]}
    assert merge_poses(merged, full) is full
    assert merge_poses(full, second)["full"] is True


def test_the_join_uri_carries_the_hub_address_when_known(clock):
    hub = Hub(clock=clock, public_url="wss://hub.example.test")
    _, welcome = host(hub)
    assert welcome["room"]["join_uri"] == f"didsa-join:1?h=wss%3A%2F%2Fhub.example.test&c={welcome['room']['code']}"


def test_the_hub_has_room_for_sixteen_sessions(clock):
    hub = Hub(clock=clock, limits=Limits(max_rooms=2))
    host(hub)
    host(hub)
    conn = FakeConn()
    hub.on_open(conn, has_key=True)
    say(hub, conn, t="host", proto=1, model=MODEL, backend_url="u", view_token="t")
    assert conn.last("error")["code"] == "hub_full"
