#include "occt_ffi_shim.h"

#include <exception>
#include <string>
#include <vector>

#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TCollection_AsciiString.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>

namespace {

// Thread-local last-error string - mirrors slvs_ffi_shim.cpp's own
// exception-at-the-boundary convention, but slvs never needed a real error
// *message* (its handle-returning calls only ever need a 0/nullptr
// sentinel); a STEP load/tessellate failure is much more useful to the
// caller (and, through it, occt_last_error()'s surfacing in
// mesh_viewer_screen.dart's _pickAndLoad error path) with a real message
// attached.
thread_local std::string g_last_error;

void set_error(const std::string& message) { g_last_error = message; }

void clear_error() { g_last_error.clear(); }

// One loaded STEP document's own state - owns the TDocStd_Document plus the
// TDF_LabelSequence of free-shape labels (bodies) resolved once at load
// time, since XCAFDoc_ShapeTool::GetFreeShapes is not free to call
// repeatedly on a large assembly.
struct OcctDocument {
    opencascade::handle<TDocStd_Document> doc;
    TDF_LabelSequence freeShapes;
};

struct OcctTessellation {
    // Flat triangle soup - triangle i owns positions[9*i..9*i+8] and
    // normals[9*i..9*i+8], matching DecodedMesh's own convention (see
    // mesh_data.dart). Stored as double (OCCT's own precision) - narrowing
    // to float32 is left to the Dart side (see occt_ffi_shim.h's own doc
    // comment on occt_tessellation_copy_positions).
    std::vector<double> positions;
    std::vector<double> normals;
};

OcctDocument* asDocument(OcctDocumentHandle handle) { return static_cast<OcctDocument*>(handle); }
OcctTessellation* asTessellation(OcctTessellationHandle handle) { return static_cast<OcctTessellation*>(handle); }

// De-indexes [face]'s own triangulation (if any) into [outPositions]/
// [outNormals], applying [face]'s TopLoc_Location (a face inside a
// compound/assembly is very commonly placed via a location transform rather
// than baked directly into its own triangulation - skipping this would
// silently render every non-identity-placed face in the wrong spot) and
// respecting TopAbs_REVERSED orientation (flips the winding, and so the
// outward-facing normal, exactly like the backend's own
// _append_face_triangles in backend/app/document/mesh.py).
void appendFaceTriangles(const TopoDS_Face& face, std::vector<double>& outPositions, std::vector<double>& outNormals) {
    TopLoc_Location location;
    opencascade::handle<Poly_Triangulation> triangulation = BRep_Tool::Triangulation(face, location);
    if (triangulation.IsNull()) return;

    const gp_Trsf& transform = location.Transformation();
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    const int triangleCount = triangulation->NbTriangles();

    for (int t = 1; t <= triangleCount; ++t) {
        int i1, i2, i3;
        triangulation->Triangle(t).Get(i1, i2, i3);
        if (reversed) std::swap(i2, i3);

        gp_Pnt p1 = triangulation->Node(i1).Transformed(transform);
        gp_Pnt p2 = triangulation->Node(i2).Transformed(transform);
        gp_Pnt p3 = triangulation->Node(i3).Transformed(transform);

        gp_Vec edge1(p1, p2);
        gp_Vec edge2(p1, p3);
        gp_Vec normal = edge1.Crossed(edge2);
        const double length = normal.Magnitude();
        if (length > 1e-12) {
            normal /= length;
        } else {
            normal = gp_Vec(0, 0, 1);
        }

        const gp_Pnt* verts[3] = {&p1, &p2, &p3};
        for (int v = 0; v < 3; ++v) {
            outPositions.push_back(verts[v]->X());
            outPositions.push_back(verts[v]->Y());
            outPositions.push_back(verts[v]->Z());
            outNormals.push_back(normal.X());
            outNormals.push_back(normal.Y());
            outNormals.push_back(normal.Z());
        }
    }
}

}  // namespace

