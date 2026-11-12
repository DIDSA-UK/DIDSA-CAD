"""F-6 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): reading a STEP (or IGES) file AS AN ASSEMBLY - one Part per distinct product, one Occurrence
per placement, names and colours kept - instead of `import_geometry`'s one-Body import.

**STEP** is read through OCCT's XCAF (`STEPCAFControl_Reader`, the `TDocStd_Document("any-label")` idiom `step_export.py` documents: no
`XCAFApp_Application`). The free shapes are walked; an assembly label's components are references to a prototype label with a `TopLoc_Location`; a
prototype with a shape is a leaf, anything else an assembly of its own. Each distinct prototype becomes ONE Part (its shape re-encoded as a STEP of
its own, so `resolve_import` keeps working), however many times it is placed.

**Placements are rigid.** An Occurrence transform is a rotation plus a translation (`RigidTransform`). A placement that is mirrored (negative
determinant) or scaled cannot be one, so for a leaf product it is **baked**: the prototype's shape is transformed by the whole placement into a Part of
its own ("<name> (mirrored)" / "(scaled)") placed at identity. A mirrored or scaled *sub-assembly* is skipped and reported.

**One failing product does not sink the import**: a product with no shape, one that cannot be re-encoded, a mirrored sub-assembly are skipped and listed
in the report ("35 of 37 parts imported; 2 skipped: ...").

**IGES** has no product structure worth the name, so the choice is one part or **one part per solid** (`read_iges_solids`): each solid of the read shape
becomes a Part with one Occurrence at identity, named "Solid 1..n".

The caller (`router.py`) turns the result into a native payload (`build_native_payload`) and merges or replaces through the same paths
`add_component` / `import_native` use, so the session is only replaced if everything that was kept is valid."""

from __future__ import annotations

import base64
import math
import os
import re
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field

from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Trsf
from OCC.Core.IFSelect import IFSelect_RetDone
from OCC.Core.Quantity import Quantity_Color, Quantity_TOC_sRGB
from OCC.Core.STEPCAFControl import STEPCAFControl_Reader
from OCC.Core.TDF import TDF_Label, TDF_LabelSequence
from OCC.Core.TDocStd import TDocStd_Document
from OCC.Core.TopAbs import TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, topods
from OCC.Core.XCAFDoc import XCAFDoc_ColorGen, XCAFDoc_ColorSurf, XCAFDoc_ColorTool, XCAFDoc_DocumentTool

from app.document.step_export import export_step

MAX_PRODUCTS = 2000  # a file with more distinct products is refused with a clear error
READ_TIMEOUT_SECONDS = 120.0
MAX_NAME_LENGTH = 80


class AssemblyImportError(ValueError):
    """The file cannot be imported as an assembly (a parse failure, a cap exceeded, no shapes). `code` is the response's error `type`."""

    def __init__(self, message: str, code: str = "import_failed"):
        super().__init__(message)
        self.code = code


@dataclass
class ProductNode:
    """One distinct product of the file (a prototype): a leaf with a `shape` in its own frame, or an assembly with `children`."""

    key: str
    name: str
    shape: TopoDS_Shape | None = None
    children: list[tuple["ProductNode", gp_Trsf]] = field(default_factory=list)
    child_colours: list[str | None] = field(default_factory=list)  # parallel to children: a colour set on the placement itself (an Occurrence's own colour)
    colour: str | None = None


@dataclass
class StepStructure:
    roots: list[ProductNode]
    products: int  # distinct leaf products with a shape
    assemblies: int  # distinct assembly products
    instances: int  # component placements, counting every one
    mirrored_instances: int  # placements that are mirrored or scaled (baked or skipped on import)
    name: str


def sanitise_name(name: str, fallback: str = "Part") -> str:
    """A name fit to be a file name: no path or reserved characters, no leading / trailing dots or spaces, bounded length."""
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")
    return cleaned[:MAX_NAME_LENGTH].strip(" .") or fallback


def unique_name(name: str, used: set[str]) -> str:
    """`name` made unique (case-insensitively) against `used`, which it is added to: "Bolt", "Bolt 2", "Bolt 3"."""
    candidate = name
    counter = 2
    while candidate.lower() in used:
        candidate = f"{name} {counter}"
        counter += 1
    used.add(candidate.lower())
    return candidate


