# Forge3D ソフトウェア設計書 v0.1

## 1. 目的

Forge3Dは、iPad Pro上で以下を一つの制作環境として提供する。

- 自由形状のスカルプト
- 頂点・辺・面を扱うメッシュモデリング
- 数値寸法を持つ基本形状
- 3Dプリント用データ作成
- アクセサリー、レザークラフト、フィギュア、模型、治具、小物などへの用途拡張

アクセサリー専用アプリには限定しない。ただしアクセサリー制作は、寸法精度と有機造形を同時に要求する代表的ユースケースとして優先対応する。

## 2. 商用・依存関係方針

### 2.1 必須原則

1. アプリの主要機能をクラウドAPIに依存させない。
2. 月額・従量課金が必要なSDKを製品の必須経路に置かない。
3. プロジェクト形式を第三者ライブラリの内部形式にしない。
4. 外部ライブラリは交換可能なアダプター越しに利用する。
5. 採用ライブラリのソース、ライセンス文、ビルド手順、採用版を固定して保存する。

### 2.2 初版のライセンス戦略

初版の製品核はApple標準フレームワークと自前コードで構成する。

- UI: SwiftUI / UIKit
- 描画・GPU計算: Metal / MetalKit
- Pencil入力: UIKit / Apple Pencil APIs
- 文書管理: SwiftUI DocumentGroupまたはUIDocument
- 数学: 自前の小規模ベクトル／行列層、必要に応じてsimd
- メッシュ／スカルプト: 自前C++コア

Open CASCADE Technologyは、iOS arm64を含む現行対応がある一方、LGPL 2.1＋追加例外で提供される。将来採用する場合も、製品本体から隔離し、配布条件を確認したうえで有効化する。初版の必須依存にはしない。

## 3. スコープ

### 3.1 MVPに含める

- 透視投影／正投影の3Dビュー
- 回転、パン、ズーム
- 球、立方体、円柱の作成
- オブジェクト選択、移動、回転、拡縮
- Draw、Smooth、Grab、Flatten、Crease
- ブラシ半径、強度、フォールオフ、反転
- X/Y/Z対称
- 固定トポロジー＋手動細分化
- 局所頂点差分によるUndo/Redo
- 独自プロジェクト保存
- STL／OBJ入出力
- 最低限のメッシュ検査

### 3.2 MVPに含めない

- 完全なパラメトリックCAD
- STEP／IGESの製品組み込み
- 高度なNURBS編集
- Dynamic Topology
- ボクセルリメッシュ
- テクスチャペイント
- リアルタイム共同編集
- クラウド必須機能

## 4. 全体アーキテクチャ

```text
Forge3DApp
├── Presentation
│   ├── SwiftUI Screens
│   ├── Tool Panels
│   └── Document Browser
├── Interaction
│   ├── Gesture Router
│   ├── Pencil Router
│   ├── Selection Controller
│   └── Command Dispatcher
├── Rendering
│   ├── Metal Renderer
│   ├── Picking Pass
│   ├── Overlay Renderer
│   └── GPU Compute
├── Domain
│   ├── Scene Graph
│   ├── Mesh Modeling
│   ├── Sculpting
│   ├── History / Undo
│   └── Validation
├── Persistence
│   ├── Project Serializer
│   ├── Mesh Import/Export
│   └── Recovery / Autosave
└── Optional Kernel Boundary
    ├── GeometryKernel Protocol
    ├── NullMeshKernel
    └── Future B-Rep Adapter
```

## 5. 言語境界

### Swift

- アプリ状態
- UI
- ファイル文書管理
- Pencil／タッチイベント取得
- コマンド発行
- アクセシビリティ

### C++

- Half-edgeメッシュ
- 空間探索
- ブラシ演算
- トポロジー変更
- メッシュ検査
- STL／OBJ処理
- 将来のリメッシュ

### Objective-C++

SwiftとC++の薄い橋渡しだけを担当する。ドメインロジックを置かない。

### Metal Shading Language

- 表示
- 深度／IDピッキング
- ブラシ候補範囲の計算
- 頂点変形の補助
- 法線更新
- 将来のボクセル処理

## 6. コアデータ構造

### 6.1 Mesh

初期実装はHalf-edge構造を採用する。