extern "C" {

OcctDocumentHandle occt_document_load_step(const char* path) {
    clear_error();
    if (path == nullptr) {
        set_error("occt_document_load_step: path is null");
        return nullptr;
    }
    try {
        // No XCAFApp_Application::NewDocument idiom - the backend's own
        // extract_step_metadata docstring (backend/app/document/
        // import_geometry.py) documents this as a hard process abort in
        // pythonocc-core's build of OCCT, unrecoverable by any amount of
        // exception handling; plain TDocStd_Document construction is the
        // confirmed-working alternative this mirrors.
        auto document = new OcctDocument();
        document->doc = new TDocStd_Document("didsa-cad-step-import");

        STEPCAFControl_Reader reader;
        reader.SetNameMode(true);
        if (reader.ReadFile(path) != IFSelect_RetDone) {
            set_error(std::string("Could not read STEP file: ") + path);
            delete document;
            return nullptr;
        }
        if (!reader.Transfer(document->doc)) {
            set_error(std::string("Could not transfer STEP data into an XCAF document: ") + path);
            delete document;
            return nullptr;
        }

        opencascade::handle<XCAFDoc_ShapeTool> shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->doc->Main());
        // Unlike the backend's own extract_step_metadata (which only reads
        // Value(1), the first free shape, for its Part-Properties-only use
        // case), this walks every free shape - a real multi-body STEP
        // assembly is exactly what this viewer's tap-to-hide/invert/reset
        // feature is for (see this file's own header comment).
        shapeTool->GetFreeShapes(document->freeShapes);

        if (document->freeShapes.Length() < 1) {
            set_error(std::string("STEP file has no free shapes (bodies): ") + path);
            delete document;
            return nullptr;
        }

        return document;
    } catch (const std::exception& e) {
        set_error(std::string("occt_document_load_step: ") + e.what());
        return nullptr;
    } catch (...) {
        set_error("occt_document_load_step: unknown native exception");
        return nullptr;
    }
}

void occt_document_destroy(OcctDocumentHandle handle) {
    delete asDocument(handle);
}

const char* occt_last_error() { return g_last_error.c_str(); }

int32_t occt_document_body_count(OcctDocumentHandle handle) {
    clear_error();
    try {
        auto document = asDocument(handle);
        if (document == nullptr) {
            set_error("occt_document_body_count: null document");
            return -1;
        }
        return static_cast<int32_t>(document->freeShapes.Length());
    } catch (...) {
        set_error("occt_document_body_count: unknown native exception");
        return -1;
    }
}

const char* occt_document_body_name(OcctDocumentHandle handle, int32_t index) {
    clear_error();
    try {
        auto document = asDocument(handle);
        if (document == nullptr || index < 0 || index >= document->freeShapes.Length()) {
            set_error("occt_document_body_name: invalid document/index");
            return "";
        }
        // 1-based per OCCT's own TDF_LabelSequence::Value convention (see
        // extract_step_metadata's own free_shapes.Value(1) for the same
        // 1-based indexing on the same call, applied to just the first body).
        const TDF_Label label = document->freeShapes.Value(index + 1);
        thread_local std::string nameStorage;
        nameStorage.clear();
        // Real OCCT C++ has no TDF_Label::GetLabelName convenience method
        // (that's a pythonocc-core-only wrapper the backend's own
        // extract_step_metadata calls - see that function's own docstring)
        // - the genuine API is a TDataStd_Name attribute lookup.
        opencascade::handle<TDataStd_Name> nameAttribute;
        if (label.FindAttribute(TDataStd_Name::GetID(), nameAttribute)) {
            nameStorage = TCollection_AsciiString(nameAttribute->Get()).ToCString();
        }
        return nameStorage.c_str();
    } catch (...) {
        set_error("occt_document_body_name: unknown native exception");
        return "";
    }
}

