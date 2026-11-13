"""Path safety for everything the store takes from a client (a project name, a file path inside a project).

A path is refused, never repaired: a client that sends one of these has a bug, and quietly rewriting it would store the file
somewhere the client does not expect. The rules are the strictest of the three places a server project can end up: the Pi's
file system, a synced Drive / OneDrive folder, and a Windows desktop (docs/shared-storage-scope.md, sections 4 and 5).

Refused:
  * an empty path or component, an absolute path (leading "/"), and a backslash (a Windows separator, so `a\\..\\b` cannot sneak by)
  * "." and ".." components
  * any component called `.didsa-store` (the store's own data, never served), in any case
  * characters Windows cannot store in a name: < > : " | ? * and control characters (0-31, 127)
  * a component ending in a dot or a space, and the reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9), with or without an extension
  * a component over 255 characters, a path over 1024
  * a path the two version routes could not tell from a history request: a last component `versions`, or `versions/<digits>`
    (`GET .../files/a/versions` lists the versions of `a`, `GET .../files/a/versions/3` serves its third version)
"""

import re

STORE_DIR_NAME = ".didsa-store"

MAX_COMPONENT = 255
MAX_PATH = 1024

_BAD_CHARS = re.compile(r'[<>:"|?*\x00-\x1f\x7f\\]')
_RESERVED = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}


class UnsafePath(ValueError):
    """The path (or project name) must be refused; str(e) says why."""


def _check_component(part: str, what: str) -> None:
    if part == "":
        raise UnsafePath(f"{what} has an empty part")
    if part in (".", ".."):
        raise UnsafePath(f"{what} may not contain '{part}'")
    if part.lower() == STORE_DIR_NAME:
        raise UnsafePath(f"{what} may not name {STORE_DIR_NAME} (the store's own data)")
    if _BAD_CHARS.search(part):
        raise UnsafePath(f"{what} has a character Windows cannot store in a name (< > : \" | ? * \\ or a control character)")
    if part.endswith((".", " ")):
        raise UnsafePath(f"{what} has a name ending in a dot or a space, which Windows cannot store")
    if part.split(".")[0].rstrip(" ").lower() in _RESERVED:
        raise UnsafePath(f"{what} uses a name Windows reserves ({part})")
    if len(part) > MAX_COMPONENT:
        raise UnsafePath(f"{what} has a name over {MAX_COMPONENT} characters")


def validate_project_name(name) -> str:
    if not isinstance(name, str) or name == "":
        raise UnsafePath("a project name is required")
    if "/" in name:
        raise UnsafePath("a project name is one folder name: no '/'")
    if name.startswith("."):
        raise UnsafePath("a project name may not start with '.'")
    _check_component(name, "the project name")
    return name


def validate_file_path(path) -> str:
    """Returns the path unchanged when it is safe; raises UnsafePath otherwise."""
    if not isinstance(path, str) or path == "":
        raise UnsafePath("a file path is required")
    if path.startswith("/"):
        raise UnsafePath("an absolute path is refused: paths are relative to the project")
    if len(path) > MAX_PATH:
        raise UnsafePath(f"a path over {MAX_PATH} characters is refused")
    parts = path.split("/")
    for part in parts:
        _check_component(part, "the path")
    if parts[-1] == "versions" or (len(parts) >= 2 and parts[-2] == "versions" and parts[-1].isdigit()):
        raise UnsafePath("a path ending in 'versions' or 'versions/<number>' collides with the version-history routes")
    return path


def is_valid_name_for_scan(name: str) -> bool:
    """A single directory entry found on disk: does it pass the same component rules? (The scan skips entries that do not, so
    everything in a tree listing can be asked for again.)"""
    try:
        _check_component(name, "name")
    except UnsafePath:
        return False
    return True