```cpp
struct Vertex {
    Vec3 position;
    Vec3 normal;
    HalfEdgeID outgoing;
    float mask;
    uint32_t flags;
};

struct HalfEdge {
    VertexID origin;
    HalfEdgeID twin;
    HalfEdgeID next;
    FaceID face;
};

struct Face {
    HalfEdgeID edge;
    Vec3 normal;
    uint32_t materialID;
};
```

表示用には三角形インデックスバッファを別途生成する。編集構造とGPU構造を同一にしない。

### 6.2 Scene Object

```text
SceneObject
├── UUID
├── Name
├── Transform
├── Visibility
├── ObjectType
├── EditableMesh reference
├── RenderMesh cache
└── Metadata
```

### 6.3 Sculpt Layer

破壊的編集だけでなく、将来的なレイヤー式スカルプトを可能にする。

```text
SculptLayer
├── layerID
├── name
├── opacity
├── enabled
└── vertex displacement map
```

MVPではベースメッシュへの直接変形を採用し、データ形式にはレイヤー領域を予約する。

## 7. スカルプト処理

1. Pencil位置から画面レイを生成する。
2. BVHで対象三角形との交点を求める。
3. 交点を中心にブラシ半径内の頂点候補を取得する。
4. 距離、筆圧、フォールオフ、マスクから変位量を計算する。
5. 対称点にも同じ操作を適用する。
6. 変更頂点と1-ring近傍の法線を更新する。
7. GPUバッファの変更範囲だけ更新する。
8. ストローク終了時にUndoコマンドを確定する。

### 最初のブラシ

- Draw: 法線方向へ変位
- Smooth: 近傍頂点平均へ補間
- Grab: スクリーン／接平面方向へ移動
- Flatten: ストローク開始時の基準平面へ寄せる
- Crease: 中心へ収束させながら内向き変位

## 8. レンダリング

MetalKitのMTKViewを表示面として利用する。描画パスは以下に分ける。

1. Depth pre-pass（必要時）
2. Object／Face ID picking pass
3. Shaded mesh pass
4. Wire／selection overlay
5. Grid／gizmo／brush cursor overlay

編集メッシュから表示メッシュへの更新は非同期ジョブにし、UIスレッドを塞がない。

## 9. 入力設計

### Apple Pencil

- 接触: ブラシストローク
- 筆圧: 強度
- 傾き: 将来の楕円ブラシ
- ホバー: ブラシ位置・半径プレビュー
- ダブルタップ: 主ツール／副ツール切替
- スクイーズ: ツールパレット
- バレルロール: スタンプ方向または楕円ブラシ角度

### 指

- 1本: オービット（設定で変更可能）
- 2本: パン／ズーム
- 長押し: コンテキストメニュー

Pencil入力とカメラ操作を明確に分離し、誤操作を防ぐ。

## 10. Undo / Redo

### Manual linear triangle subdivision

手動Subdivideはobject-local三角形meshの各共有辺へ一意な中点を作り、1 triangleをwindingを保った4 trianglesへ置換する。元頂点は移動せず、Loop/Catmull-Clark smoothingを同時に行わない。無向edge keyのmidpoint cacheによりseamを防ぎ、完成後にnormalとadjacencyを全再構築する。

これは完全なtopology変更である。新しい`EditableMesh` runtime identityを作るため、`revision`（vertex data変更）、`topologyRevision`（接続構造変更）、`topologyID`（runtime mesh identity）は新runtimeとして開始し、BVH、VertexSpatialIndex、Metal vertex/index bufferを正規経路で再構築する。Transformとcameraは変更しない。

Undoは差分でなく`ReplaceMeshCommand`のbefore/after snapshotを使う。topologyを跨ぐ安全性を優先した判断であり、大規模meshではメモリ負荷が高い。500,000 vertices／1,000,000 trianglesの実用上限と事前memory estimateで危険な操作を拒否する。degenerate/non-manifold入力は暗黙修復せず拒否する。将来Half-edge実装へ移行する際の置換点は`MeshSubdivision`境界である。

Command Patternを採用する。

```text
Command
├── execute()
├── undo()
├── redo()
├── memoryCost
└── mergePolicy
```

