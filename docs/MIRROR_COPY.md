# Mirror Copy

## Scope and plane definition

Mirror Copy is a destructive single-object topology operation. It copies the current object-local mesh across the selected local `X = 0`, `Y = 0`, or `Z = 0` plane. The mesh remains object-local and the current non-destructive `ObjectTransform` is preserved. Therefore the plane follows object rotation in world space, while translation and scale do not move the local zero plane relative to the mesh.

The operation does not cut geometry. Every off-plane source vertex must be on one side of the selected plane. A mesh crossing the plane, a plane-only mesh, or a component that does not match one of the supported classifications is rejected before mutation.

## Source validation and component classification

The complete source must be a finite indexed triangle mesh without invalid indices, isolated vertices, degenerate or duplicate triangles, non-manifold edges, or winding conflicts. Components are computed by shared undirected edges. After Union-Find resolves every face root, faces are grouped in face-ID order and the global first-seen edge list is visited once to build root-specific edge and boundary arrays. Classification then visits only each component's own arrays. Total expected work is `O(T + E)`, rather than a full edge scan per component. Components are ordered by minimum face ID; faces remain ascending and component edges retain global first-seen order.

Vertex-only contact does not connect face components. Two edge-connected components that reuse the same vertex ID form bow-tie topology and are rejected: a shared seam vertex is an invalid seam loop, while an off-plane shared vertex is an invalid source mesh. Separate components with separate vertex IDs may occupy the same position only when they do not violate exact-position collision or duplicate-triangle validation.

Each component must be one of these forms:

- **Detached closed component:** no boundary edges and no vertex within the seam tolerance. The result keeps the original shell and adds a disconnected reflected shell.
- **Open half component:** every boundary edge has both endpoints on the mirror plane, every seam vertex belongs to that boundary, no seam edge is an interior edge, no triangle lies on the plane, and the boundary graph consists only of closed degree-two loops. The reflected half reuses original seam vertex IDs and closes the surface.

Closed components touching the plane, open boundaries away from the plane, branched or incomplete seam graphs, interior seam vertices or edges, mixed source sides, and crossing triangles are rejected. Multiple valid open and closed components may be processed together. Expected result components are `open + 2 × closed`, and the completed topology is required to have no boundary.

## Seam tolerance and deterministic construction

The seam tolerance is object-local and scale aware. It uses a `0.00001 mm` minimum and a diagonal-relative `localDiagonal × 0.000001` candidate, then caps both diagonal and Float-precision growth by `max(0.00001, selectedAxisExtent × 0.0001)`. Computing extents in Double avoids overflow. The selected-axis cap prevents a very large extent on another axis, or a large local-origin offset, from pulling an unrelated region onto the plane. The same calculation is used by Preview and Apply. Only vertices classified within that tolerance are snapped, and their selected axis coordinate becomes exactly positive zero. Vertices outside the tolerance are not welded, and no other proximity weld is performed. A model smaller than the required minimum tolerance can be rejected as having no off-plane source rather than being mutated.

Preview reports the total source boundary-edge count and the maximum seam snap distance, defined as `max(abs(originalAxisCoordinate))` across seam vertices. The maximum is finite, lies in `0...seamTolerance`, and is zero when every seam coordinate is already exact zero. Both values participate in the preview source identity and analysis fingerprint.

Before reflected vertices or triangles are created, the snapped source is validated again. A triangle newly collapsed by snapping and a geometry-duplicate triangle newly created by snapping have dedicated errors. Exact-position collisions not already classified as collapse or duplicate are reported separately. These errors recommend adjusting the selected axis or source geometry; pre-existing degenerate or duplicate input continues to direct the user to Diagnostics/Cleanup.

Construction is deterministic:

1. Retain all original vertices in source index order, with accepted seam coordinates snapped to zero.
2. Append one reflected vertex for each off-plane source vertex in source index order.
3. Reuse the original vertex ID for every seam mapping.
4. Keep all source triangles first and unchanged in source face order.
5. Append reflected triangles in source face order as `(mirror(a), mirror(c), mirror(b))`.

