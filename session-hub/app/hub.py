"""The session hub's rules, with no sockets in them (docs/live-sessions-scope.md, sections 3, 4 and 6).

`Hub` holds rooms in memory. The transport (`app/api.py`) gives it a `Connection` per WebSocket and calls `on_open`, `on_text`,
`on_bytes`, `on_close` and, once a second, `tick`. The hub answers by calling `conn.send(message, key=..., merge=...)`,
`conn.send_voice(frame)` and `conn.close(...)`; those only queue, so nothing here awaits. Tests drive it with a fake connection and
a settable clock.

What the hub knows about a message is its type, who may send it, who receives it, and the few keys it keeps for late joiners (the
snapshot, section 4.7). It never interprets a transform, never holds geometry, files or keys, and never logs message bodies.
"""

import json
import logging
import secrets
import time
from urllib.parse import quote
from dataclasses import dataclass, field
from typing import Callable, Protocol

log = logging.getLogger("session_hub")

PROTO = 1
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L
CODE_LENGTH = 6
PALETTE = ["#E8590C", "#1C7ED6", "#2F9E44", "#AE3EC9", "#F08C00", "#0CA678", "#E03131", "#5C7CFA"]  # presenter first (D6)

PRESENTER_ONLY = frozenset(
    {"model", "doc_changed", "poses", "visibility", "section", "place", "status", "scene", "gather", "marks_clear", "mute_all",
     "lock", "remove", "token", "end"}
)
ANYONE = frozenset({"presence", "hand", "mark", "mark_clear", "voice_state", "leave", "ping", "pong"})
FIRST = frozenset({"host", "join", "resume"})
# Presenter state relayed to everyone else and kept whole in the snapshot.
_STATE_KEYS = ("visibility", "section", "place", "status", "scene")
_DEVICES = frozenset({"quest", "pcvr", "phone", "desktop"})
_MARK_KINDS = frozenset({"share", "ping", "look_here"})

VOICE_HEADER = 5  # version, sender id, sequence (2 bytes), flags
VOICE_VERSION = 1


@dataclass
class Limits:
    max_rooms: int = 16
    max_participants: int = 7  # 1 presenter + 6 observers (LS-8)
    max_text_bytes: int = 64 * 1024
    max_voice_bytes: int = 1024 + VOICE_HEADER
    text_rate: float = 60.0  # messages a second, averaged over `burst_s`
    voice_rate: float = 100.0
    burst_s: float = 5.0
    resume_s: float = 600.0  # a dropped participant (the presenter included) may come back for 10 minutes
    silent_s: float = 30.0  # no message for this long: dropped
    ping_s: float = 10.0
    first_message_s: float = 10.0
    bad_code_limit: int = 10  # wrong codes from one address in `bad_code_window_s` ...
    bad_code_window_s: float = 60.0
    bad_code_block_s: float = 600.0  # ... and it is refused for this long


class Connection(Protocol):
    remote: str

    def send(self, message: dict, key: object = None, merge: Callable[[dict, dict], dict] | None = None) -> None: ...

    def send_voice(self, frame: bytes, at: float) -> None: ...

    def close(self, code: int = 1000) -> None: ...


@dataclass
class _Bucket:
    rate: float
    capacity: float
    tokens: float
    at: float

    def take(self, now: float) -> bool:
        self.tokens = min(self.capacity, self.tokens + (now - self.at) * self.rate)
        self.at = now
        if self.tokens < 1.0:
            return False
        self.tokens -= 1.0
        return True


@dataclass
class Participant:
    id: int
    name: str
    colour: str
    role: str  # "presenter" | "observer"
    device: str
    client: str
    resume: str
    conn: object | None = None
    hand: bool = False
    muted: bool = False
    muted_by_presenter: bool = False
    talking: bool = False
    dropped_at: float | None = None
    ignored: int = 0  # messages dropped because the role may not send them, or malformed

    def public(self) -> dict:
        return {
            "id": self.id, "name": self.name, "colour": self.colour, "role": self.role, "device": self.device,
            "hand": self.hand, "muted": self.muted or self.muted_by_presenter, "talking": self.talking,
            "connected": self.conn is not None,
        }