`WorkspaceHistory`はSculptとTransformを`WorkspaceCommand`の単一時系列として保存する。スカルプトストロークは変更頂点だけを保存し、Transformは開始値と確定値だけを保存する。新規の意味ある編集はRedoを破棄し、load時は永続化しない履歴を全消去する。

```text
VertexDeltaCommand
├── vertexIDs[]
├── beforePositions[]
├── afterPositions[]
├── beforeMasks[]
└── afterMasks[]
```

トポロジー変更は差分方式を基本とし、複雑な変更のみ圧縮スナップショットを使う。

## 11. プロジェクト形式

拡張子案: `.forge3d`

ZIPコンテナ内に公開仕様のデータを格納する。

```text
project.forge3d
├── manifest.json
├── scene.json
├── history.jsonl
├── meshes/
│   ├── <uuid>.meshbin
│   └── <uuid>.fallback.obj
├── thumbnails/preview.webp
└── extensions/
```

### 必須方針

- manifestにformatVersionを持つ。
- 読み込み時にマイグレーションする。
- 少なくともfallbackメッシュを保持する。
- 外部カーネル固有データはextensions以下に隔離する。
- ユーザー作品を将来も救出できる構造にする。

## 12. GeometryKernel境界

```swift
protocol GeometryKernel {
    var capabilities: KernelCapabilities { get }
    func makePrimitive(_ request: PrimitiveRequest) throws -> KernelBody
    func boolean(_ request: BooleanRequest) throws -> KernelBody
    func fillet(_ request: FilletRequest) throws -> KernelBody
    func tessellate(_ body: KernelBody, quality: TessellationQuality) throws -> MeshData
    func export(_ body: KernelBody, format: CADExchangeFormat) throws -> Data
}
```

MVPでは `MeshGeometryKernel` を提供し、対応しない精密CAD操作はcapabilitiesで無効化する。将来OCCT等を使う場合はアダプターだけを追加する。

## 13. 品質目標

### MVP性能目標

- 60fps目標、最低30fpsを維持
- 100万三角形の表示
- 25万頂点程度まで快適な基本ブラシ
- 通常のブラシ入力遅延を知覚しにくい範囲に抑える
- 破損時に直近自動保存から復旧

実機測定で調整し、端末別に解像度上限と機能を段階化する。

### 信頼性

- 操作ごとの不変条件チェック
- 保存前のメッシュ検証
- クラッシュセーフな一時ファイル保存
- ファジング可能なインポーター設計

## 14. セキュリティ

- 外部ファイルのサイズ・要素数上限
- 不正なインデックス、NaN、無限値の拒否
- ZIP展開時のパストラバーサル防止
- インポーターをUI層から隔離
- 将来のプラグインは同一プロセス内で無制限実行しない

## 15. 拡張モジュール

コア完成後に、用途別機能をモジュールとして追加する。

- Jewelry: リング、石座、円周配列、刻印、肉厚検査
- Leathercraft: 型紙補助、刻印、目打ち部品、3Dプリント治具
- Figurine: 対称造形、パーツ分割、ダボ、自立／重心補助
- Print Prep: 中空化、排液穴、分割、サポート補助
- Product Design: 寸法プリミティブ、スナップ、簡易ブーリアン

## 16. 最初の縦切りプロトタイプ

完成条件:

1. 新規文書を作れる。
2. 球体が表示される。
3. 指で回転・ズームできる。
4. Pencilホバーでブラシ円が表示される。
5. Draw／Smooth／Grabが動く。
6. 1ストローク単位でUndo／Redoできる。
7. 保存して再度開ける。
8. STLを書き出せる。
9. 100回の保存／読込往復で形状が壊れない。

この縦切りが成功するまで、CAD、石座、Dynamic Topologyなどへ進まない。

## 17. Foundation Prototype 実装状態

2026-07-10 時点で `Forge3D.xcodeproj` に最小縦切りを実装した。論理境界は `src/App`、`UI`、`Input`、`Renderer`、`GeometryCore`、`SculptCore`、`Undo`、`FileIO`、`Export` に分離している。

Foundation 段階では編集コアも Swift で実装しており、C++ Half-edge、Objective-C++ bridge、BVH、GPU picking、局所更新は未実装である。これは本書の目標設計を変更するものではなく、次の Repository Foundation / Editable Mesh 作業で置換可能な境界を維持する。

