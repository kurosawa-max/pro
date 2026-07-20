# Exact Seam Merge / Split

## Purpose

Merge / Split is a destructive single-`EditableMesh` topology tool driven by runtime Face Selection. It does not create scene objects, move geometry, or persist operation metadata.

## Split Region

Split Region accepts one edge-connected selected patch inside one host component. The selected patch, unselected remainder, and seam must be unambiguous: the remainder stays connected, the seam is one simple closed loop, every seam vertex has degree two, and the loop cannot touch an existing open boundary or make vertex-only contact.

Source vertices remain first. Seam vertices are duplicated for the selected side only in ascending source vertex ID order. Source triangle order and face IDs remain unchanged; only selected triangle seam indices are remapped. Positions, bounds, triangle count, winding, edge lengths, and triangle areas are unchanged. Component count increases by one and boundary-edge count increases by twice the seam-edge count.

The result has coincident open boundaries. No cap, wall, gap, translation, collision check, or print repair is added.

## Merge Exact Seam

Merge requires Face Selection to contain one complete detached component with one simple boundary loop. Every selected boundary vertex must pair one-to-one with a boundary vertex in exactly one other component by local Float bit pattern. `+0` and `-0` share the canonical zero key; no other tolerance is used.

Selected seam edges must map one-to-one to counterpart boundary edges. Their directed uses must be opposite after pairing. Same-direction winding, missing or ambiguous vertices or edges, three-way coincidence, non-manifold results, and duplicate geometry are rejected without repair.

The counterpart boundary vertex survives. Selected seam duplicates are remapped and removed; surviving source vertices are compacted in ascending old vertex ID order. Source face order and winding remain unchanged. Component count decreases by one and boundary-edge count decreases by twice the seam-edge count.

## Preview and identity

Preview requests use UUID identity through `TopologyPreviewRequestCoordinator`. Candidate generation is separate from model installation. Only the newest request can publish a Preview, error, or busy-state completion. Operation, Face Selection, mesh, or Transform changes invalidate the Preview, and dismissal clears UI and model candidates.

The lightweight runtime key includes topology and vertex revisions, non-rewinding mesh and Transform versions, sanitized Transform, Face Selection version and selected-face fingerprint, operation, source counts, and seam metrics. Apply rebuilds the complete plan and requires exact estimate and analysis-fingerprint equality.

## Transaction and runtime

Source analysis, mapping, result construction, normal and adjacency rebuild, Diagnostics validation, bounds and metric checks, Workspace snapshots, and Picking BVH construction finish before the nonthrowing install boundary. Apply installs one fresh topology and records one `ReplaceMeshCommand`. Face Selection and topology-bound Previews are cleared. Diagnostics and Cleanup state are invalidated. Picking BVH and Vertex Spatial Index are rebuilt, and the normal Renderer revision path is used.

Preview, Cancel, parameter changes, and failures do not change project generation, history, Autosave, Recovery, serialized bytes, or STL output. Apply, Undo, and Redo each advance generation and schedule Autosave once. Undo/Redo restore mesh, Transform, and camera snapshots but do not restore Face Selection or Preview.

## Persistence and limits

Only ordinary vertices and indices are saved. Project `formatVersion` remains 1. Operation, seam pairing, Preview, Face Selection, history, and runtime caches are not serialized. STL export uses the resulting ordinary mesh; a split open seam can require a later exact merge or external repair before printing.

Limits match other topology tools: 2,000,000 result vertices, 4,000,000 result triangles, UInt32-safe indices, and 768 MiB estimated working memory. Analysis is synchronous on MainActor.

## Not included

Multiple objects, proximity or epsilon weld, Merge by Distance, Boolean operations, caps, walls, arbitrary cuts, multiple loops, holes, branched or bow-tie seams, winding or non-manifold repair, collision/self-intersection repair, and vertex/edge selection are not implemented.
