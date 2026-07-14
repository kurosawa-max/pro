# Foundation Prototype 実装仕様

**Status:** Implemented prototype  
**Target:** iPadOS 17+  
**Xcode target:** `Forge3D`

## 実装された縦切り

- SwiftUI 内に `MTKView` を統合し、weld済みIcosphereを Metal で描画する。
- 指1本のドラッグでオービット、指2本でパン、ピンチでズームする。
- 画面レイと全三角形の CPU 交差判定でメッシュ表面をピッキングする。
- Pencil の座標、正規化筆圧、altitude、azimuth、timestamp を `PencilSample` に変換する。
- Draw、Smooth、Grab、Flatten、Creaseとobject-local X／Y／Z対称編集を固定トポロジーの頂点変形として実行する。
- touchesBegan から touchesEnded までの変更頂点を1個のSculpt Undoコマンドに保存し、Transform操作と同じ時系列でUndo／Redoする。
- Pencilキャンセル時は進行中ストロークを破棄し、カメラジェスチャーは指入力だけを受け付ける。
- `.forge3d` プロジェクトを保存・再読込し、Binary STL を出力する。
- object-localのUV Sphere、8頂点Cube、Y-up Cylinderを作成し、置換前objectをUndoで復元する。
- コアロジックを XCTest から検証する。

## Foundation 保存形式 v1

Foundation Prototype の `.forge3d` は UTF-8 JSON であり、次を格納する。

- `formatVersion`（現在値 `1`）
- `mesh.vertices`（position / normal）
- `mesh.indices`
- `camera`（yaw / pitch / distance / target）
- `transform`（translation / Quaternion rotation / scale。旧dataで省略時はidentity）
- `metadata`

読み込み境界では 128 MiB、200万頂点、1200万インデックスを上限とし、範囲外インデックス、NaN、Infinity、未知の形式版を拒否する。書き出し前にも同じメッシュ検証を行う。

## アーキテクチャ上の位置付け

これは `docs/ARCHITECTURE.md` で規定した最終 ZIP コンテナ形式の代替決定ではない。Foundation 段階の読み書き可能な最小形式であり、ZIP コンテナ、fallback OBJ、アトミック保存、自動復旧への移行が必要である。`ProjectCodec` の境界を維持し、UI と形式実装を分離する。

本プロトタイプのブラシ、ピッキング、隣接探索は CPU の線形処理であり、25万頂点や60 FPSの性能目標を保証しない。BVH、Half-edge、局所法線更新、GPU 部分更新は後続マイルストーンで実装する。

## Review blocker修正

- `com.forge3d.project`をExported Type Identifierとして登録し、`.forge3d`と対応付けた。
- Icosphere生成時に共有辺の中点を再利用し、極・継ぎ目・縮退三角形を除去した。
- adjacencyは固定トポロジー中にキャッシュし、Codable対象から除外してdecode後に再構築する。
- mesh runtimeにrevisionとtopology IDを持たせ、Rendererは変更がない場合にGPU転送しない。
- vertex bufferは容量が足りる限り再利用し、index bufferはtopology ID変更時だけ更新する。
- ブラシは変更頂点だけを返し、Undo差分はストローク終了時に一度だけ確定する。
- Pickingは重心座標を返し、頂点法線を重心補間する。既定は両面で、明示的な背面カリングも選択できる。
- Smoothは強度・筆圧をclampし、1サンプルの最大移動量をブラシ半径の5%に制限する。

## CI

`.github/workflows/xcode.yml`は標準`macos-15` runnerでiPad Simulator向けの`xcodebuild build-for-testing`と`test-without-building`を実行する。リポジトリは公開設定であり、GitHub公式の課金仕様では公開リポジトリの標準GitHub-hosted runnerは無料対象である。larger runnerは使用しない。

Windows上ではXcode build/testを実行できない。CI結果が成功するまで、iPadOSビルド成功とは扱わない。

## Performance HUD

Debugビルドでは画面右上の`Perf`ボタンから性能HUDを開閉できる。Vertices、Triangles、Picking、Sculpt、Normal rebuild、Vertex/Index upload、Frame CPU、FPSを表示する。時間指標は直近値と60サンプル移動平均を併記する。Releaseでは計測処理とHUDを無効化する。詳細は`PERFORMANCE_INSTRUMENTATION.md`を参照する。

## Object coordinate system

mesh vertexはobject-local座標で保存・編集する。単一objectのTransformは非破壊状態として別保存され、Rendererでworld-spaceへ変換される。非一様scale時のnormalはinverse-transposeで変換する。Pickingはworld Rayをlocalへ戻し、Sculptはlocal座標のmeshを編集する。Transform変更はmesh revisionやGPU mesh bufferを変更しない。

通常toolbarでMove／Rotate／Scaleを切り替え、world-space固定のギズモを表示できる。MoveはX/Y/Z軸とXY/YZ/ZX平面をPencilまたは指でdragし、Transform panelと同じtranslationを非破壊更新する。軸dragはRay／axis最近接を使い、平行時はcamera方向から作る補助平面へfallbackする。平面dragは対応world planeの交点差を使う。camera距離、FOV、viewport高さから表示scaleを近似するため、画面上の大きさは距離によって極端に変化しない。