保存形式と既知の制限は `FOUNDATION_PROTOTYPE.md` に記録する。

### 17.1 Foundation runtime cache

Foundation実装の`EditableMesh`は、永続データであるvertices/indicesと、ランタイム専用のadjacency、revision、topology identityを分離する。ランタイムキャッシュはCodableへ含めず、decode後に必要時再構築する。

固定トポロジーのブラシ処理ではadjacencyを再利用する。頂点変更はmesh revisionを進め、Rendererはrevisionが変化した場合だけvertex bufferへ転送する。index bufferはtopology identityが変化した場合だけ更新する。現段階の法線再計算は全体処理のためvertex buffer転送も全体更新とし、局所法線と部分転送は後続最適化とする。

### 17.2 Performance Diagnostics

最適化判断に先立ち、`src/Diagnostics`の共通Profiler境界でPicking、Sculpt、法線再計算、Metal buffer upload、draw CPU時間、frame interval、mesh規模を計測する。Geometry/Sculpt/Rendererは計測結果を保持せず、Profilerへ区間を通知するだけとする。

計測とHUDはDebug限定で、Releaseでは時計取得・lock・サンプル保存をコンパイルしない。詳細な指標定義と計測オーバーヘッドは`PERFORMANCE_INSTRUMENTATION.md`に記録する。計測値が得られる前に特定の最適化を優先すると断定しない。

Debug限定のBenchmark scenarioはDiagnostics境界に置き、Icosphere規模を手動で切り替える。UI都合をGeometryCoreへ持ち込まず、プリセット名は保存形式へ含めない。切替の状態整理はWorkspaceModelが担当し、Rendererは既存topology identity/revision経路でbufferを更新する。Benchmark UIとプリセット実装はReleaseへ含めない。

自動Benchmark Runnerも`src/Diagnostics`のDebug専用境界に置く。固定入力、warm-up、有限統計、text／JSON reportを担当し、GeometryCoreやRendererへbenchmark専用分岐を追加しない。Renderer uploadはrevision／topology identityによる通常更新経路を通す。WorkspaceModelは開始前状態と完了・キャンセル時の復元を所有し、reportを保存プロジェクトへ含めない。

### 17.3 Picking CPU BVH

Picking専用の`MeshBVHCache`はWorkspaceModelが所有し、保存対象のEditableMeshから分離する。連続配列nodeとtriangle referenceを使い、centroid boundsの最長軸を中央値分割する。topology ID変更時はbuild、同一topologyでvertex revision変更時はleafからrootへrefit、同一revisionではreuseする。

これはCPU Pickingだけの索引であり、GPU accelerationやSculpt近傍検索には使用しない。refitは分割順を維持するため極端な変形後にtree品質が低下し得る。SAH、自動再build判定、並列buildは後続検討とする。

### 17.4 Single-object Transform foundation

EditableMeshはobject-local座標を維持し、translation、Quaternion rotation、non-uniform scaleを持つ`ObjectTransform`を別状態として保持する。Rendererは`projection × view × model × localPosition`でworld／clipへ変換し、normalにはmodel linear部のinverse-transposeを使う。Transform変更はmesh topology／revisionを変更せず、vertex／index bufferを再uploadしない。

Pickingではworld-space Rayのoriginを位置（w=1）、directionを方向（w=0）としてinverse model matrixでlocalへ変換する。Sculptはlocal hit center／normal／dragでlocal meshを編集する。brush radiusはworld-space UI値を最大scaleで割る保守的local半径とし、非一様scaleで一方向だけ過大になることを防ぐ。

TransformはFoundation JSON v1へ加算的に保存し、fieldがない旧dataはidentityとして読む。複数object、pivot、snap、Transform bake／STL適用は含まない。

### 17.5 World-space translation gizmo

単一objectの移動ギズモはworld-space固定のX/Y/Z軸とXY/YZ/ZX平面を提供し、`ObjectTransform.translation`だけを変更する。meshはobject-localのままで、ギズモ操作はmesh revision、topology ID、Metal mesh bufferを変更しない。将来のlocal-space modeを追加できるようhandle、state、drag session、幾何計算はUIイベントから分離する。

