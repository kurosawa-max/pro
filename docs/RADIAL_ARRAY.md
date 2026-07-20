# Radial Array

## Scope and angle conventions

Radial Array is a destructive, single-object topology operation. It duplicates the complete current mesh around object-local X, Y, or Z through the object-local origin and combines the detached copies into one `EditableMesh`. Count includes the unchanged source as copy 0 and is limited to `2...256`.

Full Circle uses `±360° / Count`. Positive follows the right-hand rule around the positive selected axis, negative reverses it, and the endpoint at `±360°` is not generated. Open Arc uses a signed sweep in `±0.01...±359.99°`, includes both endpoints, and uses `sweep / (Count - 1)`. The sweep sign is the Open Arc direction.

The pivot and axis are derived from the current non-destructive Transform:

```text
worldPivot = modelMatrix × localOrigin
worldAxis = normalize(linearPart(modelMatrix) × localAxisUnit)
```

Object translation moves the pivot. Rotation rotates the axis. Uniform and non-uniform scale do not multiply angles or produce a scaled rotation path.

## World-space rigid construction

Each copy is calculated directly from the source in Double world coordinates. Copy `i - 1` is never used to construct copy `i`.

```text
sourceWorld = modelMatrix × sourceLocal
rotatedWorld = worldPivot + rotate(sourceWorld - worldPivot, worldAxis, angle[i])
storedLocalFloat = Float(inverseModelMatrix × rotatedWorld)
actualWorld = modelMatrix × storedLocalFloat
```

Copy 0 retains source positions and indices exactly. The completed stored values are transformed back to world space and checked for radial-distance preservation, axis projection preservation, signed angular placement, source-to-copy chord length, every triangle edge length, and every triangle area. Tolerances account for Float storage, coordinate magnitude, Transform scale, radius, and minimum angular chord. A request whose minimum angular placement cannot survive the Float round trip is rejected before Workspace mutation.

Vertices on the rotation axis are allowed and remain on the axis. A source whose every vertex lies on the chosen axis is rejected as having no radial extent. Exact geometric duplicate triangles introduced by rotational symmetry are rejected. Nearby-only geometry is not welded or treated as an exact duplicate.

## Deterministic topology and validation

Construction is copy-major:

1. copy index ascending;
2. source vertex ID ascending;
3. copy index ascending for triangles;
4. source face ID ascending within each copy.

The mapping is `copyIndex * sourceVertexCount + sourceVertexID`. Copies share no vertex or index identity. Winding is retained because every copy is a proper rigid rotation. Normals and adjacency are rebuilt from completed stored geometry.

The source must be nonempty, finite, and indexed by complete triangles, with valid indices and without degenerate triangles, index- or exact-position duplicate triangles, non-manifold edges, winding conflicts, or isolated vertices. Open boundary meshes, closed meshes, and multiple edge-connected components are supported. For Count `C`, source component count `K`, and boundary edge count `B`, the result requires `K × C` components and `B × C` boundary edges.

The result is checked for finite normalized normals, adjacency, valid UInt32 indices, deterministic ordering, expected topology metrics, local/world bounds from actual stored vertices, collapse, exact geometry duplicates, and world rigid-shape invariants. General shell collision and self-intersection are not detected or repaired.

## Preview, stale identity, and commit

Preview is mandatory and reports the distribution, signed sweep, angular step, source/result counts, components, boundaries, local/world bounds, maximum observed radius/axis/angle/chord errors, validation tolerance, and estimated working memory.

The shared topology Preview request coordinator issues a UUID for every calculation. Parameter changes and sheet dismissal invalidate the current UUID and clear both UI and Workspace Preview. Only the latest request may install a candidate, publish an error, or release its busy state. A late result cannot leave a ghost Preview or become applicable.

The source key's `matchesRuntimeIdentity` check is deliberately lightweight: topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, sanitized Transform, options, and source counts. Apply rebuilds the complete plan and separately requires exact estimate and analysis-fingerprint agreement before any mutation.

All fallible geometry, normal/adjacency work, bounds and topology validation, before snapshot creation, and Picking BVH preparation finish before the nonthrowing commit boundary. Commit installs one fresh mesh, installs the prepared Picking BVH, rebuilds the Vertex Spatial Index, updates profiler counts, clears Face Selection and topology Previews, invalidates Diagnostics/Cleanup, and records one `ReplaceMeshCommand`. Autosave snapshot permission is limited to the synchronous history-record call.

Preview, Cancel, request invalidation, and every validation or runtime-preparation failure leave mesh, Transform, camera, history, dirty generation, Autosave/Recovery, profiler, renderer state, project bytes, and STL output unchanged. Apply, Undo, and Redo each advance project generation once and schedule a complete snapshot.

## Runtime, persistence, limits, and UI

The normal runtime identity/revision path rebuilds adjacency, Picking BVH, Sculpt Spatial Index, and Metal vertex/index buffers once for the new topology. An unchanged following frame skips uploads; there is no Radial Array renderer branch.

Only ordinary result vertices and indices are stored. Axis, distribution, Count, direction, sweep, Preview, copy metadata, history, and runtime caches are not serialized. Project `formatVersion` remains 1. Binary STL export continues to bake the preserved ObjectTransform only at export.

Limits are 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, Count 256, and a conservative 768 MiB working-set estimate. The operation runs synchronously on MainActor after a UI yield, so near-limit analysis can temporarily pause interaction.

The toolbar opens a modal sheet with Local Axis, Full Circle/Open Arc, Count, Full Circle Direction or signed Open Arc Sweep, Preview metrics, Recalculate, Apply, Cancel, progress, validation errors, VoiceOver labels, and compact-width scrolling. Parameter controls are disabled during calculation and Apply, while request identity remains the authoritative race-safety boundary.

## Known limitations

Grid, spiral, helix, arbitrary/world axes, custom pivots, selected-face array, per-copy scale/translation, live modifiers, multiple objects, weld/Boolean union, general collision/self-intersection detection, and automatic repair are not implemented. Exact rotational symmetry is rejected rather than silently producing duplicate geometry.