@dataclass
class Room:
    code: str
    created_at: float
    backend_url: str
    view_token: str
    view_expires_at: float | None
    locked: bool = False
    next_id: int = 1
    participants: dict[int, Participant] = field(default_factory=dict)
    presenter_id: int = 0
    # The snapshot (section 4.7): the latest value of each piece of presenter state, nothing else.
    model: dict | None = None
    rev: int | None = None
    hidden_feature_ids: list | None = None
    poses: dict[str, list] = field(default_factory=dict)
    state: dict[str, dict] = field(default_factory=dict)
    marks: dict[tuple[int, str], dict] = field(default_factory=dict)
    presence: dict[int, dict] = field(default_factory=dict)

    def connected(self) -> list[Participant]:
        return [p for p in self.participants.values() if p.conn is not None]

    def snapshot(self) -> dict:
        return {
            "model": self.model,
            "rev": self.rev,
            "hidden_feature_ids": self.hidden_feature_ids,
            "poses": [{"path": path, "xf": xf} for path, xf in self.poses.items()],
            **{key: self.state.get(key) for key in _STATE_KEYS},
            "marks": list(self.marks.values()),
            "presence": {str(pid): msg for pid, msg in self.presence.items()},
        }


@dataclass
class _ConnState:
    conn: Connection
    has_key: bool
    opened_at: float
    last_seen: float
    last_ping: float
    text: _Bucket
    voice: _Bucket
    room: Room | None = None
    participant: Participant | None = None
    closed: bool = False


def merge_poses(old: dict, new: dict) -> dict:
    """Two queued `poses` messages for one slow receiver become one: a full table replaces, a partial one updates by path."""
    if new.get("full"):
        return new
    items = {item["path"]: item for item in old.get("items", [])}
    for item in new.get("items", []):
        items[item["path"]] = item
    return {**new, "full": bool(old.get("full")), "items": list(items.values())}


def _is_number_list(value, length: int) -> bool:
    return isinstance(value, list) and len(value) == length and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in value)


def _text(value, limit: int = 64) -> str:
    return value.strip()[:limit] if isinstance(value, str) else ""


def normalise_code(code) -> str:
    return "".join(ch for ch in str(code).upper() if ch.isalnum())


