# Mesh Diagnostics

## Purpose and scope

Mesh Diagnosticsは現在の単一`EditableMesh`を変更せず、Subdivision、Binary STL出力、3D print前確認に必要な構造と寸法を報告する。診断はrepairより先に独立したread-only境界として実装する。問題を自動変更するとUndo、保存互換性、入力windingの意図を曖昧にするためである。

`MeshTopologyDiagnostics`、`MeshMetricDiagnostics`、`MeshDiagnosticsOverlayBuilder`はUI、Workspace、Rendererに依存しない。入力vertices/indices、runtime revision/topology identity、history、GPU bufferを変更しない。`MeshDiagnosticsReport`とoverlay設定はruntime-onlyで、Foundation project formatVersion 1へ保存しない。

## Topology classification

各triangleから`(min(indexA,indexB), max(indexA,indexB))`の無向edge keyを作り、使用数をO(T)のhash tableで集計する。

- 1 use: boundary edge
- 2 uses: manifold candidate
- 3 uses以上: non-manifold edge

2 triangleが共有edgeを逆方向に使う場合はorientation consistent、同方向に使う場合はwinding conflictとする。unorderedな3 index keyが既出なら、同一winding、rotated order、opposite windingのいずれもduplicate triangleとして扱う。自動削除・winding反転は行わない。

repeated index、範囲外index、non-finite position、zero area、mesh boundsに対して極端に小さいareaをdegenerate/fatal issueとして報告する。triangleから参照されないvertexはisolated warningである。connected componentはtriangleをnode、共有edgeをconnectionとするUnion-Findで計算するため、vertexだけで接するtriangleは別componentになる。複数componentとboundaryはwarningであり、自動結合やhole fillはしない。

## Geometry and units

`1 Forge3D unit = 1 mm`を維持する。areaとsigned volumeはFloat positionをDoubleへ昇格して累積する。

- local area: `0.5 × length(cross(b-a,c-a))`
- local signed volume: `dot(a,cross(b,c))/6`
- world area: 非一様scaleを正確に扱うため、各triangleの3頂点をTransformして再計算
- world volume: 信頼可能なlocal volumeへ`abs(scale.x × scale.y × scale.z)`を適用
- world bounds: 既存`ObjectDimensions`と同じlocal AABB 8 cornersの変換・再包含

volumeはclosed、manifold、non-degenerate、non-duplicate、orientation-consistent meshだけを信頼して表示する。open/non-manifold meshのtetrahedron和はUIでvolumeとして表示しない。信頼可能なsigned volumeが負ならinward orientationの可能性をwarningで示す。

## Severity and operation capabilities

Healthyは有効なclosed manifoldで、duplicate、degenerate、non-manifold、winding conflict、isolated/disconnected issueがない状態である。open/boundary、isolated vertex、multiple component、near-zero volume、inward orientationはWarningである。invalid structure/index、NaN/Infinity、degenerate、duplicate、non-manifold、winding conflictはErrorである。

Subdivision可否は既存`MeshSubdivision.estimate`と`validateLimits`を呼び、予測vertices/triangles/working memoryも表示する。STL可否は既存`STLExportPipeline.estimate`を呼ぶ。現行Binary STL serializerはvalid/finite/non-degenerate/size条件を満たすopenまたはnon-manifold meshを技術的には出力できるため、後者はdiagnostics Errorとprintability warningを示しつつ`canExportSTL`はtrueになり得る。これは印刷可能性の保証ではない。

## Cache and Workspace lifecycle

`MeshDiagnosticsCache`のkeyは`topologyID + topologyRevision + revision + sanitized ObjectTransform`である。同一keyはreportをreuseし、Sculpt/Undoのvertex revision、Primitive/Import/Subdivision/loadのruntime topology、Transform変更でstaleになる。load時はreportをnilにする。stale reportのmetricsとoverlayは表示せず、Refreshで再解析する。

初版のWorkspace解析はMainActor上の上限なし同期処理である。Benchmark、active Sculpt、active Gizmo drag中は拒否し、Transform panel transactionをcommitせず、historyへcommandを追加しない。pure analyzerを分離しているため、将来は安全なsnapshotと非同期実行へ置換できる。

## Viewport overlay

boundary（orange）、non-manifold（red）、winding conflict（magenta）をline、degenerate（red）とisolated vertex（yellow）をpointで表示する。座標はobject-localのまま保持し、draw時に同じmodel/view/projection matrixを適用する。各categoryは最大1,000代表で、total countはreportに正確に保持する。

overlayはmesh vertex/index bufferと別pipeline/buffer/revisionを使い、診断cache更新時だけ再uploadする。category toggleはdraw callだけを切り替える。診断箇所をcamera角度で見失わないためdepth compareは`always`、depth writeは無効である。overlayはpicking対象でなく、Sculpt/Gizmo/Camera inputを奪わない。

## Debug benchmark

Small/Medium/Large Icosphereの各presetで、既存warm-up 10回・計測60回を使い、topology analysis、local geometry metrics、world metrics、overlay generationを別caseとしてCPU計測する。reportにはvertices、triangles、後方互換なoptional unique-edge contextを含む。GPU完了時間、固定performance threshold、Workspace install、Renderer state変更は含まない。

## Known limitations

self-intersection完全検出、wall thickness、overhang、support、repair、hole filling、epsilon weld、duplicate削除、winding自動修正、remesh/decimation、multiple objectは未実装である。closed manifold判定だけでは実際の3D print成功を保証しない。大規模meshの同期解析と、capability確認時に既存validationが行う追加走査は一時的にUIを停止させる可能性がある。
