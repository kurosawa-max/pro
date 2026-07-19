# Linear Array

## Scope and terminology

Linear Array is a destructive, single-object topology operation. It duplicates the complete current mesh along object-local X, Y, or Z and combines the source and copies into one `EditableMesh`. It is not a live modifier. Every copy is detached: vertices and indices are not shared between copies, and no proximity weld or Boolean union is performed.

Count is the final number of copies including the unchanged source as copy 0. Valid Count is `2...256`. For Count 4 and Spacing 10 mm, copy positions are 0, 10, 20, and 30 mm. Negative Spacing reverses the direction. Valid signed Spacing is `-1000...-0.001 mm` or `0.001...1000 mm`.

## Local axis and world-space spacing

The chosen axis is object-local and therefore follows the current object rotation. Spacing is nevertheless a world-space millimeter distance. Translation does not affect direction, and object scale does not multiply the requested distance.

```text
worldDirection = normalize(linearPart(ObjectTransform) * localAxisUnit)
worldDisplacement(i) = worldDirection * spacingMillimeters * i
copyWorldPosition(i) = sourceWorldPosition + worldDisplacement(i)
```

Each copy is calculated directly from the source; copy `i - 1` is never used to produce copy `i`. Position calculation uses Double world coordinates, applies the inverse ObjectTransform, stores local Float coordinates, then transforms those stored values back to world space. Every corresponding vertex across every adjacent copy pair must retain the signed projection, absolute distance, and parallel direction within a coordinate-, scale-, and spacing-relative tolerance capped at one percent of requested Spacing. A request that cannot survive this Float round trip is rejected before Workspace mutation.

The existing positive scale constraint (`0.001...1000`) remains in force. Translation, rotation, uniform scale, and non-uniform scale are supported. ObjectTransform is preserved and is not baked into the editable mesh.

## Source and deterministic construction

The source must be a nonempty finite indexed triangle mesh without invalid indices, degenerate triangles, index- or geometry-duplicate triangles, non-manifold edges, winding conflicts, or isolated vertices. Open boundaries and closed manifold meshes are supported. Source defects are rejected rather than repaired.

Construction order is deterministic and copy-major:

1. copy index ascending;
2. source vertex ID ascending within each copy;
3. copy index ascending for triangles;
4. source face ID ascending within each copy.

The vertex mapping is `copyIndex * sourceVertexCount + sourceVertexID`. Copy 0 retains source positions exactly and the result begins with the original index array. Winding is unchanged because placement is translation only. Normals are rebuilt from completed geometry and adjacency is rebuilt once.

For Count `C`, source component count `K`, and source boundary edge count `B`, expected result metrics are:

```text
vertices = sourceVertices * C
triangles = sourceTriangles * C
components = K * C
boundaryEdges = B * C
totalSpan = spacingMillimeters * (C - 1)
```

All count, index, byte, and span calculations are checked before allocation. The completed result is checked for finite normalized normals, exact mapping/order, actual stored spacing, local/world bounds, adjacency, components, boundary edges, non-manifold edges, winding conflicts, degenerate triangles, duplicate triangles, isolated vertices, and UInt32-safe indices. Exact geometry duplicates introduced between copies are rejected.

## Preview and stale safety

Preview is mandatory and uses the same stored-Float placement path as Apply. It reports axis, Count, signed Spacing, signed and absolute total span, source/result vertex and triangle counts, component and boundary counts, local/world bounds, spacing validation tolerance, and estimated working memory.

The Preview source key binds topology ID/revision, vertex revision, non-rewinding mesh and Transform versions, sanitized ObjectTransform, options, source/result counts, component and boundary metrics, total span, and analysis fingerprint. Sculpt, Sculpt Undo/Redo, Transform changes and Undo/Redo, all topology replacements, load, recovery, axis, Count, Spacing, and exact-state restoration after an edit make it stale. Camera, brush, symmetry, Face Selection content/operation, and Diagnostics visibility do not.

Recalculation clears the previous model Preview before validation. A failed recalculation therefore cannot leave an older Preview applicable.

## Prepared commit, failure atomicity, and Undo

Before Preview begins, active Sculpt and Gizmo operations are cancelled, the Transform panel transaction is committed, connected selection processing is cancelled, other topology Previews are discarded, and hover is cleared. The sheet suppresses Metal input and competing commands.

Apply first recalculates the complete plan and requires Preview estimate and fingerprint equality. Result allocation, position/index generation, normal and adjacency rebuild, topology and bounds validation, before snapshot, and Picking BVH creation all occur in the fallible prepared phase. Workspace installation begins only after all of them succeed. The following commit phase is nonthrowing; APIs added to it must preserve that constraint.

The result is installed once, profiler counts are updated, the prepared Picking BVH is installed, Vertex Spatial Index is rebuilt, Face Selection and all topology Previews are cleared, and Diagnostics/Cleanup are invalidated. One `ReplaceMeshCommand` records the before and after mesh/Transform/camera snapshots. Autosave snapshot permission is enabled only for that synchronous history-record call and is cleared with `defer`.

Apply, Undo, and Redo each advance the project generation once and schedule one complete Autosave snapshot. Preview, parameter changes, Cancel, and any validation, memory, precision, or BVH preparation failure do not modify mesh, Transform, camera, selection, history, dirty state, Recovery, profiler, Renderer state, project bytes, or STL output. Undo/Redo restore mesh, Transform, and camera but do not restore selection or Preview. If a later Undo/Redo BVH rebuild fails, the cache is invalidated and the next pick retries safely.

## Runtime, persistence, and performance

A successful Array creates a fresh runtime topology. Existing Renderer revision handling uploads the new vertex and index buffers once and skips an unchanged next frame; there is no Array-specific Renderer path. Diagnostics and selection overlays are cleared, while Gizmo rendering continues with the preserved Transform.

Only ordinary result vertices and indices are saved. Axis, Count, Spacing, total span, Preview, copy metadata, history, and runtime caches are not serialized. Project `formatVersion` remains 1. Binary STL export continues to bake ObjectTransform at the export boundary without changing the Array result mesh.

Limits are 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, Count 256, and a conservative 768 MiB working-set estimate that covers source/result data, validation structures, runtime preparation, history snapshots, and renderer staging. Analysis and construction are synchronous on MainActor after the UI yields, so near-limit work can temporarily pause interaction.

## Known limitations

General copy-to-copy collision and self-intersection are not detected. Spacing smaller than object dimensions can produce intersecting detached shells. Linear Array does not repair topology, weld nearby vertices, merge overlapping copies, perform Boolean union, array selected faces, add per-copy rotation/scale, use world or arbitrary axes, generate radial/grid arrays, show a 3D ghost Preview, support multiple objects, or provide a non-destructive modifier. Run Mesh Diagnostics and inspect print geometry before production output.