def _label_name(label: TDF_Label) -> str:
    try:
        return str(label.GetLabelName()).strip()
    except Exception:  # an unnamed label raises in some builds
        return ""


def _label_colour(colour_tool, label: TDF_Label) -> str | None:
    colour = Quantity_Color()
    for kind in (XCAFDoc_ColorSurf, XCAFDoc_ColorGen):
        if XCAFDoc_ColorTool.GetColor(label, kind, colour):
            r, g, b = colour.Values(Quantity_TOC_sRGB)  # (read as sRGB explicitly: the writer in step_export.py sets them as sRGB)
            return "#%02X%02X%02X" % tuple(max(0, min(255, round(c * 255))) for c in (r, g, b))
    return None


def _dominant_sub_colour(shape_tool, colour_tool, label: TDF_Label) -> str | None:
    """The colour of the solids / faces of a leaf product (sub-label colours), the one covering the most faces; None when none carries one."""
    from OCC.Core.TopAbs import TopAbs_FACE
    from OCC.Core.TopExp import TopExp_Explorer

    counts: dict[str, int] = {}
    subs = TDF_LabelSequence()
    shape_tool.GetSubShapes(label, subs)
    for i in range(subs.Length()):
        sub = subs.Value(i + 1)
        colour = _label_colour(colour_tool, sub)
        sub_shape = shape_tool.GetShape(sub)
        if colour is None or sub_shape is None or sub_shape.IsNull():
            continue
        explorer = TopExp_Explorer(sub_shape, TopAbs_FACE)
        while explorer.More():
            counts[colour] = counts.get(colour, 0) + 1
            explorer.Next()
    return max(counts, key=counts.get) if counts else None


def _is_rigid(trsf: gp_Trsf) -> bool:
    return not trsf.IsNegative() and abs(trsf.ScaleFactor() - 1.0) < 1e-9


def _read_xcaf(data: bytes):
    fd, path = tempfile.mkstemp(suffix=".step")
    os.close(fd)
    try:
        with open(path, "wb") as handle:
            handle.write(data)
        doc = TDocStd_Document("didsa-cad-step-assembly-import")
        reader = STEPCAFControl_Reader()
        reader.SetColorMode(True)
        reader.SetNameMode(True)
        status = reader.ReadFile(path)
        if status != IFSelect_RetDone:
            raise AssemblyImportError(f"Could not parse STEP file (status={status})", "invalid_import_data")
        if not reader.Transfer(doc):
            raise AssemblyImportError("STEP file transferred no usable shapes")
        return doc
    finally:
        os.unlink(path)


def _with_timeout(function, *args):
    executor = ThreadPoolExecutor(max_workers=1)
    future = executor.submit(function, *args)
    try:
        return future.result(timeout=READ_TIMEOUT_SECONDS)
    except FutureTimeout as exc:
        raise AssemblyImportError(
            f"Reading the file took longer than {int(READ_TIMEOUT_SECONDS)} s: import it as one part, or split it", "import_too_slow"
        ) from exc
    finally:
        executor.shutdown(wait=False)


def read_step_structure(data: bytes) -> StepStructure:
    """Reads the product structure of a STEP file (see the module docstring). Raises `AssemblyImportError`."""
    return _with_timeout(_read_step_structure, data)


