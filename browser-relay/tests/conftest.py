import os

# app/auth.py reads its API key at import time (deliberately, so a missing
# key fails startup rather than running unauthenticated - see its own
# docstring), so this has to be set before anything under app/ is first
# imported by any test module.
os.environ.setdefault("BROWSER_RELAY_API_KEY", "test-relay-key")
