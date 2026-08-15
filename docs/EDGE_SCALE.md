# Selected Edge Scale

## Scope and geometry

Edge Select with a nonempty runtime selection routes the existing Scale Gizmo to a vertex-only edit of the selected edges' unique endpoints. World X, Y, Z, and Uniform handles are supported. The endpoints are captured once, deduplicated, sorted by vertex ID, and bound to the edge-table fingerprint and selection version. `selectedEdgeCount` and `affectedVertexCount` remain distinct.

The pivot is the start-local AABB center of the affected endpoints, computed as `minimum * 0.5 + maximum * 0.5`. Every pointer update is reconstructed from the immutable transaction start state and the current absolute factor. The previous preview mesh is never used as the next scale source.

Pivot-relative local offsets pass through the model matrix with `w = 0`, receive the requested world-axis scale, and pass through the inverse model matrix with `w = 0`. This preserves world-axis semantics with rotation and non-uniform ObjectTransform scale and avoids dependence on very large object translation. Round-trip validation follows the Selected Vertex Scale tolerance policy.

## Factor, transaction, and memory

Pointer-derived finite factors are clamped to `0.001...1000`. GeometryCore rejects zero, negative, non-finite, and out-of-range direct inputs. Factor `1` is a semantic no-op.

The transaction captures topology identity, edge-table fingerprint, source vertex revision and counts, selection version, selected edge IDs, sorted unique endpoint IDs, start-local positions, local/world pivot, sanitized Transform, handle, workspace session, and project generation. Pointer updates do not rescan selection or rebuild endpoints.

Working memory is limited to 768 MiB. A conservative preflight uses `min(vertexCount, selectedEdgeCount * 2)` before endpoint allocation; an exact preflight follows endpoint deduplication and precedes position capture.

## Preview, history, rendering, and persistence

Prepared begin projects active Sculpt cancellation, Transform Panel commit, and ordinary Object Scale cancellation without mutating Workspace state before the late-begin boundary. Preview owns a separate mesh and Picking BVH. Commit prepares the final Picking BVH before installing the vertex-only result and records one semantic `edgeScale` command in the shared Workspace history.

Undo and Redo restore exact endpoint positions while preserving indices, topology identity, ObjectTransform, Edge Selection content/version, and edge-table fingerprint. Meaningful commits update the normal mesh vertex buffer only; mesh index and selected/hover edge-pair buffers remain reusable. Factor `1` causes no upload.

Preview is excluded from ProjectData, Autosave, Recovery, and project format version 1. Active preview blocks STL export under the normal active-edit contract. Cancel, failure, and no-op do not schedule persistence.

## Known limitations

Local-axis scale, custom pivots, snapping, numeric entry, proportional editing, negative/mirror scaling, multiple objects, collision correction, Face Scale, Edge Slide, and topology editing are not included.