def _read_step_structure(data: bytes) -> StepStructure:
    doc = _read_xcaf(data)
    shape_tool = XCAFDoc_DocumentTool.ShapeTool(doc.Main())
    colour_tool = XCAFDoc_DocumentTool.ColorTool(doc.Main())
    nodes: dict[int, ProductNode] = {}
    counts = {"instances": 0, "mirrored": 0}

    def build(label: TDF_Label, depth: int) -> ProductNode:
        key = label.Tag()
        if key in nodes:
            return nodes[key]
        node = ProductNode(key=str(key), name=_label_name(label), colour=_label_colour(colour_tool, label))
        nodes[key] = node
        if depth > 64:
            return node
        if shape_tool.IsAssembly(label):
            components = TDF_LabelSequence()
            shape_tool.GetComponents(label, components)
            for index in range(components.Length()):
                component = components.Value(index + 1)
                if not shape_tool.IsReference(component):
                    continue
                referred = TDF_Label()
                shape_tool.GetReferredShape(component, referred)
                child = build(referred, depth + 1)
                trsf = shape_tool.GetLocation(component).Transformation()
                counts["instances"] += 1
                if not _is_rigid(trsf):
                    counts["mirrored"] += 1
                node.children.append((child, trsf))
                node.child_colours.append(_label_colour(colour_tool, component))
        else:
            shape = shape_tool.GetShape(label)
            if shape is not None and not shape.IsNull():
                node.shape = shape
                if node.colour is None:
                    node.colour = _dominant_sub_colour(shape_tool, colour_tool, label)  # colours on its solids or faces (SolidWorks puts them on the solids)
        return node

    labels = TDF_LabelSequence()
    shape_tool.GetFreeShapes(labels)
    roots = [build(labels.Value(i + 1), 0) for i in range(labels.Length())]
    if not roots:
        raise AssemblyImportError("STEP file holds no shapes")
    leaves = sum(1 for n in nodes.values() if n.shape is not None)
    assemblies = sum(1 for n in nodes.values() if n.shape is None and n.children)
    if leaves > MAX_PRODUCTS:
        raise AssemblyImportError(
            f"This file has {leaves:,} parts (the limit is {MAX_PRODUCTS:,}): import it as one part, or split it", "import_too_large"
        )
    return StepStructure(
        roots=roots,
        products=leaves,
        assemblies=assemblies,
        instances=counts["instances"],
        mirrored_instances=counts["mirrored"],
        name=roots[0].name if len(roots) == 1 else "",
    )


def probe_step(data: bytes) -> dict:
    """What `POST /import/probe` answers for a STEP file: the structure counts, no geometry sent anywhere."""
    structure = read_step_structure(data)
    return {
        "products": structure.products,
        "assemblies": structure.assemblies,
        "instances": structure.instances,
        "has_structure": structure.assemblies > 0,
        "mirrored_instances": structure.mirrored_instances,
        "name": structure.name,
    }


def read_iges_solids(data: bytes) -> StepStructure:
    """IGES "one part per solid": each solid of the read shape is a product placed once at identity under a synthetic root."""
    from app.document.import_geometry import _shape_from_iges

    shape = _shape_from_iges(data)
    solids: list[TopoDS_Shape] = []
    explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    while explorer.More():
        solids.append(topods.Solid(explorer.Current()))
        explorer.Next()
    if not solids:
        solids = [shape]  # surfaces only: one product holding whatever was read
    if len(solids) > MAX_PRODUCTS:
        raise AssemblyImportError(f"This file has {len(solids):,} solids (the limit is {MAX_PRODUCTS:,})", "import_too_large")
    from app.document.import_colours import colour_index

    colours = colour_index("iges", data)  # colours on import: each solid takes the colour covering most of it
    children = [(ProductNode(key=str(i), name=f"Solid {i + 1}", shape=solid, colour=colours.dominant_colour(solid)), gp_Trsf()) for i, solid in enumerate(solids)]
    root = ProductNode(key="root", name="", children=children)
    return StepStructure(roots=[root], products=len(solids), assemblies=0, instances=len(solids), mirrored_instances=0, name="")


def probe_iges(data: bytes) -> dict:
    structure = read_iges_solids(data)
    return {"products": structure.products, "assemblies": 0, "instances": structure.instances, "has_structure": False, "mirrored_instances": 0, "name": ""}


# --- building the native payload ---------------------------------------------------------------------------------------------


