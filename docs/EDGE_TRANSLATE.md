# Selected Edge Translation

Selected Edge Translation is a vertex-only edit available in Edge Select mode with the Move gizmo. It moves the unique endpoints of selected canonical edges without changing indices, topology identity, the edge table, or Edge Selection.

## Identity and geometry

The transaction binds topology ID and revision, edge-table fingerprint, source vertex revision, selection version, project session and generation, transform, selected edge IDs, and source counts. Canonical `low` and `high` endpoint IDs are deduplicated and sorted once. Selected edge count and affected vertex count remain distinct.

Begin projects active Sculpt cancellation, Transform Panel commit, and ordinary Object Move cancellation without mutating the workspace. Fallible capture completes against that projected state. Pointer updates validate selection version and count in O(1); selected edge IDs are captured only once.

The pivot is the center of the endpoints' local-space AABB and uses `minimum * 0.5 + maximum * 0.5`. The Move gizmo supplies a world-space delta. The inverse model matrix transforms it with `w = 0`, so object translation cannot affect the direction. Rotation and uniform or non-uniform scale are respected. Each preview is rebuilt from start positions plus the absolute local delta.

## Preview, commit, and history

Drag uses a separate preview mesh and Picking BVH. Cancel discards both. Empty or no-op drags record nothing. Commit validates the bound runtime state and prepares the committed Picking BVH before installing the mesh and recording one semantic `EdgeTranslateCommand`. Undo and redo participate in the unified workspace history.

Every preview candidate is rebuilt from the committed source mesh and immutable transaction start positions. Preview-BVH preparation, commit-BVH preparation, and final installation are separate failure boundaries.

Only vertex positions change. Edge Selection and edge overlay pair buffers remain valid, while the regular mesh vertex buffer and normals update. Project format version remains 1 and preview or selection state is never serialized.

## Limits

Checked memory preflight uses a 768 MiB ceiling before endpoint allocation, with `min(vertexCount, selectedEdgeCount * 2)` as a conservative affected-vertex bound. It accounts separately for selected edges, endpoint deduplication storage, sorted endpoints, and start positions. Empty selection never falls back to object translation. Invalid, stale, non-finite, over-limit, or preparation failures preserve the committed workspace.

Edge rotation and edge scale are not implemented.
