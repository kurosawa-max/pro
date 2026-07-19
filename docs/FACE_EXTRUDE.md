# Face Extrude

## Purpose and supported region

Face Extrude is the first topology-editing operation built on runtime Face Selection. It replaces each selected edge-connected triangle patch with a translated top patch and boundary side walls. A signed distance is entered in millimeters and a validated preview is required before Apply.

The initial implementation accepts manifold patches whose every selected incident undirected edge has exactly two global incident faces with opposite winding. A selected edge used by one selected face is a boundary edge; an edge used by two selected faces is an interior edge. Open mesh boundaries, non-manifold selected edges, inconsistent winding, and selected components without a boundary are rejected. This includes selecting an entire closed shell.

Before region analysis, Face Extrude conservatively validates the entire mesh. Any invalid index, non-finite vertex or normal, degenerate triangle, or duplicate triangle blocks the operation even when the issue is outside the selection. Mesh Diagnostics and the limited Mesh Cleanup should be used before retrying. Distant boundary, non-manifold, or winding-conflict edges are allowed only when they do not touch the selected region and post-validation proves that their category counts did not change. A future implementation may narrow the degenerate and duplicate validation scope after a safe local-validation model is established.

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

Sculpt, Transform, selection, topology, interaction mode, project load, Recovery, or distance changes require a new preview. Restoring the same visible value through Undo does not reactivate an older preview. Recalculation invalidates the previous model-level preview before analysis starts, so a failed recalculation cannot leave an older preview applicable.

## Validation, atomic install, and runtime rebuild

Apply completely recalculates the plan and requires estimate and fingerprint equality with the preview. It creates a new `EditableMesh`, rebuilds all normals and adjacency, validates finite positions and normalized normals, checks indices and counts, rejects degenerate or duplicate result triangles, and requires boundary, non-manifold, and winding-conflict counts outside the edited patch to remain unchanged. A Picking BVH is built before Workspace installation.

Apply is split into a fallible prepared phase and a nonthrowing commit phase. The prepared phase recalculates the result and fingerprint, captures the before snapshot, validates the completed mesh, and builds the Picking BVH. Only after every fallible step succeeds does the commit phase install the mesh once, prepare the Vertex Spatial Index, install the Picking BVH, update profiler mesh counts, clear the topology-bound Face Selection, and invalidate Diagnostics/Cleanup data. `WorkspaceHistory.record` is nonthrowing; if history storage becomes fallible in the future, it must be preflighted or the commit must gain rollback before any mesh install. Renderer vertex and index buffers use the normal topology-revision path; no renderer-specific extrusion path exists.

The local result bounds comparison is intentionally bit-exact. Plan bounds and `EditableMesh.bounds` consume the same already-rounded finite `SIMD3<Float>` values, and AABB reduction only selects component minima and maxima without further arithmetic. World preview bounds remain a separate transformed calculation.

Failure changes only the displayed error and status. Mesh, Transform, camera, selection, history, dirty generation, Autosave, Recovery, Diagnostics, profiler, renderer upload state, project bytes, and STL output remain unchanged.

## Undo, dirty state, and persistence

Successful Apply records one `ReplaceMeshCommand` containing before/after mesh, ObjectTransform, and camera snapshots. The temporary permission to capture the completed Autosave snapshot is scoped to this nonthrowing record call and is always cleared with `defer`. Undo restores the original mesh, Redo restores the extrusion result, and each topology installation creates an empty selection for the current runtime topology. Selection and preview are not restored. Runtime adjacency, Picking BVH, and Vertex Spatial Index are prepared for each installed snapshot.

Undo/Redo explicitly invalidates the previous Picking BVH before rebuilding for the restored topology. If rebuilding fails, the mesh and history result remain installed and renderable, Picking becomes unavailable, and the next Sculpt or Face Select pick retries a current-topology build. A provided Workspace cache never falls back silently to a full triangle scan and cannot return a stale-topology hit.

Preview and Cancel do not change history, project mutation generation, dirty state, Autosave, or Recovery. Apply advances the project generation once and schedules Autosave from the fully installed snapshot. The result persists as ordinary vertices and indices in project formatVersion 1. Distance, preview, component data, selection, history, and runtime caches are not serialized. Binary STL export continues to bake ObjectTransform from the resulting mesh.

## Limits and performance

Face Extrude reuses the current Cleanup ceilings of 2,000,000 result vertices, 4,000,000 result triangles, and 768 MiB estimated working memory. Selected-component analysis uses the 1,000,000-face connected-processing ceiling. All index, triangle, byte, dictionary, remap, result-array, BVH, and history-snapshot estimates use checked integer arithmetic. A conservative baseline memory check runs before allocating the global edge table, followed by an exact estimate after boundary and duplicate counts are known.

Analysis and mesh construction are synchronous on MainActor after a yield that gives the loading state an opportunity to appear. This prioritizes atomic state transitions, but a near-limit mesh can temporarily occupy the UI. There is no fixed performance threshold.

## Known limitations

Self-intersection and collision detection are not implemented. The conservative whole-mesh validation can reject a selection because of a distant degenerate, duplicate, invalid, or non-finite element. Open-boundary extrusion, whole-shell extrusion, individual-face direction mode, taper, twist, snapping, interactive extrusion gizmos, multiple objects, material/UV handling, and automatic repair are outside this version. The separate planar convex Face Inset and face-region chamfer operations are described in `FACE_INSET.md` and `FACE_BEVEL.md`; general edge bevel remains outside this version.
