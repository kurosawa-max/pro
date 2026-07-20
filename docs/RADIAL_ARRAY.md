# Radial Array

## Scope and angle conventions

Radial Array is a destructive, single-object topology operation. It duplicates the complete current mesh around object-local X, Y, or Z through the object-local origin and combines the detached copies into one `EditableMesh`. Count includes the unchanged source as copy 0 and is limited to `2...256`.

Full Circle uses `±360° / Count`. Positive follows the right-hand rule around the positive selected axis, negative reverses it, and the endpoint at `±360°` is not generated. Open Arc uses a signed sweep in `±0.01...±359.99°`, includes both endpoints, and uses `sweep / (Count - 1)`. The sweep sign is the Open Arc direction.

The pivot and axis are derived through the same Float helpers used by rendering:

```text
worldPivotFloat = ObjectTransform.worldPosition(localOrigin)
worldAxisFloat = ObjectTransform.worldDirection(localAxisUnit)
```

Object translation moves the pivot. Rotation rotates the axis. Uniform and non-uniform scale do not multiply angles or produce a scaled rotation path.

Inactive controls are canonicalized before Preview identity or geometry is calculated. Full Circle fixes the hidden Sweep to one canonical value. Open Arc fixes the hidden Direction to one canonical value. Switching distribution remains a visible identity change, while changing an inactive control cannot change the result or fingerprint.

## Ideal Double and actual render-space Float paths

The currently displayed source is authoritative. Source local Float vertices, the local origin, and the selected local axis first pass through `ObjectTransform.worldPosition` or `worldDirection`. Those Float results are converted to Double for ideal Rodrigues rotation. Float Renderer precision that has already been lost is never reconstructed by multiplying a Double-converted matrix.

```text
sourceWorldFloat = ObjectTransform.worldPosition(sourceLocalFloat)
idealWorldDouble = rotate(Double(sourceWorldFloat), Double(worldAxisFloat), angle[i])
storedLocalFloat = Float(doubleInverseModelMatrix × idealWorldDouble)
actualWorldFloat = ObjectTransform.worldPosition(storedLocalFloat)
```

Copy 0 retains source positions and indices exactly. Only `actualWorldFloat` is used as the observed result. It is compared with the ideal Double position for radial distance, axis projection, signed angle, source chord, adjacent-copy chord, every edge length, triangle area, and winding. Render-space non-finite positions, zero chords, collapsed radii/edges/areas, and exact-position duplicate triangles are rejected before Workspace mutation.

Axis classification has a separate per-vertex tolerance derived from that displayed vertex, pivot, axis projection, and Float ULP. It never uses the operation validation tolerance or the largest radius. A vertex beyond this strict threshold is always off-axis and must pass radius, axial, angle, position, and chord validation even when its radius is tiny. Preview records the axis/off-axis counts, minimum positive and maximum displayed radii, and minimum feature chord. Every off-axis vertex must be able to represent its adjacent angular chord; a large outer radius cannot hide an unrepresentable inner feature.

A source whose displayed Float geometry has collapsed edges or triangle area is rejected. Exact local collinearity is checked after inverse conversion, but local area is not required to match the source under non-uniform scale; product validity is decided from actual render-space world edges, area, and winding. Exact geometric duplicate triangles introduced by rotational symmetry are rejected. Nearby-only geometry is not welded or treated as an exact duplicate.

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

Preview is mandatory and reports the distribution, signed sweep, angular step, local-origin/world pivot, world axis, axis/off-axis counts, displayed source radial range, minimum feature chord, separate position/radius/axis/angular tolerances, source/result counts, components, boundaries, local/world bounds, maximum measured radius/axis/angle/chord errors, and estimated working memory.

The shared topology Preview request coordinator issues a UUID for every calculation. Parameter changes and sheet dismissal invalidate the current UUID and clear both UI and Workspace Preview. Only the latest request may install a candidate, publish an error, or release its busy state. A late result cannot leave a ghost Preview or become applicable.

The source key's `matchesRuntimeIdentity` check is deliberately lightweight: topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, sanitized Transform, canonical options, and source counts. Apply rebuilds the complete plan and separately requires exact estimate and analysis-fingerprint agreement before any mutation. The fingerprint includes the actual displayed source positions, pivot, axis, radius analysis, tolerances, and final stored positions; none of this work occurs during SwiftUI rendering.

All fallible geometry, normal/adjacency work, bounds and topology validation, before snapshot creation, and Picking BVH preparation finish before the nonthrowing commit boundary. Commit installs one fresh mesh, installs the prepared Picking BVH, rebuilds the Vertex Spatial Index, updates profiler counts, clears Face Selection and topology Previews, invalidates Diagnostics/Cleanup, and records one `ReplaceMeshCommand`. Autosave snapshot permission is limited to the synchronous history-record call.

Preview, Cancel, request invalidation, and every validation or runtime-preparation failure leave mesh, Transform, camera, history, dirty generation, Autosave/Recovery, profiler, renderer state, project bytes, and STL output unchanged. Apply, Undo, and Redo each advance project generation once and schedule a complete snapshot.

## Runtime, persistence, limits, and UI

The normal runtime identity/revision path rebuilds adjacency, Picking BVH, Sculpt Spatial Index, and Metal vertex/index buffers once for the new topology. An unchanged following frame skips uploads; there is no Radial Array renderer branch.

Only ordinary result vertices and indices are stored. Axis, distribution, Count, direction, sweep, Preview, copy metadata, history, and runtime caches are not serialized. Project `formatVersion` remains 1. Binary STL export continues to bake the preserved ObjectTransform only at export.

Limits are 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, Count 256, and a conservative 768 MiB working-set estimate. The operation runs synchronously on MainActor after a UI yield, so near-limit analysis can temporarily pause interaction.

The toolbar opens a modal sheet with Local Axis, Full Circle/Open Arc, Count, Full Circle Direction or signed Open Arc Sweep, Preview metrics, Recalculate, Apply, Cancel, progress, validation errors, VoiceOver labels, and compact-width scrolling. Parameter controls are disabled during calculation and Apply, while request identity remains the authoritative race-safety boundary.

## Known limitations

Grid, spiral, helix, arbitrary/world axes, custom pivots, selected-face array, per-copy scale/translation, live modifiers, multiple objects, weld/Boolean union, general collision/self-intersection detection, and automatic repair are not implemented. Exact rotational symmetry is rejected rather than silently producing duplicate geometry.
