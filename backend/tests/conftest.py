"""Sets CAD_API_KEY before any test module imports app.main, so app.auth's
startup check passes and the whole existing test suite doesn't need its own
env-var bootstrapping. conftest.py is collected before sibling test modules,
so this runs in time.
"""

import os

TEST_API_KEY = "test-api-key"

os.environ.setdefault("CAD_API_KEY", TEST_API_KEY)