The winding reversal compensates for reflection. Normals are then rebuilt from completed geometry using the existing area-weighted policy; source normals are not trusted as final output.

## Result validation

Before Workspace installation, Mirror Copy validates result counts, UInt32 indices, finite and normalized normals, exact local bounds, finite world bounds under the current Transform, fresh adjacency, closed manifold edges, consistent winding, absence of degenerate and duplicate triangles, expected component count, exact source and reflected triangle order, seam reuse, reflected vertex correspondence, and axis-symmetric local bounds.

Self-intersection and collision detection are not performed. Detached reflected shells can intersect the original or other components even when topology is valid. This is reported as a known limitation rather than silently repaired.

## Error precedence

Validation uses a stable precedence so fixtures and user guidance identify the earliest actionable cause:

1. Empty/invalid structure, non-finite values, pre-existing degenerate triangles, pre-existing index- or geometry-duplicate triangles, non-manifold edges, winding conflicts, and isolated vertices.
2. No off-plane vertices, a triangle crossing the plane, or disconnected positive/negative source sides.
3. Snap-induced collapse, snap-induced geometry duplicate, then remaining exact-position snap collision.
4. Component topology: seam triangle, bow-tie/invalid loop, closed-plane contact, off-plane open boundary, seam interior vertex, seam interior edge, and incomplete/branched loop.
5. Count, index, working-memory, result topology, component-count, symmetry, bounds, stale-preview, and prepared-runtime failures.

No Workspace mutation occurs at any validation stage.

## Preview, commit, Undo, and Autosave

Preview is mandatory. Its source key binds topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, sanitized Transform, axis, source side, component classification, seam loop/vertex/boundary counts, tolerance, maximum snap distance, and an analysis fingerprint. Sculpt, Transform, topology, axis, load, recovery, or exact-state restoration after an intervening edit makes the preview stale. Camera, brush, symmetry, Gizmo visibility/mode, Face Selection content/operation, and Diagnostics visibility do not affect the geometric plan.

Apply recalculates the plan and requires identical estimate and fingerprint. The result mesh, normals, adjacency, bounds, symmetry checks, before snapshot, and Picking BVH are completed in the fallible prepared phase. Only then does a nonthrowing commit install the mesh, update profiler counts, install Picking and Sculpt indexes, clear topology-bound Face Selection and topology previews, invalidate Diagnostics/Cleanup, and record one `ReplaceMeshCommand`.

Autosave snapshot permission is enabled only during the synchronous history record call and is cleared with `defer`. Preview, Cancel, and failure do not change mesh, Transform, camera, selection, history, dirty generation, Autosave, Recovery, profiler, renderer upload state, project bytes, or STL output. Apply, Undo, and Redo each advance project generation once and schedule a complete installed snapshot. Selection and preview are not restored by Undo/Redo.

## Runtime, persistence, and limits

Every successful result has a fresh topology identity. Adjacency, Picking BVH, and Vertex Spatial Index are prepared at the normal Workspace boundary. Renderer vertex and index buffers use the existing topology-revision path: each uploads once for the new mesh and an unchanged frame skips both uploads. There is no mirror-specific renderer branch.

The result persists as ordinary vertices and indices in project `formatVersion` 1. Axis, source classification, tolerance, component plan, preview, history, and runtime caches are not serialized. Binary STL export continues to bake the unchanged ObjectTransform from the mirrored result without mutating it.

Limits are 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, and a conservative 768 MiB estimated working set. Analysis and construction run synchronously on MainActor after the UI yields, so a near-limit mesh can temporarily pause interaction. Fixed performance thresholds are not used.

## Not implemented

Cutting across the mirror plane, arbitrary or moved planes, world-axis mode, interactive plane Gizmo, live mirror modifier, apply-and-delete-source, nearby-vertex weld, negative scale, self-intersection repair, boolean union, multiple objects, materials, and UV handling are outside this version.