def _rigid_to_dict(trsf: gp_Trsf) -> dict:
    """A rigid `gp_Trsf` as `RigidTransform`'s wire shape (rotate about the origin, then translate: the convention `apply_rigid_transform_to_shape` uses)."""
    translation = trsf.TranslationPart()
    quaternion = trsf.GetRotation()
    w = max(-1.0, min(1.0, quaternion.W()))
    angle = 2.0 * math.acos(w)
    sin_half = math.sqrt(max(0.0, 1.0 - w * w))
    if sin_half < 1e-9 or abs(angle) < 1e-12:
        axis_values = [0.0, 0.0, 1.0]
        angle = 0.0
    else:
        axis_values = [quaternion.X() / sin_half, quaternion.Y() / sin_half, quaternion.Z() / sin_half]
        if angle > math.pi:  # the shorter way round
            angle = 2.0 * math.pi - angle
            axis_values = [-v for v in axis_values]
    return {"translation": [translation.X(), translation.Y(), translation.Z()], "rotation_axis": axis_values, "rotation_angle_degrees": math.degrees(angle)}


@dataclass
class AssemblyImport:
    payload: dict  # a native project payload (schema_version, document, sketches)
    root_part_id: str  # the imported top product's Part
    part_files: dict[str, str]  # Part id -> the file name suggested for it (unique, sanitised, ".didsa")
    part_names: dict[str, str]
    folder: str  # the folder name suggested for the new files (named after the import)
    report: dict  # {"imported": n, "total": n, "skipped": [{"name", "reason"}], "baked": n}