ギズモはmesh後の独立overlay draw callで描画し、固定GPU bufferを再利用する。mesh revisionやvertex／index uploadは発生しない。操作優先順位はactive drag、gizmo handle、Sculpt、Cameraで、cancel時は開始Transformへ戻る。Benchmark中は非表示・操作不可で、ON／OFF状態はprojectへ保存しない。

Rotateはworld X/Y/Z固定ringを表示し、Rayとring平面の交点半径でPickingする。複数候補は半径誤差、Ray距離、軸順で決定する。drag開始vectorと現在vectorのcross／dotから`atan2`でraw角度を求め、前回raw角との差を±πでunwrapして連続累積角を保持する。Quaternionは毎frame `worldDelta(accumulatedAngle) * startRotation`から再構成して正規化する。平行Rayや微小／非有限vectorはsession角度を変更せず、そのframeを無視する。

Rotation ringも固定GPU bufferと独立overlay draw callを使用し、object rotation／scaleによらずworld-space方向とscreen-space近似サイズを維持する。Transformパネルのdegree値とは双方向同期するが、内部状態はQuaternionである。mode切替、cancel、load、reset、Benchmark開始時はdrag状態を解除し、cancelでは開始Transformを復元する。modeや操作状態はprojectへ保存しない。

Scaleはworld X/Y/Z固定の軸線＋先端cubeと中央uniform cubeを表示する。軸dragは開始時からの拘束距離を`1 + delta / gizmoWorldScale`へ変換して対応する`ObjectTransform.scale`成分だけへ適用する。uniform dragはcamera-facing plane上の固定対角方向へ投影し、開始scale全体へ同じ倍率を掛けるため非一様比率を維持する。表示軸はobject rotationに追従しないが、編集対象は`T × R × S`のscale.x/y/zである。

scaleはTransform panel入力では絶対値を、Gizmo dragでは負factorを最小値へ止めたうえで`0.001...1000`へ有限な正値としてclampし、negative scaleを許可しない。Scaleも固定GPU bufferと独立overlay draw callを使い、mesh bufferを再uploadしない。中央uniformを軸より優先してpickし、Scale mode以外ではScale handleをpickしない。active drag中はSculptとCameraを抑止し、Benchmark中は全Gizmoを無効化する。

Sculpt strokeとTransformは単一のWorkspace historyへ操作順に記録する。Move／Rotate／Scaleのdragはend時に1コマンド、Transform panelはfield focus単位に1コマンド、Reset Transformは単独コマンドとなる。cancelとno-opは記録せず、新規編集はRedoを破棄する。load時は履歴を消去し、自動Benchmark中は履歴を一時退避してUndo／Redoを無効化し、終了時に復元する。履歴はprojectへ保存しない。

現段階では平面scale、negative scale、scale snapping、自由／screen-plane回転、local／world軸切替、複数object、pivot、STLへのTransform bakeを実装しない。STLは従来どおりlocal meshを出力する。

## Primitive generation

通常toolbarの`New Primitive`からUV Sphere、Cube、Cylinderを作成できる。全形状はobject-local、Y-up、原点中心で、作成時に現在meshを置換し、Transformをidentityへ戻し、boundsからcameraをauto-frameする。Sphereの極とseam、Cylinderのseamとcap rim、Cubeの角は共有indexでweldされ、閉じたmanifold topologyを構成する。

Primitive生成は`ReplaceMeshCommand`としてmesh・Transform・cameraの作成前後snapshotを統合Undo履歴へ記録する。projectには生成済みmeshだけをFoundation v1のvertices／indicesとして保存し、種別や入力parameterは保存しない。Cube／Cylinderの縁は編集topologyを優先した平均頂点normalでありhard edge表示ではない。全mesh snapshotは大規模meshで履歴memoryを増加させる。複数object、procedural再編集、Scene hierarchyは未対応であり、Benchmarkの既存Icosphere条件は維持する。

## Flatten, Crease, and symmetry

Flattenはstroke最初の有効hit planeを固定し、Creaseは接線方向pinchとnormal内向きindentで溝を作る。X／Y／Z symmetryはobject-local原点面で最大8 centerへ展開し、normal、Grab delta、Flatten planeもaxisごとに反転する。centerとcandidate vertexを重複排除し、同一sampleで同じvertexを二重更新しない。候補はVertex Spatial Indexから取得し、変更vertexと1-ringだけのnormalを更新するため、topology／index uploadは変化しない。

symmetryはstroke開始時に固定され、1stroke全体をoriginal／mirror込みの1 Undo commandにする。UI設定はprojectへ保存せず、load後は全軸OFFである。3D symmetry plane表示、radial symmetry、topology mirror、Mask、Dynamic Topologyは未実装である。

## 実機検証項目

1. iPadOS 17+ の iPad で起動し、球体が表示される。
2. 指操作と Pencil ストロークが競合しない。
3. Pencil hover のブラシ円、筆圧、Draw/Smooth/Grab を確認する。
4. Undo/Redo、Files 経由の保存・再読込、STL のスライサー読込を確認する。
5. Instruments でフレーム時間、入力遅延、メモリを測定する。
