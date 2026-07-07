from fastapi import HTTPException

from app.document.models import Document, Part, SketchFeature

# Temporary in-memory store, same stopgap as app.sketch.store - see the note
# there. Single Document instance per the brief (no multi-doc management).
_document = Document(id="default")


def get_document() -> Document:
    return _document


def replace_document(document: Document) -> None:
    """Native file import's "full replace, not merge" (client-owned files,
    locked-in scope): swaps out the whole in-memory Document for `document`.
    Only intended to be called by `app.document.router`'s native-import
    endpoint, immediately followed by `app.sketch.store.replace_all_sketches`
    doing the same for the Sketch side - together they make an import a
    clean, atomic full replacement rather than a merge with whatever
    Document/Sketches were open before."""
    global _document
    _document = document


def get_part_or_404(part_id: str) -> Part:
    part = _document.parts.get(part_id)
    if part is None:
        raise HTTPException(status_code=404, detail="Part not found")
    return part


def is_sketch_locked(sketch_id: str) -> bool:
    """True if `sketch_id` belongs to a SketchFeature that is locked (not
    the last Feature in its Part). Sketches not wrapped by any Feature at
    all (e.g. created directly via the sketch router rather than through a
    Part) are never locked - this only ever returns True for a sketch that
    is genuinely behind a later Feature."""
    for part in _document.parts.values():
        for feature in part.features:
            if isinstance(feature, SketchFeature) and feature.sketch_id == sketch_id:
                return part.is_locked(feature.id)
    return False
