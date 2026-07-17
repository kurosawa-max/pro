# Autosave and Recovery

## Purpose

Recovery protects committed project edits when the app, process, or device stops unexpectedly. It is a safety copy in the app sandbox; it is not a replacement for an explicit Save to Files and never overwrites a user-selected project URL.

The normal project remains `formatVersion` 1. Recovery stores only the same project payload: mesh vertices and indices, non-destructive `ObjectTransform`, camera, and existing project metadata. History, active edits, diagnostics, cleanup state, benchmark state, runtime caches, renderer buffers, and UI state are excluded.

## Dirty state and ordering

`WorkspaceModel` owns a non-wrapping `MutationGeneration` for committed, persisted content. Sculpt, Transform, Primitive, Subdivision, STL Import, Mesh Cleanup, camera commits, Undo, and Redo advance it. Tool settings, hover, diagnostics, overlays, benchmark activity, cancelled edits, and no-ops do not.

The last explicitly saved generation is the clean baseline. Undo and Redo still advance the generation even when values happen to match an earlier state. At `UInt64.max`, the numeric component remains saturated and a new in-memory identity is assigned, so equality cannot wrap back to an older generation. Neither component is written into the project.

An explicit Save records the generation of the immutable snapshot that was exported. If the workspace changes while the Files sheet is open, Save completion records that older baseline but leaves the newer workspace dirty. Pending autosave work is cancelled, a matching Recovery no newer than the saved snapshot is removed, and any later edits are scheduled again. Save failure or cancellation never deletes Recovery.

## Snapshot and debounce

A snapshot is copied once on the main actor from mesh, Transform, camera, project metadata, generation, timestamp, session identity, and display name. Encoding and file I/O use only that immutable value. Snapshot creation refuses active Sculpt, Gizmo, Transform-panel, and Debug benchmark state; provisional values are never protected as committed work.

Committed changes use a two-second trailing debounce. Continued edits replace the pending request, so Sculpt samples and Gizmo frames do not cause writes. There is no maximum-wait timer in this initial design: a continuous edit is protected after it commits and editing pauses, or when a safe lifecycle flush succeeds. The scheduler and storage boundary are injectable so tests do not wait in real time.

## Recovery wrapper and atomic write

The single recovery slot is:

```text
Application Support/Forge3D/Recovery/current.recovery
```

The wrapper contains a fixed magic value, wrapper version 1, metadata length, project length, SHA-256 checksum of metadata plus project payload, JSON metadata, and the unchanged format-version-1 project JSON. Metadata provides the capture date, display name, vertex and triangle counts, world dimensions, session identity, and source generation used for Save ordering. Inspection performs bounded full decoding before offering Recover. Generation metadata is not part of the normal project payload.

Limits are 128 MiB for encoded project JSON and 160 MiB for the complete wrapper. Length arithmetic is overflow checked. A write checks available capacity when the filesystem reports it and reserves an additional 1 MiB margin. Peak working memory can include the immutable Workspace snapshot, encoded project JSON, metadata/checksum payload, and validation readback; very large projects can therefore require substantially more memory than the final file and take noticeable time.

Writing follows this order:

1. Encode and validate the immutable snapshot.
2. Create the Recovery directory.
3. Reject a different-session single-slot conflict.
4. Write a uniquely named sibling temporary file.
5. Synchronize it, read it back, and fully validate checksum and project data.
6. Atomically replace the current file, or move the first valid file into place.
7. Update UI state only after successful inspection.

Temporary files are removed on every exit path. An encode, space, permission, synchronization, validation, or replacement failure leaves the Workspace, history, dirty generation, and previous valid Recovery unchanged. Corrupted previous Recovery is not silently overwritten.

## Startup and user choices

The first Workspace display inspects Recovery. A valid snapshot shows date, display name, counts, dimensions in millimeters, and file size. Corruption produces an error instead of loading partial data. The sheet uses text and symbols, exposes VoiceOver hints, disables duplicate operations, and fits a scrollable iPad form.

- **Recover** fully validates again, installs the recovered mesh/Transform/camera, clears history and diagnostic/cleanup state, rebuilds adjacency, Picking BVH, and Sculpt spatial index, and starts dirty. The Recovery remains until an explicit Save or Discard.
- **Discard** asks for confirmation, deletes the Recovery, and does not change the Workspace.
- **Later** keeps both Recovery and Workspace unchanged. The save-state control reopens the sheet.

Recover preserves the saved camera exactly and does not auto-frame. Decoding creates a fresh mesh runtime identity. The normal renderer revision path uploads vertex and index buffers once for that identity and skips an unchanged following update. Runtime identity, adjacency, BVH, spatial index, Metal buffers, profiler data, and history are never serialized.

## Project loading and single-slot policy

Before opening Files, dirty work must be flushed to Recovery. If the slot belongs to another session, opening is blocked until Recover or Discard is chosen. A failed decode leaves the current Workspace and Recovery unchanged. A successful project load becomes a clean baseline with a new session; an older retained Recovery is then presented rather than deleted or overwritten silently.

Only one Recovery slot exists. Multiple simultaneous projects, snapshot history, iCloud, CloudKit, remote sync, and external-file autosave are outside this version.

## Lifecycle and status

The normal UI reports Saved, Unsaved Changes, Autosaving, Autosaved with time, or Autosave Failed with Retry. Failure text remains visible and explicit Save remains available. Debug benchmark data is never snapshotted.

On `inactive` and `background`, Forge3D attempts an immediate flush only when no edit transaction is active. On `active`, it rechecks whether Recovery should be offered. OS background execution time and process termination are outside app control, so completion is not guaranteed; explicit Save remains the durable user-controlled operation.
