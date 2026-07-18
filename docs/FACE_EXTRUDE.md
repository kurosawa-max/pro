# Face Extrude

## Purpose and supported region

Face Extrude is the first topology-editing operation built on runtime Face Selection. It replaces each selected edge-connected triangle patch with a translated top patch and boundary side walls. A signed distance is entered in millimeters and a validated preview is required before Apply.

The initial implementation accepts manifold patches whose every selected incident undirected edge has exactly two global incident faces with opposite winding. A selected edge used by one selected face is a boundary edge; an edge used by two selected faces is an interior edge. Open mesh boundaries, non-manifold selected edges, inconsistent winding, degenerate or duplicate triangles, non-finite geometry, and selected components without a boundary are rejected. This includes selecting an entire closed shell. Existing boundary or topology issues in a distant, unaffected component are allowed only when result validation proves their counts did not change.

## Components, direction, and units

Selected faces are partitioned by shared undirected edges. Vertex-only contact does not join components. Components are discovered by ascending face ID, and face IDs within each component are sorted.

Each selected triangle is transformed from object-local coordinates to world space. Its Double-precision cross product contributes to the component area vector. After scale-relative finite validation, the normalized area vector is multiplied by the signed distance. Each source position is transformed to world space, displaced, and transformed back through the inverse model matrix. Therefore the visible displacement is measured in world millimeters under translation, rotation, uniform scale, and non-uniform scale. Positive distance follows winding; negative distance moves opposite winding and can self-intersect.

## Deterministic mesh construction

The result is built as a separate value before Workspace mutation:

1. Copy still-referenced original vertices in original index order.
2. Append duplicated vertices by component ID, then original vertex ID.
3. Keep unselected original triangles in original face order.
4. Append translated top triangles in original selected face order while preserving winding.
5. Append two side triangles per boundary edge, ordered by component, selected face ID, and edge slot.

The same original vertex is duplicated once per component. If two selected components touch only at a vertex, each gets an independent duplicate. Original selected interior vertices that are no longer referenced are removed; boundary vertices remain for unselected faces and side walls. Optional original and `(componentID, originalVertexID)` remaps reject missing or overflowing indices.

## Preview and stale safety

Preview performs full selection, component, boundary, normal, result-count, compaction, bounds, and working-memory analysis without changing the Workspace. The displayed result bounds are world-space millimeter bounds.

The source key contains mesh topology ID and topology revision, vertex revision, a non-rewinding runtime mesh version, selection topology binding and UUID/value version, sanitized ObjectTransform, a non-rewinding Transform version, selected count, distance, and an analysis fingerprint. Runtime versions use a UUID identity plus UInt64 value. At integer exhaustion they rotate identity and restart at zero rather than colliding with an earlier version. Camera changes do not stale a preview because they do not affect geometry.

Sculpt, Transform, selection, topology, project load, Recovery, or distance changes require a new preview. Restoring the same visible value through Undo does not reactivate an older preview.

## Validation, atomic install, and runtime rebuild

Apply completely recalculates the plan and requires estimate and fingerprint equality with the preview. It creates a new `EditableMesh`, rebuilds all normals and adjacency, validates finite positions and normalized normals, checks indices and counts, rejects degenerate or duplicate result triangles, and requires boundary, non-manifold, and winding-conflict counts outside the edited patch to remain unchanged. A Picking BVH is built before Workspace installation.

Only after every fallible build step succeeds does `WorkspaceModel` install the mesh once, prepare the Vertex Spatial Index, install the Picking BVH, update profiler mesh counts, clear the topology-bound Face Selection, and invalidate Diagnostics data. Renderer vertex and index buffers then use the normal topology-revision path; no renderer-specific extrusion path exists.

Failure changes only the displayed error and status. Mesh, Transform, camera, selection, history, dirty generation, Autosave, Recovery, Diagnostics, profiler, renderer upload state, project bytes, and STL output remain unchanged.

## Undo, dirty state, and persistence

Successful Apply records one `ReplaceMeshCommand` containing before/after mesh, ObjectTransform, and camera snapshots. Undo restores the original mesh, Redo restores the extrusion result, and each topology installation creates an empty selection for the current runtime topology. Selection and preview are not restored. Runtime adjacency, Picking BVH, and Vertex Spatial Index are prepared for each installed snapshot.

Preview and Cancel do not change history, project mutation generation, dirty state, Autosave, or Recovery. Apply advances the project generation once and schedules Autosave from the fully installed snapshot. The result persists as ordinary vertices and indices in project formatVersion 1. Distance, preview, component data, selection, history, and runtime caches are not serialized. Binary STL export continues to bake ObjectTransform from the resulting mesh.

## Limits and performance

Face Extrude reuses the current Cleanup ceilings of 2,000,000 result vertices, 4,000,000 result triangles, and 768 MiB estimated working memory. Selected-component analysis uses the 1,000,000-face connected-processing ceiling. All index, triangle, byte, dictionary, remap, result-array, BVH, and history-snapshot estimates use checked integer arithmetic. A conservative baseline memory check runs before allocating the global edge table, followed by an exact estimate after boundary and duplicate counts are known.

Analysis and mesh construction are synchronous on MainActor after a yield that gives the loading state an opportunity to appear. This prioritizes atomic state transitions, but a near-limit mesh can temporarily occupy the UI. There is no fixed performance threshold.

## Known limitations

Self-intersection and collision detection are not implemented. Open-boundary extrusion, whole-shell extrusion, individual-face direction mode, inset, bevel, taper, twist, snapping, interactive extrusion gizmos, multiple objects, material/UV handling, and automatic repair are outside this version.
