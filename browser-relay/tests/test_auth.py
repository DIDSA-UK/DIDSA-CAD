from app.auth import is_authorized


class _FakeHeaders(dict):
    """Starlette's WebSocket.headers is case-insensitive; app/auth.py's
    is_authorized() looks up the lowercase key directly, so this fake only
    needs to behave like a plain dict keyed by the lowercase header name -
    good enough to exercise is_authorized() without pulling in Starlette."""


def test_rejects_missing_key():
    assert is_authorized(_FakeHeaders()) is False


def test_rejects_wrong_key():
    assert is_authorized(_FakeHeaders({"x-api-key": "wrong"})) is False


def test_accepts_correct_key():
    assert is_authorized(_FakeHeaders({"x-api-key": "test-relay-key"})) is True
