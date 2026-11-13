"""The Part id of a native file, for the part-id index (the moved-files rule).

Reads ONE field: `document.root_part_id` of a native project file (backend/app/document/native_format.py, `export_native`:
`{"schema_version": 1, "document": {"root_part_id": "...", "parts": [...]}}`). Nothing else in the file is looked at or kept, and
nothing is imported from the backend. A file that is not native JSON, is unreadable, is over MAX_BYTES, or has no string
root_part_id gets None.
"""

import json

NATIVE_SUFFIXES = (".didsa", ".didsaprt", ".didsa.json")

# A native file is JSON that is parsed whole to reach one field; past this size the parse would cost more memory than a 4 GB Pi can spare.
MAX_BYTES = 100 * 1024 * 1024


def looks_native(path: str) -> bool:
    return path.lower().endswith(NATIVE_SUFFIXES)


def root_part_id(file_path: str, size: int) -> str | None:
    """`file_path` is the bytes on disk. The caller decides by name (`looks_native`) whether to ask; this sniffs too (the first
    non-blank byte must be `{`) so a big binary is not run through the JSON parser."""
    if size > MAX_BYTES:
        return None
    try:
        with open(file_path, "rb") as handle:
            head = handle.read(64).lstrip()
            if not head.startswith(b"{"):
                return None
            handle.seek(0)
            data = json.load(handle)
    except (OSError, ValueError, RecursionError, MemoryError):
        return None
    if not isinstance(data, dict):
        return None
    document = data.get("document")
    if not isinstance(document, dict):
        return None
    value = document.get("root_part_id")
    return value if isinstance(value, str) and value else None