int32_t occt_document_body_bbox(OcctDocumentHandle handle, int32_t index, double* out_min, double* out_max) {
    clear_error();
    try {
        auto document = asDocument(handle);
        if (document == nullptr || out_min == nullptr || out_max == nullptr || index < 0 ||
            index >= document->freeShapes.Length()) {
            set_error("occt_document_body_bbox: invalid arguments");
            return 1;
        }
        const TDF_Label label = document->freeShapes.Value(index + 1);
        opencascade::handle<XCAFDoc_ShapeTool> shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->doc->Main());
        TopoDS_Shape shape = shapeTool->GetShape(label);
        if (shape.IsNull()) {
            set_error("occt_document_body_bbox: body has no shape");
            return 1;
        }
        Bnd_Box box;
        BRepBndLib::Add(shape, box);
        if (box.IsVoid()) {
            set_error("occt_document_body_bbox: body has an empty/degenerate bounding box");
            return 1;
        }
        double xmin, ymin, zmin, xmax, ymax, zmax;
        box.Get(xmin, ymin, zmin, xmax, ymax, zmax);
        out_min[0] = xmin;
        out_min[1] = ymin;
        out_min[2] = zmin;
        out_max[0] = xmax;
        out_max[1] = ymax;
        out_max[2] = zmax;
        return 0;
    } catch (...) {
        set_error("occt_document_body_bbox: unknown native exception");
        return 1;
    }
}

OcctTessellationHandle occt_tessellate_body(
    OcctDocumentHandle handle, int32_t index, double linear_deflection, double angular_deflection_radians) {
    clear_error();
    try {
        auto document = asDocument(handle);
        if (document == nullptr || index < 0 || index >= document->freeShapes.Length()) {
            set_error("occt_tessellate_body: invalid document/index");
            return nullptr;
        }
        const TDF_Label label = document->freeShapes.Value(index + 1);
        opencascade::handle<XCAFDoc_ShapeTool> shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->doc->Main());
        TopoDS_Shape shape = shapeTool->GetShape(label);
        if (shape.IsNull()) {
            set_error("occt_tessellate_body: body has no shape");
            return nullptr;
        }

        // Mirrors backend/app/document/mesh.py's tessellate_shape call
        // exactly: same 5 positional arguments, same meaning
        // (isRelative=false, isInParallel=true).
        BRepMesh_IncrementalMesh mesher(shape, linear_deflection, /*isRelative=*/false, angular_deflection_radians,
                                        /*isInParallel=*/true);
        mesher.Perform();

        auto tessellation = new OcctTessellation();
        TopExp_Explorer explorer(shape, TopAbs_FACE);
        while (explorer.More()) {
            const TopoDS_Face face = TopoDS::Face(explorer.Current());
            appendFaceTriangles(face, tessellation->positions, tessellation->normals);
            explorer.Next();
        }
        return tessellation;
    } catch (const std::exception& e) {
        set_error(std::string("occt_tessellate_body: ") + e.what());
        return nullptr;
    } catch (...) {
        set_error("occt_tessellate_body: unknown native exception");
        return nullptr;
    }
}

int32_t occt_tessellation_triangle_count(OcctTessellationHandle handle) {
    auto tessellation = asTessellation(handle);
    if (tessellation == nullptr) return -1;
    return static_cast<int32_t>(tessellation->positions.size() / 9);
}

int32_t occt_tessellation_copy_positions(OcctTessellationHandle handle, double* out) {
    auto tessellation = asTessellation(handle);
    if (tessellation == nullptr || out == nullptr) return 1;
    std::copy(tessellation->positions.begin(), tessellation->positions.end(), out);
    return 0;
}

int32_t occt_tessellation_copy_normals(OcctTessellationHandle handle, double* out) {
    auto tessellation = asTessellation(handle);
    if (tessellation == nullptr || out == nullptr) return 1;
    std::copy(tessellation->normals.begin(), tessellation->normals.end(), out);
    return 0;
}

void occt_tessellation_destroy(OcctTessellationHandle handle) {
    delete asTessellation(handle);
}

}  // extern "C"
