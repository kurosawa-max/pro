# Face Selection

## Purpose and scope

Face Selectionは現在の単一`EditableMesh`に対するruntime-onlyのtriangle選択基盤である。Face Select modeではApple Pencilのtapで最前面triangleを選択し、指のcamera操作と既存Transform Gizmoを維持する。この段階では選択結果を表示・管理するだけで、mesh vertex、index、topology、Transformを変更しない。

Edge／Vertex／Box／Lasso／Paint selection、背面貫通選択、soft selection、general edge bevel、Face delete、選択Transform、multiple objectは未実装である。安全なmanifold patchに対するFace Extrudeと、planar convex single-loop patchに対するFace Inset／Face Bevelは、このruntime selectionを入力として実装済みであり、詳細は`FACE_EXTRUDE.md`、`FACE_INSET.md`、`FACE_BEVEL.md`を参照する。

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

`selectedCount`は変更時に増減し、表示のたびに全bitをscanしない。内容が実際に変わった操作だけがselection専用revisionを進める。同一faceへのAdd、未選択faceへのRemove、同一Replace、空状態のClearでは進めない。revisionはruntime専用UUID identityと64-bit valueの組である。通常はvalueだけを増やし、valueが上限の状態から次の変更へ進む時は新しいUUIDへ交換してvalueを0へ戻すため、過去のrenderer cache keyへ整数wrapしない。project用`MutationGeneration`は流用しない。

Clear、Select All、Replaceはword列を走査するが、bitset storage自体を再確保せず既存容量を再利用する。Invertを含む全体操作はO(T/64)である。

Face Selection上限は4,000,000 trianglesで、bitsetは最大約0.5 MiBである。全face overlayのindex列は最大12,000,000 indices、約48 MiBとなる。count、index count、Metal byte countはoverflow検査する。selectionはCodableではなくproject、Recovery、historyへ保存しない。

## Picking and operations

world-space Rayは`ObjectTransform.inverseModelMatrix`でobject-localへ変換し、既存CPU `MeshBVH`を使う。indexed-only入口はtopology ID／revisionが変わればcacheをbuildし直し、vertex revisionだけが変わればrefitする。build／refit成功後にcurrent runtime identityを再確認したcacheだけを利用し、invalid mesh、非finite Ray、zero direction、build／refit失敗はunavailableとする。選択のためのlinear scan fallbackは行わない。Undo／Redoでmesh snapshotを復元する際は旧cacheを先にinvalidateし、rebuild失敗後も次のpickで再試行する。Workspaceからcacheを渡すSculptも失敗時に全triangle scanへ無言でfallbackせず、古いtopology hitを使用しない。既定の両面交差、最短distance、同距離時のtriangle順はSculpt Pickingと同じである。

- Replace: hit faceだけに置換する。空白tapはClearする。
- Add: hit faceを追加する。空白tapは変更しない。
- Remove: hit faceを解除する。空白tapは変更しない。
- Toggle: hit faceを反転する。空白tapは変更しない。
- Clear: 全faceを解除する。
- Select All: 全faceを選択する。
- Invert: 選択／非選択を反転する。
- Select Connected: 現在選択をseedとして、共有edgeで到達できるfaceを追加する。

Select Connectedは無向`DiagnosticEdgeKey`とUnion-Findを使う期待O(T + E)処理である。vertexだけの接触は接続としない。non-manifold edgeではそのedgeを使う全faceが同じcomponentになり、duplicate triangleも入力face順に決定論的に含む。edge hashの一時memoryを制限するため1,000,000 trianglesを上限とし、超過時はselectionとprojectを変更しない。

開始時にprocessing stateを設定して一度MainActorをyieldするため、SwiftUIがProgressViewを更新する機会を持つ。ただしgeometry計算自体はMainActor同期であり、計算中の継続的なanimation描画は保証しない。mode／topology／selectionが変わった場合はtaskをcancelし、古い結果をcommitしない。

## Input priority

入力優先順位は次のとおりである。

1. active modal／sheet
2. active Gizmo drag
3. current Gizmo handle
4. Face Select modeのPencil tap
5. Sculpt modeのPencil stroke
6. finger camera gesture

Face Select中もGizmoは表示・操作できる。Gizmo外のPencil入力だけがface候補になる。開始から終了までの最大移動12 points以内、0.5秒以内、終了位置がviewport内の入力をtapとする。cancel、移動超過、時間超過、viewport外、end sample欠落、Ray生成失敗、invalid BVHでは既存selectionを変更しない。Face Select中はPencil dragでSculptを開始しない。Benchmarkとactive edit中は選択操作を無効にする。ContentViewはsheet、file picker／exporter、confirmation alert、Recovery promptの表示状態をMetalCanvasへ渡し、背後のPencil、Gizmo、hover、finger camera入力を抑止する。

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

Diagnosticsを後段に置くため重大edgeをselection fillで隠さない。selected count 0ではdrawせず、そのempty keyは正常なcache stateとして記録する。非empty selectionでは更新試行時にactive cache keyを無効化し、source indicesの検証、byte count検査、buffer確保、copyがすべて成功した後だけcache keyとdraw countをcommitする。失敗時はdraw countを0にして古いoverlayを隠し、keyを未commitのまま保つため同一selectionを次frameで再試行できる。容量を再利用して短いselectionへ更新する場合も新しいselected index countだけをdrawする。camera、ObjectTransform、Sculpt vertex revisionでは更新せず、mesh vertex／index upload metricとBenchmark結果へ加算しない。allocationやvalidationに失敗してもmesh、Diagnostics、Gizmoの描画とWorkspace stateは維持する。

FaceSelectionPanelは最大幅を制限したsafe-area insetに配置し、summaryとcommandsをadaptive gridで折り返す。compact widthまたはaccessibility Dynamic Typeではoperation pickerをmenu表示へ切り替えるため、buttonとcountを画面外へ押し出さない。

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

Select Connectedは初版ではMainActor上の同期pure geometry処理であり、上限付近ではUIを一時的に占有し、ProgressViewの連続animationが止まる可能性がある。selection overlayはtriangle fillだけで、outline、hover face、occluded face、multi-object selectionはない。selection Undo／Redoと永続化は意図的に含めない。Face Extrude／Inset／Bevel Apply後の新topologyではselectionをclearし、過去selectionはUndoで復元しない。Face Deleteなどの追加topology編集は後続作業である。