軸dragはcamera Rayとaxis lineの最近接parameter差を開始時からの絶対差分として用いる。ほぼ平行な場合はaxisとcamera view directionから補助平面を作り、その交点をaxisへ射影する。平面dragは同一world planeとの開始／現在交点差を使い、平行・非有限・過大な差分は無視する。表示scaleはcamera距離、45度FOV、viewport高さからscreen-space約112 point相当を近似し、安全範囲へclampする。

Rendererは固定ギズモbufferをmesh後の別draw callで再利用し、origin、scale、hover／activeだけをuniform更新する。操作性を優先してdepth compareをalwaysとし、オブジェクト背後でも完全には隠さない。入力優先順位はactive gizmo、gizmo handle hit、Pencil Sculpt、指Cameraの順で、drag cancel時は開始Transformを復元する。local軸、snap、pivot、複数objectは未実装である。

### 17.6 World-space rotation gizmo

Transform GizmoはMove／Rotate／Scaleの単一modeを持ち、初期値はMoveとする。Rotateはworld X/Y/Zを法線とする3本のringを表示し、originはobject translation、表示scaleはMoveと同じcamera距離／FOV／viewport近似を使う。ringはobject rotation／scaleに追従せず、mode・hover・active・dragは保存しない。

PickingはRayと各world rotation planeの正方向交差を求め、交点半径とring半径の誤差がcamera scale連動tolerance以内の候補を採用する。候補が複数なら半径誤差、Ray距離、X→Y→Zの順で決定する。平面にほぼ平行なRay、中心、微小・非有限ベクトルはmissまたはそのframeの更新無視とする。

dragは開始交点の正規化vectorと現在vectorから`atan2(dot(axis, cross(start,current)), dot(start,current))`でraw角度を計算する。前回raw角との差を±πでunwrapして連続累積角を保持するため、180度境界と複数回転を連続して通過できる。内部Quaternionは毎frame `worldDelta(accumulatedAngle) * startRotation`から再構成して正規化するため、Quaternion差分の誤差を累積せず、既存rotationに対してもworld-space軸回転となる。translation／scaleとobject-local meshは変更せず、mesh revision／topology／GPU mesh uploadも変化しない。

Rotation ringは固定bufferを専用overlay draw callで再利用し、Moveと同じ軸色・uniform layout・depth always方針を使う。入力優先順位はactive current-mode gizmo、current-mode handle、Sculpt、Cameraである。mode切替、cancel、load、reset、Benchmark開始時はdrag開始Transformへ復元する。自由回転、screen-plane rotation、local軸、snap、pivot、複数objectは含まない。

### 17.7 World-space scale gizmo

Scale modeはworld-space固定表示のX/Y/Z軸線＋先端cubeと、originのuniform cubeを提供する。表示originは`ObjectTransform.translation`で、object rotation／scaleには追従しない。一方、編集対象は`T × R × S`の`ObjectTransform.scale.x/y/z`であるため、回転済みobjectでもX handleはscale.xを変更する。これはworld軸方向そのものへscaleを適用するlocal/world切替機能ではない。

軸dragはMoveと同じRay／axis拘束と平行時fallbackを使い、`factor = 1 + (currentConstraint - startConstraint) / gizmoWorldScale`を開始scaleの選択成分へ絶対適用する。uniform dragは開始時camera-facing planeと安定したcamera right/up対角方向を固定し、その方向への交点変位から同じfactorを求める。開始scale全体へ共通factorを掛けるため、非一様scaleの比率を維持する。各frameの差分は累積せず、無効Rayは最後の有効値を保つ。

scaleは全経路で絶対値を有限な`0.001...1000`へ正値clampし、negative／zero scaleを生成しない。drag中の負factorは反転させず最小値へ止める。uniform時は3成分から共通factor範囲を先に求め、成分別clampによる比率崩れを避ける。中央uniform handleを軸より優先し、軸は中央cube外の有限区間だけをpickする。Scale rendererは共通shader／uniform／軸色と専用固定bufferを使う独立overlay draw callであり、Transform変更でmesh revision、topology ID、vertex／index uploadを変えない。

