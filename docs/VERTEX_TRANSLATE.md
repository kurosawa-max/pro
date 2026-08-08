# Selected Vertex Translation

## Scope

Selected Vertex Translation is the first geometry-editing operation built on the runtime-only Vertex Selection foundation. In Vertex Select mode with the Move gizmo active, a drag previews and commits translation of the selected mesh vertices. It does not change `ObjectTransform`, topology, indices, selection identity, or the project format.

Rotation, scale, proportional editing, snapping, soft selection, local-axis gizmos, and multi-object editing are outside this foundation.

## Pivot and coordinate conversion

Selected vertex IDs are sorted before evaluation. Their object-local axis-aligned bounding box is computed deterministically, and its center is the local pivot. `ObjectTransform.modelMatrix` converts that pivot to world space for the existing world-axis Translation Gizmo.

The gizmo produces a world-space delta. The inverse model matrix converts the delta with homogeneous `w = 0`, so translation is excluded while rotation and non-uniform scale are handled. Vertex positions remain object-local. Invalid or non-finite transforms and deltas are rejected.

## Transaction and preview

A drag transaction captures:

- a runtime transaction identity;
- project session identity and the non-rewinding project generation;
- topology ID, topology revision, topology fingerprint, source vertex revision, and source counts;
- the exact Vertex Selection version;
- sorted selected vertex IDs and their start positions;
- sanitized `ObjectTransform`;
- local and world pivot;
- latest world and local deltas.

The selection version is a UUID content identity that changes only when the dense selection actually changes. Runtime drag validation compares this version and the O(1) selected count; it does not rebuild the selected-ID array on every pointer update. Topology identity, fingerprint, vertex revision, project session/generation, and sanitized Transform remain independently bound.

Every preview position is reconstructed from `startPosition + currentLocalDelta`. Updates never accumulate a frame delta. The preview is a separate `EditableMesh`; the committed Workspace mesh, serialized project, history, dirty generation, Autosave, Recovery, and STL output remain unchanged until drag end.

Drag start has a read-only prepared phase. It projects the mesh revision, transform, history generation, and project generation that will exist after conflicting Sculpt, Transform-panel, and ordinary Translation Gizmo sessions are formally ended. It then validates the projected runtime source, copies selected positions, checks the memory limit, binds the final project/session identity, and constructs the final gizmo constraint session. A late preparation failure changes no Workspace or UI state.

After preparation succeeds, `commitPreparedVertexTranslateDrag` is nonthrowing. It ends those conflicts, checks projected values only as internal invariants, and installs the already-complete transaction and gizmo session. It performs no recoverable validation, rebinding, snapshot creation, failure injection, or failed-begin return after conflict resolution starts.

Cancel, mode change, input suppression, modal interruption, or a stale source discards the preview. A zero-distance drag records no history entry.

## Commit, Undo, and runtime caches

A successful drag end prepares the Picking BVH before installing the validated preview and records one dedicated `VertexTranslateCommand` in the unified Workspace history. Undo and Redo restore the selected positions in chronological order with Sculpt and Transform commands. A commit preserves topology ID, topology revision, indices, `ObjectTransform`, camera, and Vertex Selection.

`EditableMesh.updatePositions` recalculates affected normals and advances only vertex revision. The vertex spatial index receives the mutations. Preview Picking uses an isolated BVH cache, while commit prepares and installs the committed BVH before Workspace mutation. The renderer observes the new vertex revision and updates the vertex buffer; unchanged topology prevents an index-buffer upload. Selection ID buffers remain keyed to the unchanged selection and topology.

Explicit cancel and stale-source cancellation restore the raw hover captured at drag start. Commit clears that hover so the next pointer sample can evaluate the committed geometry. Preparation and candidate failure points are injectable in tests; a failed candidate is discarded without changing project content and a subsequent drag can retry.

## Memory and limits

The operation uses the existing 2,000,000-vertex selection limit and a 768 MiB working-memory ceiling. Preflight conservatively accounts for source and preview CPU mesh storage, active and candidate GPU vertex buffers, preview Picking triangle references and BVH nodes, selected IDs and start positions, preview positions, and dictionary/update staging. Overflow is rejected before preview creation.

## Persistence

The project schema remains format version 1. Preview and transaction state are runtime-only and are never encoded. Only a committed mesh position change participates in Save, Autosave, Recovery, project load, and STL export.

## Known limitations

- The first version uses the existing affected-normal rebuild and BVH refit paths; it adds no new geometry acceleration.
- Diagnostics overlay data is not recomputed during a transient drag preview.
- Vertex selection is not persisted or restored by Undo; topology replacement still clears it.
- Vertex rotation, vertex scale, snapping, soft selection, and transform numeric entry are not implemented.
