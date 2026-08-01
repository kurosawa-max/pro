# Vertex Selection

Vertex Selection is runtime-only state for the current single `EditableMesh`. A vertex ID is its stable index in `mesh.vertices`; identity is bound to topology ID, topology revision, vertex count, index count, and a deterministic topology fingerprint. Vertex-only edits preserve IDs. Every topology replacement creates an empty selection, and prior selections are not restored by Undo/Redo.

## Topology and storage

`MeshVertexTopologyTable` records sorted incident edges, incident faces, and neighboring vertex IDs. It classifies boundary, isolated, and edge-non-manifold neighborhoods without welding coincident positions. The dense bitset uses one bit per vertex, keeps `selectedCount` incrementally, and returns selected IDs in ascending order. Replace, Add, Remove, Toggle, Clear, All, and Invert change the runtime UUID version only when content changes.

The supported limit is 2,000,000 vertices with a shared 768 MiB conservative working-memory preflight. Invalid indices, non-finite positions, arithmetic overflow, or memory-limit failure do not mutate the project.

## Picking and connected selection

The existing CPU BVH returns the nearest visible double-sided triangle after the world ray is transformed into object-local space. Only its three vertices are projected. Candidates within 16 screen points are ordered by distance and then lower vertex ID. Picking never scans every triangle and does not build a BVH per tap.

Select Connected performs a breadth-first traversal over shared topological edges and applies the current Replace, Add, Remove, or Toggle operation to every vertex reachable from the current seeds. Toggle flips every component vertex individually. Exact-coincident vertices with different IDs, including split seams, remain disconnected. Isolated vertices form single-vertex components.

## Input and rendering

Input priority is modal UI, active Gizmo drag, Gizmo handle, Vertex Select Pencil tap, Sculpt Pencil stroke, then finger camera. A tap uses the shared 12-point and 0.5-second tracker. Face, Edge, and Vertex selections remain independent across mode changes; only the active overlay is visible. Benchmark and modal operations disable selection.

The Metal overlay reuses the mesh vertex buffer and uploads only sorted selected vertex IDs plus at most one hover ID. Selected and hover caches are independent. Camera, Transform, and Sculpt changes reuse the ID buffers. Depth testing is enabled, depth writing disabled, and mesh upload metrics are unchanged. A failed overlay allocation hides the failed overlay and leaves the same state eligible for retry; mesh rendering and Workspace state continue.

Draw order is mesh, face overlay, edge overlay, vertex overlay, Diagnostics, then Gizmo. Selected vertices suppress hover to avoid redundant markers.

## Project interaction and limitations

Selection, operation, hover, topology table, and renderer cache are not Codable. They do not change dirty state, Autosave, Recovery, Undo/Redo, metadata, serialized formatVersion 1 bytes, or STL output. Topology-changing Primitive, Subdivision, STL Import, Cleanup, modeling operations, Load, Recovery, and topology Undo/Redo clear selection. Sculpt, Transform, camera, Diagnostics, Save, Autosave, and tool-setting changes preserve it.

Vertex transform, dissolve, weld, merge, topology editing, edge/face conversion, box/lasso/paint selection, through selection, soft selection, and multiple objects are not implemented.