def build_native_payload(structure: StepStructure, root_name: str, schema_version: int = 1) -> AssemblyImport:
    """The parts, occurrences and import features of `structure` as one native payload (see the module docstring for the baking and skipping rules)."""
    used_files: set[str] = set()
    parts: list[dict] = []
    part_files: dict[str, str] = {}
    part_names: dict[str, str] = {}
    skipped: list[dict] = []
    baked = {"count": 0}
    part_id_of: dict[str, str] = {}
    leaf_total = 0

    def new_part(name: str, features: list[dict], occurrences: list[dict], appearance: dict | None) -> str:
        part_id = str(uuid.uuid4())
        file_name = unique_name(sanitise_name(name), used_files)
        part: dict = {
            "id": part_id, "name": name or file_name, "features": features, "part_number": None, "description": None, "revision": None,
            "remarks": None, "supplier": None, "supplier_part_number": None, "default_material": None, "body_material_assignments": {},
            "occurrences": occurrences, "mates": [], "component_patterns": [],
        }
        if appearance:
            part["appearance"] = appearance
        parts.append(part)
        part_files[part_id] = f"{file_name}.didsa"
        part_names[part_id] = part["name"]
        return part_id

    def leaf_part(shape: TopoDS_Shape, name: str, colour: str | None) -> str | None:
        try:
            data = export_step({"body": shape})
        except Exception as exc:  # a product OCCT cannot write back out must not sink the import
            skipped.append({"name": name, "reason": f"could not be re-encoded ({exc})"})
            return None
        feature = {"type": "import", "id": str(uuid.uuid4()), "source_format": "step", "source_data_base64": base64.b64encode(data).decode("ascii")}
        return new_part(name, [feature], [], {"colour": colour} if colour else None)

    def occurrence(part_id: str, trsf: gp_Trsf, fixed: bool, colour: str | None = None) -> dict:
        return {
            "id": str(uuid.uuid4()), "external_ref": part_files[part_id], "resolved_part_id": part_id, "name_override": None,
            "transform": _rigid_to_dict(trsf), "suppressed": False, "hidden": False, "fixed": fixed, "color": colour,
        }

    def bake_assembly(child: ProductNode, trsf: gp_Trsf, name: str, kind: str, stack: tuple[str, ...]) -> str | None:
        """A mirrored or scaled SUB-ASSEMBLY: flattened into a new assembly Part ("<name> (mirrored)") whose occurrences are the subtree's leaves, each placed by the
        composed transform (still rigid -> an Occurrence of the shared leaf Part; mirrored / scaled -> a baked leaf Part). Nested placements inside it are composed."""
        occurrences: list[dict] = []

        def walk(node: ProductNode, accumulated: gp_Trsf, depth: int) -> None:
            if depth > 64 or node.key in stack:
                return
            for index, (grandchild, t) in enumerate(node.children):
                full = accumulated.Multiplied(t)
                colour = node.child_colours[index] if index < len(node.child_colours) else None
                if grandchild.shape is not None:
                    if _is_rigid(full):
                        leaf_id = convert(grandchild, f"{name} {len(occurrences) + 1}", stack + (node.key,))
                        if leaf_id is not None:
                            occurrences.append(occurrence(leaf_id, full, False, colour))
                    else:
                        nonlocal leaf_total
                        leaf_total += 1
                        baked_shape = BRepBuilderAPI_Transform(grandchild.shape, full, True).Shape()
                        baked_id = leaf_part(baked_shape, f"{grandchild.name or name} ({kind})", grandchild.colour)
                        if baked_id is not None:
                            baked["count"] += 1
                            occurrences.append(occurrence(baked_id, gp_Trsf(), False, colour))
                elif grandchild.children:
                    walk(grandchild, full, depth + 1)

        walk(child, trsf, 0)
        if not occurrences:
            skipped.append({"name": name, "reason": f"a {kind} sub-assembly with nothing importable inside"})
            return None
        return new_part(f"{name} ({kind})", [], occurrences, None)

    def convert(node: ProductNode, fallback: str, stack: tuple[str, ...]) -> str | None:
        nonlocal leaf_total
        if node.key in part_id_of:
            return part_id_of[node.key]
        name = node.name or fallback
        if node.shape is not None:
            leaf_total += 1
            part_id = leaf_part(node.shape, name, node.colour)
            if part_id is not None:
                part_id_of[node.key] = part_id
            return part_id
        if not node.children:
            skipped.append({"name": name, "reason": "has no shape and no components"})
            return None
        if node.key in stack:
            skipped.append({"name": name, "reason": "refers to itself"})
            return None
        occurrences: list[dict] = []
        for index, (child, trsf) in enumerate(node.children):
            child_fallback = f"{name} {index + 1}"
            if _is_rigid(trsf):
                child_id = convert(child, child_fallback, stack + (node.key,))
                if child_id is not None:
                    occurrences.append(occurrence(child_id, trsf, fixed=not occurrences and not stack, colour=node.child_colours[index] if index < len(node.child_colours) else None))
                continue
            kind = "mirrored" if trsf.IsNegative() else "scaled"
            if child.shape is None:
                flat_id = bake_assembly(child, trsf, child.name or child_fallback, kind, stack + (node.key,))
                if flat_id is not None:
                    occurrences.append(occurrence(flat_id, gp_Trsf(), fixed=not occurrences and not stack, colour=node.child_colours[index] if index < len(node.child_colours) else None))
                continue
            baked_shape = BRepBuilderAPI_Transform(child.shape, trsf, True).Shape()
            baked_id = leaf_part(baked_shape, f"{child.name or child_fallback} ({kind})", child.colour)
            leaf_total += 1
            if baked_id is not None:
                baked["count"] += 1
                occurrences.append(occurrence(baked_id, gp_Trsf(), fixed=not occurrences and not stack))
        if not occurrences:
            skipped.append({"name": name, "reason": "none of its components could be imported"})
            return None
        part_id = new_part(name, [], occurrences, None)
        part_id_of[node.key] = part_id
        return part_id

    root_name = root_name.strip() or "Imported assembly"
    if len(structure.roots) == 1 and (structure.roots[0].shape is not None or structure.roots[0].children):
        top = structure.roots[0]
        if not top.name:
            top.name = root_name
        root_id = convert(top, root_name, ())
    else:
        top = ProductNode(key="synthetic-root", name=root_name, children=[(r, gp_Trsf()) for r in structure.roots])
        root_id = convert(top, root_name, ())
    if root_id is None:
        raise AssemblyImportError("None of the file's products could be imported" + (f" ({skipped[0]['reason']})" if skipped else ""))

    imported = sum(1 for part in parts if part["features"])
    folder = sanitise_name(root_name, "Imported assembly")
    payload = {"schema_version": schema_version, "document": {"id": "default", "root_part_id": root_id, "parts": parts}, "sketches": []}
    return AssemblyImport(
        payload=payload, root_part_id=root_id, part_files=part_files, part_names=part_names, folder=folder,
        report={"imported": imported, "total": leaf_total, "skipped": skipped, "baked": baked["count"]},
    )
