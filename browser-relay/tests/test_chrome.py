import asyncio

import pytest

from app.chrome import ChromePool, TooManySessionsError, build_chrome_args


def test_build_chrome_args_is_headless_and_local_only():
    args = build_chrome_args("chromium", 9333, "/tmp/some-profile")
    assert "--headless=new" in args
    assert "--remote-debugging-port=9333" in args
    assert "--remote-debugging-address=127.0.0.1" in args
    assert "--user-data-dir=/tmp/some-profile" in args


def test_new_tab_refuses_past_the_session_cap():
    # Doesn't launch a real Chrome: the cap is checked (and raises) before
    # ChromePool.new_tab() would ever make an HTTP call, so pre-filling
    # _open_tabs past the (default 2) cap exercises the whole refusal path
    # without needing a live CDP endpoint.
    pool = ChromePool()
    pool._open_tabs = {"tab-1", "tab-2"}

    async def _attempt():
        with pytest.raises(TooManySessionsError):
            await pool.new_tab()

    asyncio.run(_attempt())
