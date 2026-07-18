# Face Bevel

## Scope

Face Bevel is a single-object topology operation driven by runtime Face Selection. It replaces each accepted selected patch with an inward boundary, a chamfer ring, and an inner cap shifted along the component normal. Width is positive, height is signed, and both are measured in world-space millimeters. Preview is mandatory and Apply records one `ReplaceMeshCommand`.

The initial operation accepts shared-edge connected components only when each is a planar, simple, strictly convex triangulated disk with exactly one oriented boundary loop. Selected open boundaries, holes, multiple loops, non-disk topology, concave boundaries, non-planar regions, non-manifold selected edges, and winding conflicts are rejected before Workspace mutation. Width must be in `0.001...1000` mm. Height must be finite, nonzero, and have an absolute value in `0.001...1000` mm. Defaults are 1 mm width and 0.5 mm height.

## Shared planar-region geometry

`PlanarFaceRegion` contains the pure geometry shared with Face Inset: component analysis, deterministic world-space basis construction, convex constant-width offset, local `Float` round-trip checks, inner triangulation safety, result construction, and final mesh validation. It has no Workspace or UI dependency. Face Inset remains a zero-height planar result; Face Bevel supplies a shifted inner position for every selected vertex and owns all height and chamfer validation.

For each component, the source boundary is projected into a deterministic right-handed 2D basis. Every counter-clockwise edge is shifted inward by the requested width and adjacent shifted lines are intersected. Parallel lines, excessive miter, collapse, reversal, self-intersection, or an offset outside the source polygon are rejected. Interior selected vertices keep their in-plane coordinates.

## World-space width and height

All source positions are transformed from object-local `Float` into world `Double`. Boundary positions receive the constant-width offset and every selected duplicate receives `componentNormal * height`. Positions then pass through the inverse model matrix into local `Float`, are stored in the result mesh, and are transformed back to world space for validation.

The actual round-tripped result must retain the requested perpendicular boundary-edge distance and signed normal displacement within a scale-relative tolerance derived from model dimensions, world-coordinate magnitude, and `Float` precision. This covers translation, rotation, uniform scale, and non-uniform scale without baking `ObjectTransform` into the source mesh. A positive height follows the selected winding normal; a negative height moves in the opposite direction.

The displayed bevel angle is `atan2(abs(height), width)` in degrees. The displayed chamfer slope length is `hypot(width, height)` in millimeters. These are derived values, not separately editable parameters.

## Intersection and triangulation safety

The shifted inner cap reuses the selected triangle connectivity. Its stored, round-tripped positions must preserve positive orientation, non-degenerate triangles, strict containment of interior vertices, and exact polygon coverage within tolerance. Unique inner edges and triangle pairs use the same explicit intersection, overlap, containment, shared-edge fold-over, and area-sum checks as Face Inset. The pairwise safety ceiling is 8,000,000 edge pairs and 8,000,000 triangle pairs per component.

The chamfer is a ruled strip between two simple, strictly convex, consistently ordered boundary loops in parallel planes. Each source boundary edge maps to the corresponding inward parallel edge, and the ring is triangulated in loop order with two consistently wound triangles. The implementation validates the actual offset edge width, signed height, slope, every ring triangle area, and final mesh topology. Under these accepted conditions, non-adjacent strip sections cannot cross without a projected boundary crossing, which the convex offset and pairwise inner-boundary checks reject. Arbitrary collision detection against unselected geometry is not performed.

## Deterministic construction

The result is built outside the Workspace:

1. Retain referenced source vertices in ascending source index order.
2. Append one duplicate for every selected vertex, ordered by component and source vertex ID.
3. Append unselected triangles in source face order.
4. Append two chamfer triangles per boundary edge in oriented loop order.
5. Append shifted inner-cap triangles in original selected face order and winding.

Vertex-only touching components get independent duplicates, even when they share an original source vertex. The completed mesh receives a fresh topology identity, recalculated normals, adjacency, full diagnostics validation, exact local/world bounds, a prepared Picking BVH, and a rebuilt Sculpt spatial index.

## Preview, commit, and stale safety

The preview source key binds topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, selection topology/version/count, sanitized Transform, width, height, and an analysis fingerprint. Changes to mesh, Transform, selection, topology, interaction mode, width, or height stale the preview. Recalculation clears the previous preview before fallible work, so failure cannot leave an older preview applicable.

Apply recalculates the plan and requires estimate and fingerprint equality. Geometry construction, normal and adjacency rebuild, result validation, bounds, before snapshot, and Picking BVH preparation all happen in the fallible prepared phase. Only then does the nonthrowing commit install the mesh, update profiler counts, install Picking and Sculpt indexes, record one replacement command, clear topology-bound selection, clear other topology previews, and invalidate Diagnostics and Cleanup. APIs invoked after mesh installation must remain nonthrowing; a future fallible history store would require preflight or rollback.

The temporary Autosave snapshot permission is enabled only around the synchronous history `record` call and is cleared with `defer`. Preview, Cancel, and failure do not change mesh, Transform, camera, selection, history, project generation, dirty state, Autosave, Recovery, Diagnostics, profiler, renderer upload state, project bytes, or STL output. Apply advances project generation once and schedules Autosave from the fully installed result. Undo and Redo restore the before/after mesh snapshots but do not restore selection or preview.

## Persistence, limits, and known limitations

Width, height, preview, selection, history, and runtime caches are not serialized. The result persists as ordinary vertices and indices in project `formatVersion` 1. Binary STL export continues to bake the current `ObjectTransform` without mutating the bevel mesh.

The operation shares ceilings of 2,000,000 result vertices, 4,000,000 result triangles, 1,000,000 selected faces, and 768 MiB estimated working memory. Analysis and construction are synchronous on MainActor after a yield, so a near-limit mesh can temporarily occupy the UI. There is no fixed performance threshold.

General edge bevel, concave regions, holes, multiple boundary loops, non-planar regions, width profiles, variable height, segment counts greater than one, curvature, collision detection against other geometry, automatic repair, multiple objects, materials, and UV handling are not implemented.
