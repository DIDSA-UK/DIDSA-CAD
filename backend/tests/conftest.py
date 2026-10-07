"""Sets CAD_API_KEY before any test module imports app.main, so app.auth's
startup check passes and the whole existing test suite doesn't need its own
env-var bootstrapping. conftest.py is collected before sibling test modules,
so this runs in time.

Also tags the gear test modules with the `gears` marker (see
`_GEAR_TEST_FILE_PATTERN`) so the expensive real-geometry gear suites can be
selected or skipped as a group: `pytest -m "not gears"` for the fast core
loop, `pytest -m gears` for just the gears. The bevel *pair* modules (the
slowest of all: meshing-phase searches, some 100-280 s each) additionally
carry `bevel_pair`, so `-m "gears and not bevel_pair"` / `-m bevel_pair` split
them off. CI runs core / gears / bevel_pair as three parallel jobs (see
.github/workflows/backend-verify.yml).
"""

import os
import re

import pytest

TEST_API_KEY = "test-api-key"

os.environ.setdefault("CAD_API_KEY", TEST_API_KEY)

# Test modules whose file name says they exercise gear / bevel / rack / planetary
# features. Matched on the basename so a new `test_*gear*.py` is picked up
# automatically with no registration step.
_GEAR_TEST_FILE_PATTERN = re.compile(r"^test_.*(gear|bevel|rack|planetary).*\.py$")


_BEVEL_PAIR_TEST_FILE_PATTERN = re.compile(r"^test_bevel_pair.*\.py$")


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "gears: gear / bevel / rack / planetary tests (real-geometry, the slowest part of the suite); "
        "applied automatically by file name in conftest.py",
    )
    config.addinivalue_line(
        "markers",
        "bevel_pair: the bevel pair modules (a subset of `gears`; the slowest tests in the suite); "
        "applied automatically by file name in conftest.py",
    )


def pytest_collection_modifyitems(config, items):
    for item in items:
        if _GEAR_TEST_FILE_PATTERN.match(os.path.basename(str(item.fspath))):
            item.add_marker(pytest.mark.gears)
        if _BEVEL_PAIR_TEST_FILE_PATTERN.match(os.path.basename(str(item.fspath))):
            item.add_marker(pytest.mark.bevel_pair)
