# Mirror Copy

## Scope and plane definition

Mirror Copy is a destructive single-object topology operation. It copies the current object-local mesh across the selected local `X = 0`, `Y = 0`, or `Z = 0` plane. The mesh remains object-local and the current non-destructive `ObjectTransform` is preserved. Therefore the plane follows object rotation in world space, while translation and scale do not move the local zero plane relative to the mesh.

The operation does not cut geometry. Every off-plane source vertex must be on one side of the selected plane. A mesh crossing the plane, a plane-only mesh, or a component that does not match one of the supported classifications is rejected before mutation.

## Source validation and component classification

The complete source must be a finite indexed triangle mesh without invalid indices, isolated vertices, degenerate or duplicate triangles, non-manifold edges, or winding conflicts. Components are computed by shared undirected edges in expected `O(T + E)` time; vertex-only contact remains separate.

Each component must be one of these forms:

- **Detached closed component:** no boundary edges and no vertex within the seam tolerance. The result keeps the original shell and adds a disconnected reflected shell.
- **Open half component:** every boundary edge has both endpoints on the mirror plane, every seam vertex belongs to that boundary, no seam edge is an interior edge, no triangle lies on the plane, and the boundary graph consists only of closed degree-two loops. The reflected half reuses original seam vertex IDs and closes the surface.

Closed components touching the plane, open boundaries away from the plane, branched or incomplete seam graphs, interior seam vertices or edges, mixed source sides, and crossing triangles are rejected. Multiple valid open and closed components may be processed together. Expected result components are `open + 2 × closed`, and the completed topology is required to have no boundary.

## Seam tolerance and deterministic construction

The seam tolerance is object-local and scale aware. It begins with `max(0.00001, localDiagonal × 0.000001)` millimeters, incorporates bounded Float coordinate precision, and is capped relative to the local diagonal so it cannot become a broad proximity weld. Only vertices classified as seam vertices are snapped, and their selected axis coordinate becomes exactly positive zero. If snapping would place distinct source positions at the same exact Float position, the operation is rejected. No epsilon weld is performed.

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

## Preview, commit, Undo, and Autosave

Preview is mandatory. Its source key binds topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, sanitized Transform, axis, source side, component classification, seam counts and tolerance, and an analysis fingerprint. Sculpt, Transform, topology, axis, load, recovery, or exact-state restoration after an intervening edit makes the preview stale. Camera, brush, symmetry, Gizmo visibility/mode, and Face Selection content do not affect the geometric plan.

Apply recalculates the plan and requires identical estimate and fingerprint. The result mesh, normals, adjacency, bounds, symmetry checks, before snapshot, and Picking BVH are completed in the fallible prepared phase. Only then does a nonthrowing commit install the mesh, update profiler counts, install Picking and Sculpt indexes, clear topology-bound Face Selection and topology previews, invalidate Diagnostics/Cleanup, and record one `ReplaceMeshCommand`.

Autosave snapshot permission is enabled only during the synchronous history record call and is cleared with `defer`. Preview, Cancel, and failure do not change mesh, Transform, camera, selection, history, dirty generation, Autosave, Recovery, profiler, renderer upload state, project bytes, or STL output. Apply, Undo, and Redo each advance project generation once and schedule a complete installed snapshot. Selection and preview are not restored by Undo/Redo.

## Runtime, persistence, and limits

Every successful result has a fresh topology identity. Adjacency, Picking BVH, and Vertex Spatial Index are prepared at the normal Workspace boundary. Renderer vertex and index buffers use the existing topology-revision path: each uploads once for the new mesh and an unchanged frame skips both uploads. There is no mirror-specific renderer branch.

The result persists as ordinary vertices and indices in project `formatVersion` 1. Axis, source classification, tolerance, component plan, preview, history, and runtime caches are not serialized. Binary STL export continues to bake the unchanged ObjectTransform from the mirrored result without mutating it.

Limits are 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, and a conservative 768 MiB estimated working set. Analysis and construction run synchronously on MainActor after the UI yields, so a near-limit mesh can temporarily pause interaction. Fixed performance thresholds are not used.

## Not implemented

Cutting across the mirror plane, arbitrary or moved planes, world-axis mode, interactive plane Gizmo, live mirror modifier, apply-and-delete-source, nearby-vertex weld, negative scale, self-intersection repair, boolean union, multiple objects, materials, and UV handling are outside this version.
