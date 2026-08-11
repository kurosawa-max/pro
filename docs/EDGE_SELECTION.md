# Edge Selection

Selected edges can be moved with the Move gizmo through the vertex-only [Selected Edge Translation](EDGE_TRANSLATE.md) transaction. It preserves the canonical edge table and Edge Selection; an empty selection does not fall back to object translation.

Selected edges can be moved with the Move gizmo through the vertex-only [Selected Edge Translation](EDGE_TRANSLATE.md) transaction. It preserves the canonical edge table and Edge Selection; an empty selection does not fall back to object translation.

Edge Selection is a runtime-only foundation for selecting topological edges of the current `EditableMesh`. It does not mutate mesh geometry or topology and does not participate in project persistence, Undo/Redo, dirty state, Autosave, or Recovery.

## Identity and deterministic table

An edge is the canonical unordered pair `(min(vertexA, vertexB), max(vertexA, vertexB))`. Position, geometric coincidence, epsilon, and Transform are not part of identity. Exact-coincident edges using different vertex IDs remain distinct, including the two sides of a split seam.

The edge table accumulates the three edges of every triangle, sorts unique keys by low ID then high ID, assigns edge IDs in that order, and sorts incident face IDs. One incident face means boundary, two means manifold interior, and more than two means non-manifold. The fingerprint covers canonical keys and incident faces. The cache is reused across vertex-only edits and invalidated by topology identity changes.

## Selection and connected semantics

`EdgeSelection` is an independent dense bitset bound to topology identity and edge-table fingerprint. Replace, Add, Remove, Toggle, Clear, All, and Invert advance a UUID version only when content changes. A miss never clears selection. `Select Connected Edges` adds every edge in the vertex-ID-connected components containing current seeds; geometric coincidence without a shared vertex ID does not connect components.

Face and Edge Selection states remain independent. Switching modes preserves both states, while only the active overlay is drawn. Every topology replacement clears Edge Selection and hover. Sculpt, normal rebuild, Transform, camera, Save, and other vertex-only or project-neutral operations preserve selected edge IDs.

## Visible-surface picking

Picking first uses the current CPU BVH to find the nearest visible triangle with the existing double-sided policy. Only that triangle's three canonical edges are candidates. Each homogeneous clip-space segment is clipped against Metal's `z >= 0` near plane before point-to-segment distance is measured in screen points. A clipped-out edge is skipped without suppressing the triangle's other visible edges; an invalid matrix or topology makes the pick unavailable. The threshold is 14 points. Equal-distance candidates choose the lower edge ID.

Silhouette-only picking outside a triangle, hidden or occluded edges, through/X-Ray selection, loop/ring selection, and box/lasso selection are not included.

## Overlay and failure behavior

The Metal overlay uploads endpoint vertex-ID pairs. Its vertex shader reads positions from the normal mesh vertex buffer, applies the same Metal near-plane segment clipping, and expands each visible edge into a screen-space quad. Selected edges use 2.5-point thickness and hover uses 5 points. `displayScale` converts these values to drawable pixels, preserving their apparent point width across 1x, 2x, 3x, resized, Split View, and external-display surfaces. Invalid or degenerate projected segments emit no visible quad. Depth testing is enabled, depth writes are disabled, and depth bias reduces z-fighting.

Selected and hover overlays have independent topology-bound cache keys, buffers, counts, staging counters, and upload counters. A hover-only change generates, allocates, copies, and commits only its one endpoint pair; it never enumerates selected IDs or touches the selected buffer. A selection-only change leaves a still-valid hover buffer unchanged. Clearing hover commits only its empty hover state.

Transform and camera changes update uniforms only. Sculpt follows the normal mesh vertex upload path while both endpoint-pair buffers remain reusable. Each changed component completes checked staging, fresh allocation, and copy before committing its buffer, count, and key. A selected-only failure invalidates only selected drawing; a hover-only failure invalidates only hover drawing. When both change, both are staged before either is committed. Component-specific errors are deduplicated, successful retry clears only the recovered component's error, and mesh and selection state always remain intact.

## Memory and persistence

Before allocation, checked count-only estimation includes key accumulation, incident face uses, canonical records, key lookup, vertex-to-edge incidence, selection bitset, CPU pair staging, and GPU pair storage. The guard uses the shared 768 MiB working-memory policy. No partial table is published after failure. Selection remains valid if a large overlay cannot be allocated.

Project `formatVersion` remains 1. Edge Selection, hover, operation, edge table, fingerprint, cache, threshold, and overlay buffers are not serialized.

- Invalidated selected or hover overlays release their Metal buffer reference before retry; the unchanged peer remains available.
