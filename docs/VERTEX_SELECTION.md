# Vertex Selection

Vertex Selection is runtime-only state for the current single `EditableMesh`. A vertex ID is its stable index in `mesh.vertices`; identity is bound to topology ID, topology revision, vertex count, index count, and a deterministic topology fingerprint. Vertex-only edits preserve IDs. Every topology replacement creates an empty selection, and prior selections are not restored by Undo/Redo.

## Topology and storage

`MeshVertexTopologyTable` records sorted incident edges, incident faces, and neighboring vertex IDs. It classifies boundary, isolated, and edge-non-manifold neighborhoods without welding coincident positions. Its runtime binding checks topology ID, topology revision, vertex count, index count, and a streaming deterministic fingerprint of both counts and the complete triangle-index sequence. This prevents a table or selection from being applied to different connectivity even when lightweight runtime fields are accidentally reused. The dense bitset uses one bit per vertex, keeps `selectedCount` incrementally, and returns selected IDs in ascending order. Replace, Add, Remove, Toggle, Clear, All, and Invert change the runtime UUID version only when content changes.

The supported limit is 2,000,000 vertices with a shared 768 MiB conservative working-memory preflight. Invalid indices, non-finite positions, arithmetic overflow, or memory-limit failure do not mutate the project.

## Picking and connected selection

The existing CPU BVH returns the nearest visible double-sided triangle after the world ray is transformed into object-local space. Only its three vertices are projected. Candidates within 16 screen points are ordered by exact squared screen distance; the lower vertex ID is consulted only when those squared distances are exactly equal. Non-finite inputs and projected candidates are rejected. Picking never scans every triangle and does not build a BVH per tap.

Select Connected performs a breadth-first traversal over shared topological edges and applies the current Replace, Add, Remove, or Toggle operation to every vertex reachable from the current seeds. Toggle flips every component vertex individually. Exact-coincident vertices with different IDs, including split seams, remain disconnected. Isolated vertices form single-vertex components.

## Input and rendering

Input priority is modal UI, active Gizmo drag, Gizmo handle, Vertex Select Pencil tap, Sculpt Pencil stroke, then finger camera. A tap uses the shared 12-point and 0.5-second tracker. Face, Edge, and Vertex selections remain independent across mode changes; only the active overlay is visible. Benchmark and modal operations disable selection.

The Metal overlay reuses the mesh vertex buffer and uploads only sorted selected vertex IDs plus at most one effective hover ID. Raw hover remains available while its vertex is selected; effective hover is suppressed for drawing and automatically reappears when that vertex is removed from the selection without requiring pointer movement. Selected and hover caches are independent. Camera, Transform, Sculpt, and hover-only changes reuse the selected ID buffer. Depth testing is enabled, depth writing disabled, and mesh upload metrics are unchanged.

Each overlay component preflights its real staging peak as the active GPU buffer plus the candidate GPU buffer plus the temporary CPU ID array, using checked arithmetic. Allocation or copy failure hides only the failed component, commits no cache key for it, and leaves the same state eligible for retry on the next update. The peer overlay, mesh rendering, Diagnostics, Gizmos, and Workspace state continue unchanged. The initial implementation builds a sorted selected-ID array for each changed selection, so its temporary CPU cost is linear in selected vertex count.

Draw order is mesh, face overlay, edge overlay, vertex overlay, Diagnostics, then Gizmo. Selected vertices suppress hover to avoid redundant markers.

## Project interaction and limitations

Selection, operation, hover, topology table, and renderer cache are not Codable. They do not change dirty state, Autosave, Recovery, Undo/Redo, metadata, serialized formatVersion 1 bytes, or STL output. Topology-changing Primitive, Subdivision, STL Import, Cleanup, modeling operations, Load, Recovery, and topology Undo/Redo clear selection. Sculpt, Transform, camera, Diagnostics, Save, Autosave, and tool-setting changes preserve it.

Vertex transform, dissolve, weld, merge, topology editing, edge/face conversion, box/lasso/paint selection, through selection, soft selection, and multiple objects are not implemented.
