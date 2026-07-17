# Face Selection

## Purpose and scope

Face Selectionは現在の単一`EditableMesh`に対するruntime-onlyのtriangle選択基盤である。Face Select modeではApple Pencilのtapで最前面triangleを選択し、指のcamera操作と既存Transform Gizmoを維持する。この段階では選択結果を表示・管理するだけで、mesh vertex、index、topology、Transformを変更しない。

Edge／Vertex／Box／Lasso／Paint selection、背面貫通選択、soft selection、Extrude、Inset、Bevel、Face delete、選択Transform、multiple objectは未実装である。

## Face identity and source topology

Face IDは現在のindex順に対するtriangle番号である。

```text
faceID = triangleIndex
indexOffset = faceID * 3
valid range = 0 ..< mesh.indices.count / 3
```

`FaceSelection`は`sourceTopologyID`、`sourceTopologyRevision`、`triangleCount`を保持する。vertex position／normalだけが変わってもface IDは維持される。topology ID、topology revision、triangle countのいずれかが変わったselectionはstaleであり、現在meshへ適用しない。

## Dense selection storage

選択内容はtriangleごとに1 bitを使う`[UInt64]` dense bitsetである。単一faceのcontains／set／clear／toggleはO(1)、Clear／Select All／InvertはO(T/64)である。末尾wordの未使用bitはSelect AllとInvertの後にmaskする。

`selectedCount`は変更時に増減し、表示のたびに全bitをscanしない。内容が実際に変わった操作だけがselection専用revisionを進める。同一faceへのAdd、未選択faceへのRemove、同一Replace、空状態のClearでは進めない。revisionは64-bit valueと64-bit epochの組で、value上限時にvalueを0へ戻してepochを進める。project用`MutationGeneration`は流用しない。

Face Selection上限は4,000,000 trianglesで、bitsetは最大約0.5 MiBである。全face overlayのindex列は最大12,000,000 indices、約48 MiBとなる。count、index count、Metal byte countはoverflow検査する。selectionはCodableではなくproject、Recovery、historyへ保存しない。

## Picking and operations

world-space Rayは`ObjectTransform.inverseModelMatrix`でobject-localへ変換し、既存CPU `MeshBVH`を使う。indexed-only入口はcurrent topology ID/revisionとvertex revisionに一致するcacheだけを使い、選択のためのlinear scan fallbackを行わない。既定の両面交差、最短distance、同距離時のtriangle順はSculpt Pickingと同じである。

- Replace: hit faceだけに置換する。空白tapはClearする。
- Add: hit faceを追加する。空白tapは変更しない。
- Remove: hit faceを解除する。空白tapは変更しない。
- Toggle: hit faceを反転する。空白tapは変更しない。
- Clear: 全faceを解除する。
- Select All: 全faceを選択する。
- Invert: 選択／非選択を反転する。
- Select Connected: 現在選択をseedとして、共有edgeで到達できるfaceを追加する。

Select Connectedは無向`DiagnosticEdgeKey`とUnion-Findを使う期待O(T + E)処理である。vertexだけの接触は接続としない。non-manifold edgeではそのedgeを使う全faceが同じcomponentになり、duplicate triangleも入力face順に決定論的に含む。edge hashの一時memoryを制限するため1,000,000 trianglesを上限とし、超過時はselectionとprojectを変更しない。

## Input priority

入力優先順位は次のとおりである。

1. active modal／sheet
2. active Gizmo drag
3. current Gizmo handle
4. Face Select modeのPencil tap
5. Sculpt modeのPencil stroke
6. finger camera gesture

Face Select中もGizmoは表示・操作できる。Gizmo外のPencil入力だけがface候補になる。開始から終了までの最大移動12 points以内、0.5秒以内、終了位置がviewport内の入力をtapとする。cancel、移動超過、時間超過、viewport外、Ray生成失敗、invalid／stale BVHでは既存selectionを変更しない。Face Select中はPencil dragでSculptを開始しない。Benchmarkとactive edit中は選択操作を無効にする。

## Invalidation lifecycle

次のtopology置換では空selectionを新sourceへ作り直す。

- Primitive
- Manual Subdivision
- STL Import
- Mesh Cleanup
- Project Load
- Recovery適用
- topology置換のUndo／Redo
- 将来の別mesh install

以前のtopology runtimeへUndoで戻っても過去selectionは復元しない。selectionは次のvertex-only／runtime操作では維持する。

- SculptとSculpt Undo／Redo
- TransformとTransform Undo／Redo
- camera
- Diagnostics
- explicit Save／Autosave
- brush、symmetry、Gizmo mode

## Renderer overlay

Metal Rendererは既存mesh vertex bufferを再利用し、選択faceの元indexだけを専用selection index bufferへ格納する。object model matrixとcamera view/projectionをmeshと共有し、半透明tintをdepth test有効、depth write無効、depth bias付きで描画する。

描画順は次のとおりである。

1. shaded mesh
2. selected face fill
3. Diagnostics edge／point overlay
4. Transform Gizmo overlay

Diagnosticsを後段に置くため重大edgeをselection fillで隠さない。selected count 0ではdrawしない。selection source topologyとselection versionが変わった時だけ専用index bufferを更新する。camera、ObjectTransform、Sculpt vertex revisionでは更新せず、mesh vertex／index upload metricとBenchmark結果へ加算しない。allocationやvalidationに失敗した場合はmesh表示を続行し、selection overlayだけを非表示にする。

## Dirty, history, and persistence

Face Select mode、operation、selection内容、selection revision、overlay cacheはproject内容ではない。次を変更しない。

- project mutation generationとdirty／save state
- Autosave scheduleとRecovery payload
- Undo／Redo stackと有効状態
- mesh revision、topology revision、topology ID
- ObjectTransform、camera、project metadata
- Foundation formatVersion 1のserialized bytes

project loadとRecovery後は新runtime topologyに対応する空selectionから開始する。

## Known limitations

Select Connectedは初版ではMainActor上の同期pure geometry処理であり、上限付近ではUIを一時的に占有する可能性がある。selection overlayはtriangle fillだけで、outline、hover face、occluded face、multi-object selectionはない。selection Undo／Redoと永続化は意図的に含めない。topology編集機能はこのruntime selection境界を利用する後続作業で実装する。
