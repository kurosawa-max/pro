# Face Inset

## Scope

Face Inset is a single-object topology operation driven by runtime Face Selection. It creates a constant-width inner boundary and a ring of triangles while preserving the selected patch as an inner surface. The distance is positive and measured in world-space millimeters. Preview is mandatory; Apply records one `ReplaceMeshCommand`.

This first version accepts each shared-edge connected selected component only when it is a planar, simple, strictly convex disk with exactly one oriented boundary loop. Every selected incident edge must have exactly two global uses with opposite winding, so a selection touching an open mesh boundary is rejected. Concave regions, holes, multiple loops, handles, non-planar patches, negative distance, outset, bevel, and self-intersection repair are rejected rather than approximated.

## Region and boundary validation

Selected components use shared undirected edges; vertex-only contact remains separate. Selected interior edges must have two oppositely oriented selected uses. Boundary edges have one selected use and are followed in source winding order. Every boundary vertex must have one incoming and one outgoing edge, the traversal must consume every boundary edge exactly once, and `V - E + F` must equal one. Global non-manifold selected edges and winding conflicts are rejected.

The operation validates the entire source mesh for structure, finite values, degenerate triangles, and duplicate triangles. Boundary, non-manifold, and winding-conflict counts outside the edit must be identical after construction.

## World-space geometry

Positions are transformed from object-local to world space before analysis. The component area vector determines a stable normal. A deterministic 2D basis chooses the world X, Y, or Z axis least parallel to the normal, with X/Y/Z as the tie order, then constructs a right-handed basis with cross products.

Planarity tolerance is `max(0.0001 mm, componentDiagonal × 1e-5)`. The projected boundary must have positive area, no repeated or short edges, no non-adjacent segment intersection, and a positive scale-relative turn at every corner.

Each CCW boundary edge is shifted left by the requested distance. Adjacent shifted lines are intersected to form the inset vertex. Parallel lines, non-finite intersections, a miter ratio above 100, collapse, reversal, self-intersection, or a result outside the source polygon are rejected. Interior selected vertices keep their world position and must remain strictly inside the inset polygon. Boundary results are transformed through the inverse model matrix; the source mesh and ObjectTransform are never baked or mutated.

## Deterministic construction

The result is built independently of the Workspace:

1. Retain referenced source vertices in ascending source index order.
2. Append one duplicate for every selected vertex, ordered by component and source vertex ID.
3. Append unselected triangles in source face order.
4. Append two ring triangles per boundary edge in oriented loop order.
5. Append inner triangles in original selected face order and winding.

Boundary duplicates use offset positions; interior duplicates retain their positions. Unreferenced selected interior source vertices are compacted away. The result receives a fresh runtime topology identity, recalculated normals, adjacency, full validation, and a prebuilt Picking BVH before installation.

## Preview, atomicity, and history

The preview source key binds topology ID/revision, vertex revision, non-rewinding mesh and Transform runtime versions, selection topology/version/count, sanitized Transform, options, and an analysis fingerprint. Any relevant change makes the preview stale, including restoring the same visible value after an intervening change.

Apply recalculates the plan and requires identical estimate and fingerprint. All fallible geometry, validation, and BVH work occurs before the nonthrowing commit. Failure changes only status/error presentation. Successful commit installs the mesh, prepares Picking and Sculpt spatial indexes, updates profiler counts, clears topology-bound selection, invalidates Diagnostics/Cleanup state, and records one replacement command. Undo and Redo restore mesh/Transform/camera snapshots but never restore selection or preview.

Preview, Cancel, and failure do not change project generation, dirty state, Autosave, Recovery, history, runtime mesh revisions, project bytes, or renderer upload state. Apply advances project generation once and uses the normal topology upload path. Inset options, preview, selection, and runtime caches are not serialized; project `formatVersion` remains 1.

## Limits and known limitations

The operation shares limits of 2,000,000 result vertices, 4,000,000 result triangles, 1,000,000 selected faces, and 768 MiB estimated working memory. Analysis and construction are initially synchronous on MainActor after one yield, so a near-limit mesh can temporarily occupy the UI. There is no fixed performance threshold.

General concave offsetting, holes, multiple boundary loops, negative inset/outset, bevel, local face Transform, material/UV handling, multiple objects, collision detection, and automatic repair are not implemented.