class Hub:
    def __init__(self, clock: Callable[[], float] = time.monotonic, limits: Limits | None = None, rng: secrets.SystemRandom | None = None,
                 public_url: str = ""):
        self.clock = clock
        self.public_url = public_url  # this hub's public wss:// address, for the join QR (SESSION_HUB_PUBLIC_URL); "" = the client adds it
        self.limits = limits or Limits()
        self._rng = rng or secrets.SystemRandom()
        self.rooms: dict[str, Room] = {}
        self._resume: dict[str, tuple[Room, Participant]] = {}
        self._conns: dict[int, _ConnState] = {}
        self._bad_codes: dict[str, list[float]] = {}
        self._blocked: dict[str, float] = {}

    # --- connection lifecycle -------------------------------------------------------------------------------------------------

    def on_open(self, conn: Connection, has_key: bool) -> None:
        now = self.clock()
        lim = self.limits
        self._conns[id(conn)] = _ConnState(
            conn=conn, has_key=has_key, opened_at=now, last_seen=now, last_ping=now,
            text=_Bucket(lim.text_rate, lim.text_rate * lim.burst_s, lim.text_rate * lim.burst_s, now),
            voice=_Bucket(lim.voice_rate, lim.voice_rate * lim.burst_s, lim.voice_rate * lim.burst_s, now),
        )

    def on_close(self, conn: Connection) -> None:
        """The socket is gone. A participant that did not `leave` is dropped and may `resume` for `resume_s`."""
        cs = self._conns.pop(id(conn), None)
        if cs is None or cs.participant is None or cs.room is None:
            return
        participant, room = cs.participant, cs.room
        if participant.conn is not conn:
            return  # replaced by a resume on another connection
        participant.conn = None
        participant.dropped_at = self.clock()
        participant.talking = False
        room.presence.pop(participant.id, None)
        log.info("room %s: %s (%d) dropped", room.code, participant.name, participant.id)
        self._broadcast(room, {"t": "left", "id": participant.id, "reason": "dropped"}, exclude=participant.id)

    def on_text(self, conn: Connection, text: str) -> None:
        cs = self._conns.get(id(conn))
        if cs is None or cs.closed:
            return
        now = self.clock()
        cs.last_seen = now
        if len(text.encode("utf-8")) > self.limits.max_text_bytes:
            self._fail(cs, "too_big", "A message may be at most 64 KB.")
            return
        if not cs.text.take(now):
            self._fail(cs, "rate_limited", "Too many messages.")
            return
        try:
            message = json.loads(text)
        except ValueError:
            message = None
        if not isinstance(message, dict) or not isinstance(message.get("t"), str):
            if cs.participant is None:
                self._fail(cs, "not_allowed", "The first message must be host, join or resume.")
            else:
                cs.participant.ignored += 1
            return
        kind = message["t"]
        if cs.participant is None:
            if kind not in FIRST:
                self._fail(cs, "not_allowed", "The first message must be host, join or resume.")
                return
            if message.get("proto") != PROTO:
                self._fail(cs, "proto_unsupported", f"This hub speaks protocol {PROTO}.")
                return
            {"host": self._host, "join": self._join, "resume": self._resume_participant}[kind](cs, message)
            return
        participant, room = cs.participant, cs.room
        allowed = kind in ANYONE or (kind in PRESENTER_ONLY and participant.role == "presenter")
        if not allowed:
            participant.ignored += 1
            return
        handler = getattr(self, "_on_" + kind, None)
        if handler is None or handler(cs, room, participant, message) is False:
            participant.ignored += 1

    def on_bytes(self, conn: Connection, data: bytes) -> None:
        """A voice frame (section 4.6): relayed to everyone else with the sender id written in by the hub; never decoded or kept."""
        cs = self._conns.get(id(conn))
        if cs is None or cs.closed or cs.participant is None:
            return
        now = self.clock()
        cs.last_seen = now
        participant, room = cs.participant, cs.room
        if len(data) <= VOICE_HEADER or len(data) > self.limits.max_voice_bytes or data[0] != VOICE_VERSION:
            participant.ignored += 1
            return
        if not cs.voice.take(now):
            self._fail(cs, "rate_limited", "Too many voice frames.")
            return
        if participant.muted or participant.muted_by_presenter:
            return
        frame = bytes([data[0], participant.id]) + bytes(data[2:])
        for other in room.connected():
            if other.id != participant.id:
                other.conn.send_voice(frame, now)

    def tick(self) -> None:
        """Once a second: keep-alive pings, silent and late-first-message connections, rooms whose presenter did not come back,
        observers whose resume time ran out."""
        now = self.clock()
        lim = self.limits
        for cs in list(self._conns.values()):
            if cs.closed:
                continue
            if cs.participant is None and now - cs.opened_at > lim.first_message_s:
                self._fail(cs, "not_allowed", "No host, join or resume in time.")
                continue
            if now - cs.last_seen > lim.silent_s:
                cs.closed = True
                cs.conn.close(1001)
                self.on_close(cs.conn)
                continue
            if now - cs.last_ping >= lim.ping_s:
                cs.last_ping = now
                cs.conn.send({"t": "ping", "n": int(now)})
        for room in list(self.rooms.values()):
            presenter = room.participants.get(room.presenter_id)
            if presenter is not None and presenter.conn is None and presenter.dropped_at is not None and now - presenter.dropped_at > lim.resume_s:
                self._end_room(room, "presenter_gone")
                continue
            for p in list(room.participants.values()):
                if p.conn is None and p.dropped_at is not None and now - p.dropped_at > lim.resume_s:
                    self._forget(room, p)
        for remote, until in list(self._blocked.items()):
            if until <= now:
                del self._blocked[remote]

    def stats(self) -> dict:
        return {"rooms": len(self.rooms), "participants": sum(len(r.connected()) for r in self.rooms.values())}

    # --- the first message ----------------------------------------------------------------------------------------------------

    def _host(self, cs: _ConnState, msg: dict) -> None:
        if not cs.has_key:
            self._fail(cs, "not_allowed", "Hosting needs the hub key (X-API-Key on the WebSocket handshake).")
            return
        if len(self.rooms) >= self.limits.max_rooms:
            self._fail(cs, "hub_full", "This hub has no room for another session.")
            return
        model = msg.get("model")
        if not isinstance(model, dict) or model.get("kind") not in ("backend", "demo"):
            self._fail(cs, "bad_message", "host needs a model whose kind is backend or demo.")
            return
        backend_url = _text(msg.get("backend_url"), 512)
        view_token = _text(msg.get("view_token"), 256)
        if model["kind"] == "backend" and not (backend_url and view_token):
            self._fail(cs, "bad_message", "A backend model needs backend_url and view_token.")
            return
        now = self.clock()
        room = Room(code=self._new_code(), created_at=now, backend_url=backend_url, view_token=view_token,
                    view_expires_at=msg.get("view_expires_at") if isinstance(msg.get("view_expires_at"), (int, float)) else None)
        room.model = model
        room.rev = model.get("rev") if isinstance(model.get("rev"), int) else None
        self.rooms[room.code] = room
        participant = self._add_participant(cs, room, msg, "presenter")
        room.presenter_id = participant.id
        log.info("room %s: hosted by %s", room.code, participant.name)
        self._welcome(cs, room, participant)

    def _join(self, cs: _ConnState, msg: dict) -> None:
        now = self.clock()
        remote = cs.conn.remote
        if self._blocked.get(remote, 0) > now:
            self._fail(cs, "rate_limited", "Too many wrong codes; try again later.")
            return
        room = self.rooms.get(normalise_code(msg.get("code", "")))
        if room is None:
            recent = [t for t in self._bad_codes.get(remote, []) if now - t < self.limits.bad_code_window_s] + [now]
            self._bad_codes[remote] = recent
            if len(recent) >= self.limits.bad_code_limit:
                self._blocked[remote] = now + self.limits.bad_code_block_s
                self._bad_codes.pop(remote, None)
                log.info("refusing %s for %d s after %d wrong codes", remote, self.limits.bad_code_block_s, len(recent))
            self._fail(cs, "bad_code", "No session has that code.")
            return
        if room.locked:
            self._fail(cs, "room_locked", "The presenter has locked this session.")
            return
        if len(room.participants) >= self.limits.max_participants or room.next_id > 255:
            self._fail(cs, "room_full", "This session is full.")
            return
        participant = self._add_participant(cs, room, msg, "observer")
        log.info("room %s: %s (%d) joined", room.code, participant.name, participant.id)
        self._welcome(cs, room, participant)
        self._broadcast(room, {"t": "joined", "participant": participant.public()}, exclude=participant.id)

    def _resume_participant(self, cs: _ConnState, msg: dict) -> None:
        found = self._resume.get(_text(msg.get("resume"), 128))
        if found is None:
            self._fail(cs, "resume_expired", "That session or place in it has gone; join again.")
            return
        room, participant = found
        if participant.role == "presenter" and not cs.has_key:
            self._fail(cs, "not_allowed", "Resuming as the presenter needs the hub key.")
            return
        if participant.conn is not None:  # the old socket has not noticed it is dead yet: this one takes over
            old = self._conns.pop(id(participant.conn), None)
            if old is not None:
                old.closed = True
                old.conn.close(1000)
        participant.conn = cs.conn
        participant.dropped_at = None
        cs.room, cs.participant = room, participant
        log.info("room %s: %s (%d) resumed", room.code, participant.name, participant.id)
        self._welcome(cs, room, participant)
        self._broadcast(room, {"t": "joined", "participant": participant.public(), "resumed": True}, exclude=participant.id)

    def _add_participant(self, cs: _ConnState, room: Room, msg: dict, role: str) -> Participant:
        used = {p.colour for p in room.participants.values()}
        colour = next((c for c in PALETTE if c not in used), PALETTE[(room.next_id - 1) % len(PALETTE)])
        device = msg.get("device") if msg.get("device") in _DEVICES else "desktop"
        participant = Participant(
            id=room.next_id, name=_text(msg.get("name"), 40) or f"Guest {room.next_id}", colour=colour, role=role,
            device=device, client=_text(msg.get("client"), 64), resume=secrets.token_urlsafe(24), conn=cs.conn,
        )
        room.next_id += 1
        room.participants[participant.id] = participant
        self._resume[participant.resume] = (room, participant)
        cs.room, cs.participant = room, participant
        return participant

    def _welcome(self, cs: _ConnState, room: Room, participant: Participant) -> None:
        welcome = {
            "t": "welcome", "proto": PROTO,
            "you": {"id": participant.id, "name": participant.name, "colour": participant.colour, "role": participant.role},
            "room": {"code": room.code, "join_uri": self._join_uri(room.code), "locked": room.locked},
            "resume": participant.resume,
            "participants": [p.public() for p in room.participants.values()],
            "snapshot": room.snapshot(),
        }
        if participant.role == "observer":
            welcome["backend_url"] = room.backend_url
            welcome["view_token"] = room.view_token
            welcome["view_expires_at"] = room.view_expires_at
        cs.conn.send(welcome)

    # --- presenter state ------------------------------------------------------------------------------------------------------

    def _on_model(self, cs, room: Room, p: Participant, msg: dict):
        source = msg.get("source")
        if not isinstance(source, dict) or source.get("kind") not in ("backend", "demo"):
            return False
        room.model = {**source, "title": _text(msg.get("title"), 120)}
        room.rev = msg.get("rev") if isinstance(msg.get("rev"), int) else source.get("rev")
        room.poses.clear()  # a new model: the presenter sends a full pose table after it loads
        room.state.pop("visibility", None)
        room.state.pop("scene", None)
        room.hidden_feature_ids = None
        self._relay_from(room, p, msg)

    def _on_doc_changed(self, cs, room: Room, p: Participant, msg: dict):
        rev = msg.get("rev")
        if not isinstance(rev, int):
            return False
        room.rev = max(rev, room.rev or 0)
        if isinstance(msg.get("hidden_feature_ids"), list):
            room.hidden_feature_ids = msg["hidden_feature_ids"]
        self._relay_from(room, p, msg)

    def _on_poses(self, cs, room: Room, p: Participant, msg: dict):
        items = msg.get("items")
        if not isinstance(items, list) or not all(isinstance(i, dict) and isinstance(i.get("path"), str) and _is_number_list(i.get("xf"), 12) for i in items):
            return False
        if msg.get("full"):
            room.poses = {i["path"]: i["xf"] for i in items}
        else:
            for i in items:
                room.poses[i["path"]] = i["xf"]
        self._relay_from(room, p, msg, key="poses", merge=merge_poses)

    def _on_visibility(self, cs, room, p, msg):
        if not isinstance(msg.get("hidden"), list):
            return False
        return self._keep_state(room, p, msg)

    def _on_section(self, cs, room, p, msg):
        if msg.get("on") and not (_is_number_list(msg.get("point"), 3) and _is_number_list(msg.get("normal"), 3)):
            return False
        return self._keep_state(room, p, msg)

    def _on_place(self, cs, room, p, msg):
        if not _is_number_list(msg.get("xf"), 12):
            return False
        return self._keep_state(room, p, msg)

    def _on_status(self, cs, room, p, msg):
        return self._keep_state(room, p, msg)

    def _on_scene(self, cs, room, p, msg):
        return self._keep_state(room, p, msg)

    def _keep_state(self, room: Room, p: Participant, msg: dict):
        room.state[msg["t"]] = self._stamped(p, msg)
        self._relay_from(room, p, msg, key=msg["t"])

    def _on_gather(self, cs, room, p, msg):
        self._relay_from(room, p, msg)

    def _on_marks_clear(self, cs, room: Room, p, msg):
        ids = msg.get("ids")
        if isinstance(ids, list):
            for key in [k for k in room.marks if k[1] in ids or f"{k[0]}:{k[1]}" in ids]:
                del room.marks[key]
        else:
            room.marks.clear()
        self._relay_from(room, p, msg)

    def _on_mute_all(self, cs, room: Room, p, msg):
        for other in room.participants.values():
            if other.role != "presenter":
                other.muted_by_presenter = True
        self._relay_from(room, p, msg)
        self._roster(room)

    def _on_lock(self, cs, room: Room, p, msg):
        room.locked = bool(msg.get("locked"))
        self._relay_from(room, p, {"t": "lock", "locked": room.locked})

    def _on_remove(self, cs, room: Room, p, msg):
        target = room.participants.get(msg.get("id")) if isinstance(msg.get("id"), int) else None
        if target is None or target.id == p.id:
            return False
        if target.conn is not None:
            tcs = self._conns.pop(id(target.conn), None)
            target.conn.send({"t": "error", "code": "removed", "message": "The presenter removed you from this session."})
            target.conn.close(4003)
            if tcs is not None:
                tcs.closed = True
        log.info("room %s: %s (%d) removed", room.code, target.name, target.id)
        self._forget(room, target)
        self._broadcast(room, {"t": "left", "id": target.id, "reason": "removed"})

    def _on_token(self, cs, room: Room, p, msg):
        token = _text(msg.get("view_token"), 256)
        if not token:
            return False
        room.view_token = token
        room.view_expires_at = msg.get("view_expires_at") if isinstance(msg.get("view_expires_at"), (int, float)) else None
        self._relay_from(room, p, {"t": "token", "view_token": token, "view_expires_at": room.view_expires_at})

    def _on_end(self, cs, room: Room, p, msg):
        self._end_room(room, "ended")

    # --- anyone ---------------------------------------------------------------------------------------------------------------

    def _on_presence(self, cs, room: Room, p: Participant, msg: dict):
        stamped = self._stamped(p, msg)
        room.presence[p.id] = stamped
        for other in room.connected():
            if other.id != p.id:
                other.conn.send(stamped, key=("presence", p.id))

    def _on_hand(self, cs, room: Room, p: Participant, msg: dict):
        p.hand = bool(msg.get("up"))
        self._roster(room)

    def _on_mark(self, cs, room: Room, p: Participant, msg: dict):
        mark_id = _text(msg.get("id"), 64)
        if not mark_id or msg.get("kind") not in _MARK_KINDS or not isinstance(msg.get("target"), dict):
            return False
        stamped = self._stamped(p, {**msg, "id": mark_id, "colour": p.colour})
        if msg["kind"] == "share":
            room.marks[(p.id, mark_id)] = stamped
        for other in room.connected():
            if other.id != p.id:
                other.conn.send(stamped)

    def _on_mark_clear(self, cs, room: Room, p: Participant, msg: dict):
        mark_id = _text(msg.get("id"), 64)
        if (p.id, mark_id) not in room.marks:
            return False
        del room.marks[(p.id, mark_id)]
        self._relay_from(room, p, {"t": "mark_clear", "id": mark_id})

    def _on_voice_state(self, cs, room: Room, p: Participant, msg: dict):
        p.muted = bool(msg.get("muted"))
        if not p.muted:
            p.muted_by_presenter = False  # unmuting yourself after Mute all is allowed (P3 may change this)
        p.talking = bool(msg.get("talking")) and not p.muted
        self._roster(room)

    def _on_leave(self, cs, room: Room, p: Participant, msg: dict):
        if p.role == "presenter":
            self._end_room(room, "ended")
            return
        self._conns.pop(id(cs.conn), None)
        cs.closed = True
        cs.conn.close(1000)
        log.info("room %s: %s (%d) left", room.code, p.name, p.id)
        self._forget(room, p)
        self._broadcast(room, {"t": "left", "id": p.id, "reason": "left"})

    def _on_ping(self, cs, room, p, msg):
        cs.conn.send({"t": "pong", "n": msg.get("n")})

    def _on_pong(self, cs, room, p, msg):
        return None

    # --- helpers --------------------------------------------------------------------------------------------------------------

    def _stamped(self, p: Participant, msg: dict) -> dict:
        return {**msg, "from": p.id, "at": int(self.clock() * 1000)}

    def _relay_from(self, room: Room, p: Participant, msg: dict, key=None, merge=None) -> None:
        stamped = self._stamped(p, msg)
        for other in room.connected():
            if other.id != p.id:
                other.conn.send(stamped, key=key, merge=merge)

    def _broadcast(self, room: Room, msg: dict, exclude: int | None = None) -> None:
        for other in room.connected():
            if other.id != exclude:
                other.conn.send(msg)

    def _roster(self, room: Room) -> None:
        self._broadcast(room, {"t": "roster", "participants": [p.public() for p in room.participants.values()]})

    def _forget(self, room: Room, p: Participant) -> None:
        room.participants.pop(p.id, None)
        room.presence.pop(p.id, None)
        self._resume.pop(p.resume, None)
        for key in [k for k in room.marks if k[0] == p.id]:
            del room.marks[key]

    def _end_room(self, room: Room, reason: str) -> None:
        log.info("room %s: ended (%s)", room.code, reason)
        for p in list(room.participants.values()):
            if p.conn is not None:
                cs = self._conns.pop(id(p.conn), None)
                p.conn.send({"t": "end", "reason": reason})
                p.conn.close(1000)
                if cs is not None:
                    cs.closed = True
            self._resume.pop(p.resume, None)
        self.rooms.pop(room.code, None)

    def _fail(self, cs: _ConnState, code: str, message: str) -> None:
        cs.closed = True
        cs.conn.send({"t": "error", "code": code, "message": message})
        cs.conn.close(4000)
        self._conns.pop(id(cs.conn), None)
        if cs.participant is not None and cs.room is not None and cs.participant.conn is cs.conn:
            cs.participant.conn = None
            cs.participant.dropped_at = self.clock()
            self._broadcast(cs.room, {"t": "left", "id": cs.participant.id, "reason": "dropped"}, exclude=cs.participant.id)

    def _join_uri(self, code: str) -> str:
        if self.public_url:
            return f"didsa-join:1?h={quote(self.public_url, safe='')}&c={code}"
        return f"didsa-join:1?c={code}"

    def _new_code(self) -> str:
        while True:
            code = "".join(self._rng.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
            if code not in self.rooms:
                return code