Move／Rotate／Scaleは相互排他で、active drag、current-mode handle、Sculpt、Cameraの入力順を維持する。mode切替、非表示化、cancel、load、reset、Benchmark開始時はScale sessionも解除し、cancelでは開始Transformを完全復元する。Benchmark中は全ギズモを非表示・操作不可とする。XY／YZ／ZX平面scale、negative scale、snapping、local/world切替、pivot、複数object、mesh bakingは含まない。

### 17.8 Unified Sculpt and Transform history

`WorkspaceHistory`は`StrokeCommand`と`TransformCommand`を同じUndo／Redo stackへ記録し、SculptとTransformをユーザー操作順に戻す。Gizmoはdrag開始Transformを保持し、end時だけ開始値と最終値を1コマンドとして確定する。cancelは開始値を復元して記録しない。Transform panelはfield focus開始から終了までをtransactionとし、live入力を1コマンドへまとめる。Reset Transformは単独コマンドである。

Undo／RedoでTransformを適用してもobject-local mesh、topology ID、mesh revision、GPU mesh bufferは変更しない。Sculpt commandだけが局所頂点位置を復元して通常のmesh revision経路を通る。no-opや非有限commandは拒否し、意味ある新規編集だけがRedoを破棄する。project loadは履歴と未確定panel transactionを消去する。自動Benchmarkは開始時の履歴を一時退避し、実行中はUndo／Redoを無効化して、完了・cancel・timeoutのいずれでも元の履歴を復元する。履歴自体はprojectへ保存しない。

### 17.9 Single-object primitive generation

`PrimitiveMeshBuilder`はGeometryCore内の決定論的な生成境界として、object-local・Y-up・原点中心のUV Sphere、Cube、Cylinderを生成する。UV Sphereは極を各1頂点、経度seamを循環indexで共有する。CubeはSculpt adjacencyを優先した8共有頂点、Cylinderはside ringとcap rimを同じindexで共有する。CubeとCylinderのhard edge normalは分離せず、既存の面積加重頂点normalを使用する。

Primitive作成はmesh topologyの置換であり、新しい`EditableMesh` runtime、adjacency、topology IDを生成する。Picking BVH、Sculpt Spatial Index、Metal vertex／index bufferは固有runtime identityを検知して正規の再構築・upload経路を通り、変更のない後続frameでは再uploadしない。cameraはbounds centerをtargetとし、45度perspectiveに収まる有限distanceへauto-frameする。

`ReplaceMeshCommand`は作成前後のmesh、ObjectTransform、cameraを値型snapshotとして統合Workspace historyへ保存する。Undoは編集済み旧meshを、Redoは生成meshを完全復元し、後続Sculptによるsnapshot汚染を避ける。Foundation段階では全mesh snapshotのメモリ負荷を許容するが、大規模mesh向けの履歴上限・圧縮は技術的負債である。projectには通常のvertices／indicesだけをFoundation v1で保存し、PrimitiveKindやprocedural parameterは保存しない。既存Icosphere Benchmark presetは変更しない。

### 17.10 Flatten, Crease, and object-local symmetry

SculptCoreはDraw／Smooth／GrabにFlatten／Creaseを追加する。Flattenはstroke最初の有効hitでobject-local planeを固定し、stroke中は同じorigin／normalへ有限clamp付きで近づける。Creaseはcenterへの接線pinch 70%とsurface内向きindent 30%を合成する。どちらも固定topologyでindexを変更しない。

`SculptSymmetry`はobject-localのX/Y/Z面を独立指定し、X→Y→Zの決定順で最大8 centerへ展開する。center、surface normal、Grab delta、Flatten planeを同じaxis maskで反転する。epsilon内のcenterを除去し、同一vertexへ複数centerが重なる場合は最大変位候補だけを1sampleにつき1回適用する。symmetryはstroke開始時にsnapshotし、projectやUndoへ保存しない。

候補取得は固定cellの`VertexSpatialIndex`を使い、topology時にbuildし、Sculpt後は変更vertexのcell membershipだけを更新する。normalは変更vertexと1-ring近傍に限定して再計算し、adjacency cacheを再利用する。1strokeはoriginal／mirror双方を1個の`StrokeCommand`へ確定し、cancelは全変更を復元する。index uploadとtopology変更は発生せず、vertex revisionは意味ある変更時だけ進む。symmetry plane overlay、radial symmetry、topology mirror、Mask、Dynamic Topologyは未実装である。
