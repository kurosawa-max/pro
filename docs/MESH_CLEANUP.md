# Mesh Cleanup

## Purpose and safety boundary

Mesh CleanupはMesh Diagnosticsが確実に分類できる問題だけを、previewとユーザーの明示選択後に変更する破壊的操作である。初期状態では全optionをOFFとし、次の3項目だけを対象にする。

- degenerate triangleの除去
- unordered index keyが一致するduplicate triangleの除去
- 元から存在したisolated vertexの選択的除去

hole filling、boundary stitching、epsilon weld、近接vertex統合、non-manifold repair、winding correction、component削除、remesh、decimationは行わない。vertex positionは移動せず、選択されていない問題は変更しない。

## Deterministic algorithm

`MeshCleanup`はUI、Workspace、Rendererへ依存しない。`estimate`と`clean`はsource meshを変更せず、Diagnosticsと同じscale-relative degenerate predicateとunordered triangle keyを共有する。

triangleをsource ID順に1回走査する。degenerate除去を選択した場合はrepeated index、collinear、scale-relative tiny-area triangleを除く。duplicate除去を選択した場合は最初のtriangleをwindingごと保持し、同一winding、cyclic permutation、opposite windingを含む2件目以降を除く。最初の面を保持することで入力順と入力windingを決定論的に保存し、面向きを推測しない。

同じtriangleがdegenerateとduplicateの両方に該当し、両optionを選択した場合はdegenerateを先に分類して除去数の二重計上を防ぐ。duplicate-only Cleanupではこの優先規則は働かず、先頭のdegenerate triangleを保持して後続duplicateだけを除くため、未選択のdegenerate問題は残る。

triangle削除後に新たに参照されなくなったvertexは結果meshの不要データとして常に圧縮し、別件数で表示する。元からisolatedだったvertexは`Remove isolated vertices`を選んだ場合だけ除去する。残すvertexを旧index順にコピーし、`[UInt32?]`の旧→新mappingでindexをO(V + I) remapする。triangle順序とwindingは変えない。

## Validation, limits, and atomicity

入力のinvalid index、NaN/Infinity、空構造はrepair不能として拒否する。結果が全triangleを失う、vertexが3未満になる、選択対象がない、count/byte計算がoverflowする、またはpost-validationに失敗する場合も拒否する。上限は2,000,000 vertices、4,000,000 triangles、保守的なworking set 768 MiBである。

`clean`は新しい`EditableMesh`をローカル値として完成させ、全normal再計算、adjacency構築、bounds/indices/finite normal検証、選択issueの再検証を終えてからWorkspaceへ返す。成功前にWorkspaceを変更しないため、preview/apply failureではmesh、Transform、camera、history、profiler、diagnostics、Renderer upload stateは不変である。

Cleanup sheetを開く準備はatomic applyより前の明示境界である。この準備でactive SculptとGizmoをcancelし、Transform panel transactionをcommitし、hoverをclearする。準備完了後のpreview/apply failureはその時点のWorkspaceを完全に維持する。

## Workspace, Undo, and runtime rebuild

previewは`topologyID + topologyRevision + revision`を保持する。apply直前にsource keyとestimateを再検証し、stale previewを拒否する。Benchmark中と二重Cleanupは拒否する。

成功時は新しいtopology identityを持つmeshへ一度だけ置き換え、ObjectTransform、camera、brush、symmetry、Gizmo mode/visibilityを維持する。before/afterのmesh、Transform、cameraを既存`ReplaceMeshCommand` 1件へ記録するため、Undo/RedoはCleanup全体を1操作として完全復元する。Cleanup option、summary、history、runtime identityはproject formatVersion 1へ保存しない。

新meshはadjacencyを即時構築し、WorkspaceのPicking BVHとVertex Spatial Indexも正規cache境界でprebuildする。Rendererは新topology identityを検出してvertex/index bufferを各1回uploadし、変更のない次frameでは再uploadしない。Diagnostics cacheをinvalidateし、既存reportとoverlayをstaleにする。結果件数を表示した後、`Analyze Again`で残るboundary、component、non-manifold、winding issueを再評価する。

## Preview and performance

previewは現在/結果のvertex・triangle数、各除去予定数、新たなunreferenced vertex数、estimated working memoryを表示する。全optionは既定OFFで、対象なし、処理中、stale previewではCleanupを無効化する。VoiceOver label/hintを提供し、二重押下を防止する。

分類、選択、参照scan、compaction、normal再計算は線形走査を基本とし、duplicate検出はhash setを使う。性能回帰は決定論的な専用XCTest `measure` scenarioで観測し、固定しきい値によるCI失敗は行わない。初版は安全な値型snapshotと原子的installを優先したMainActor同期処理であり、大規模meshではUIを一時停止する可能性がある。

## Known limitations

これはwatertight化や3D-print成功を保証するrepair機能ではない。self-intersection、wall thickness、hole、non-manifold edge、winding、orientation、近接vertex、小componentは変更も自動判断もしない。Cleanup後は必ずDiagnosticsを再実行して残る問題を確認する。
