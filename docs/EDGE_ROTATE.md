# Selected Edge Rotate

Selected Edge Rotate is a vertex-only edit of the endpoints of the current edge selection. Edge Select mode routes the existing world-space rotation gizmo to this operation; an empty selection never falls back to object rotation.

## Transaction and geometry

Drag begin binds topology identity and revision, edge-table fingerprint, vertex revision, source counts, edge-selection version, sanitized object transform, project session, and project generation. Selected edge IDs are captured once. Their endpoint IDs are deduplicated and sorted, so pointer updates do not scan the selection bitset.

The pivot is the affected endpoints' start-position local AABB center, computed as `minimum * 0.5 + maximum * 0.5`. Every pointer update reconstructs from the stable committed or projected source plus the current absolute angle. The previous preview mesh is never used as the source of the next preview, so the result and vertex revision are deterministic with respect to pointer sample count. Each reconstruction subtracts the pivot, transforms the offset with model-matrix `w = 0`, rotates it around world X/Y/Z, transforms it back with inverse-model-matrix `w = 0`, and restores the pivot. This is translation-independent and supports rotation with non-uniform object scale.

The existing rotation session provides an unwrapped multi-turn angle. Full-turn-equivalent angles are no-ops. Finite, normalized-axis, inverse-transform, and render-space round-trip checks reject unsafe candidates.

## Preview, history, and runtime

Preview has a private mesh and BVH. Commit prepares the final picking BVH before installing the candidate and records one semantic `EdgeRotateCommand`. Undo and redo update only affected vertex positions in the unified workspace timeline. Topology, indices, object transform, edge selection, camera, project format version 1, and selection identity are preserved.

Renderer synchronization uses the normal vertex-revision path. A committed edit uploads vertices only; mesh indices and selection endpoint-pair buffers remain reusable. Preview and cancel do not affect project bytes, STL output, history, dirty generation, Autosave, or Recovery.

Checked peak-memory estimation uses the shared 768 MiB policy and includes candidate mesh, normals, captured endpoints, and BVH preparation. Preparation, stale identity, numeric, preview-BVH, and commit-BVH failures are atomic and retryable.

Local-axis rotation, custom pivots, snapping, proportional editing, multiple objects, Edge Scale, and topology changes are not included.
