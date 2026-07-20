# Forge3D 開発ロードマップ v0.1

## Foundation Prototype status — 2026-07-10

Swift ベースの縦切りとして、iPadOS Xcode target、Metal 球体表示、カメラ操作、CPU picking、Pencil 入力モデル、Draw/Smooth/Grab、ストローク単位 Undo/Redo、Foundation v1 保存、Binary STL、XCTest を実装した。

この実装は各マイルストーンの製品品質完了を意味しない。特に C++ bridge、Half-edge、BVH、GPU/局所更新、ZIP project container、fallback mesh、autosave/recovery、実機性能測定、CI は未完了である。

2026-07-11のreview blocker修正で、weld済みIcosphere、adjacency cache、mesh revision駆動GPU同期、重心Picking、入力分離、macOS CI定義を追加した。CI定義の追加はMilestone 0完了を意味せず、実際のXcode結果とC++ bridgeは引き続き未完了である。

同日の性能計測基盤ではDebug専用の60サンプルProfilerと開閉式HUDを追加する。測定前にBVH、局所法線更新、GPU Computeの優先順位は確定しない。

手動Benchmark scenarioとしてSmall/Medium/LargeのIcosphere切替とMetrics resetを追加する。これは比較条件を揃えるためのDebugツールであり、自動ベンチマーク、性能保証、最適化実装は含まない。Simulator値と実機値は分けて扱う。

次段階としてDebug専用の自動Benchmark Runnerを追加し、固定入力、warm-up 10回、計測60回で3規模と7ケースをtext／JSONへまとめる。CPU計測でありGPU完了時間やRelease性能を保証せず、固定しきい値による合否や最適化はまだ行わない。

Picking専用CPU BVHとして中央値分割、topology変更時build、vertex revision変更時refit、同一revision reuseを追加する。Sculpt近傍検索、GPU BVH、SAH、並列buildは含めず、Simulator／実機の実測前に効果を断定しない。

単一object Transform foundationとして非破壊translation／Quaternion rotation／scale、Renderer normal matrix、world→local Picking／Sculpt、後方互換保存、通常Transform panelを追加した。

単一objectのworld-space Translation GizmoとしてX/Y/Z軸、XY/YZ/ZX平面、hover／active表示、安定化fallback付き拘束dragを追加した。meshはlocal座標を維持し、ギズモはTransform translationだけを更新する。

world-space Rotation GizmoとしてX/Y/Z ring、Quaternion左乗算による拘束回転を追加した。平行Rayは安全に無視し、固定overlay bufferを再利用してmesh uploadを発生させない。

world-space表示のScale GizmoとしてX/Y/Z軸＋先端cubeと中央uniform cube、Move／Rotate／Scale modeを追加した。軸scaleは開始値の選択成分だけ、uniformは非一様比率を保って全成分へ開始相対倍率を適用する。`0.001...1000`へ正値clampし、固定overlay bufferによりmesh uploadを発生させない。

SculptとTransformを単一時系列で扱うWorkspace historyを追加する。Gizmo drag、Transform panel確定、Reset TransformをTransform commandとして記録し、Sculpt commandと交互にUndo／Redoできる。cancel／no-opは記録せず、新規編集でRedoを破棄する。loadでは履歴を消去し、自動Benchmarkでは開始時履歴を隔離・復元する。履歴永続化、Camera／GizmoMode Undo、複数object履歴は対象外とする。

単一object Primitive生成として、weld済みUV Sphere、8共有頂点Cube、Y-up Cylinder、parameter入力sheet、bounds camera framingを追加する。生成はtopology置換としてruntime cacheを再構築し、mesh／Transform／camera snapshotの`ReplaceMeshCommand`でUndo／Redoする。projectには通常meshだけを保存し、procedural parameter、複数object、hard-edge render cacheは含めない。既存Icosphere Benchmark条件は維持する。全mesh snapshotの履歴memory上限は後続課題とする。

固定topology SculptへFlatten、Crease、object-local X／Y／Z symmetryを追加する。複数軸は最大8 centerへ展開し、center／vertexをdedupeしてnormal／Grab delta／Flatten planeをmirrorする。Vertex Spatial Index候補検索、1-ring normal更新、1stroke＝1Commandを維持し、BenchmarkへFlatten／Crease／X／XYZ caseを追加する。symmetry plane表示、radial symmetry、Mask、Dynamic Topologyは後続範囲とする。

Binary／ASCII STL importを追加する。Binary exact byte layoutとASCII grammarを明示的に判定し、bit-pattern exact weld、degenerate／duplicate／non-manifold／non-finite検証をinstall前に行う。入力座標は変換せずmmと解釈し、identity Transformとauto-frame cameraのmesh置換を1件のUndo／Redoにする。repair、unit自動推測、epsilon weld、multiple objectは含まない。

read-only Mesh Diagnosticsとしてedge分類、winding、duplicate/degenerate、isolated vertices、edge-connected components、Double area/signed volume、world metrics、Subdivision/STL capability、runtime cache、Metal issue overlayを追加する。automatic repair、self-intersection完全検出、wall thicknessはMilestone 7以降の独立作業とする。

Diagnosticsに続く限定Mesh Cleanupとして、preview選択式のisolated vertex、duplicate triangle、degenerate triangle除去、deterministic index remap、全normal/adjacency/runtime再構築、ReplaceMeshCommand 1件のUndo/Redoを追加する。epsilon weld、hole fill、non-manifold/winding repair、component削除はMilestone 7以降の独立検討とする。

単一objectのFace Selection foundationとしてtriangle ID、dense bitset、Replace／Add／Remove／Toggle、Clear／All／Invert／edge-connected selection、CPU BVH picking、再試行可能な専用Metal fill overlay、compact／Dynamic Type UIを追加する。selection versionはUUID identityで整数wrapを防ぐ。selectionはruntime-onlyで、topology置換時にclearし、vertex-only変更では維持する。project dirty、Autosave、Recovery、Undo／Redo、formatVersion 1へ参加しない。Edge／Vertex／Box／Lasso selectionは後続作業とする。

Face Selectionを入力とする安全なFace Extrude foundationとして、共有edge component、area-weighted world normal、signed millimeter distance、top face／boundary side wall、deterministic compaction、必須preview、stale identity、prepared／commit分離した原子的mesh install、snapshot Undo／Redoを追加する。mesh全体のinvalid／degenerate／duplicate／non-finite入力、selected open boundary、non-manifold edge、winding conflict、whole shellを拒否する。Undo／RedoのBVH failureはcache invalidateと後続retryで安全に扱う。self-intersection検出やrepairは行わず、general edge bevel、individual extrusion、interactive gizmo、multiple objectは後続範囲とする。

Face Insetのplanar region安全境界を共有するFace Bevel foundationとして、positive world-mm width、signed world-mm height、2 triangles/edgeのchamfer ring、shifted inner cap、必須preview、stored Floatからのworld width／height／edge垂直断面slope／ring winding検証、prepared commit、ReplaceMeshCommand 1件を追加する。planar strictly-convex single-loop diskだけを受け入れる。共有analysis containerの中立名化、hard-normal split、general edge bevel、concave／hole／multiple-loop／non-planar region、multiple segments、collision repair、multiple objectは後続範囲とする。

単一objectのlocal-axis Mirror Copy foundationとして、X/Y/Z zero-plane、same-side分類、linear component grouping、closed componentのdetached duplicate、open half meshのexact-zero seam共有、boundary／maximum snap Preview統計、snap後専用validation、決定論的vertex/triangle順、reverse winding、必須preview、prepared commit、ReplaceMeshCommand 1件を追加する。plane crossingは切断せず、closed-plane contact、off-plane boundary、bow-tie、branched/incomplete seam、non-manifold／invalid sourceを拒否する。arbitrary plane、world-axis mode、live modifier、self-intersection repair、boolean union、multiple objectは後続範囲とする。

単一objectのlocal-axis Linear Array foundationとして、sourceを含むCount、signed world-mm Spacing、X/Y/Z axis、source基準Double placement、stored Float spacing再検証、copy-major vertex/triangle ordering、detached component/boundary倍増、必須preview、prepared commit、ReplaceMeshCommand 1件を追加する。Transformを維持し、normal/adjacency/BVH/Spatial Indexを再構築する。collision/self-intersection、weld/Boolean、Grid、per-copy transform、live modifier、multiple objectは後続範囲とする。

単一objectのlocal-axis Radial Array foundationとして、Full Circle／signed Open Arc、sourceを含むCount、local-origin pivot、world-space rigid rotation、non-uniform scale対応Double placement、stored Floatの半径／軸投影／角度／chord／edge／area再検証、copy-major detached topology、race-safe必須preview、prepared commit、ReplaceMeshCommand 1件を追加する。exact rotational duplicateは拒否し、一般collision/self-intersection、weld/Boolean、Grid/Spiral/Helix、custom pivot、live modifier、multiple objectは後続範囲とする。

## Milestone 0 — Repository Foundation

- Xcode workspace作成
- Swift/C++/Objective-C++境界の最小ビルド
- CIでコンパイルと単体テスト
- コーディング規約、ADR、依存台帳
- ライセンススキャン

終了条件: 空のアプリが実機起動し、C++関数をSwiftから呼べる。

## Milestone 1 — Viewer

- MTKView統合
- カメラ
- グリッド
- 基本シェーダ
- 球体表示
- 指ジェスチャー
- オブジェクトIDピッキング

終了条件: 実機で安定してモデルを閲覧・選択できる。

## Milestone 2 — Editable Mesh

- Half-edgeメッシュ
- GPU用三角形キャッシュ
- BVH
- 頂点法線
- プリミティブ生成
- メッシュ不変条件テスト

終了条件: 球・箱・円柱を生成し、保存／読込できる。

## Milestone 3 — Pencil Sculpt Vertical Slice

- Pencil入力
- ホバーカーソル
- Draw
- Smooth
- Grab
- 筆圧
- 対称
- 差分Undo

終了条件: 25万頂点の球に対して実用的な操作ができる。

## Milestone 4 — Project and Export

- 1 unit = 1 mm、world dimensions、ObjectTransform bake済みBinary STL、As Displayed/Center at Origin、Binary/ASCII STL importはFoundationで実装済み。STL importはunit推測やrepairを行わない。STL unit metadata、3MF、OBJ Transform bake、multiple-object exportは未実装。
- formatVersion 1を維持した2秒debounce autosave、atomic single-slot Recovery、Recover／Discard／Later、保存状態UI、scene lifecycle flushはFoundationで実装済み。Recoveryは通常Saveを置き換えず、history／runtime cacheを保存しない。snapshot履歴、iCloud、background完了保証は未実装。

- `.forge3d`形式
- 自動保存（Foundation single-slot実装済み。履歴化とcloud同期は未実装）
- 復旧（Foundation Recover／Discard／Later実装済み。複数snapshotは未実装）
- STL出力
- OBJ入出力
- サムネイル

終了条件: 実作品を保存し、外部スライサーへ渡せる。

## Milestone 5 — Modeling Tools

- Move/Rotate/Scale
- Face/Edge/Vertex selection（triangle Face Selection foundationは実装済み。Edge／Vertexとtopology editは未実装）
- Extrude（manifold face patchの基本parallel extrusionはFoundation実装済み。open boundary、whole shell、interactive/individual modeは未実装）
- Inset（planar convex single-loop patchのconstant-width foundationは実装済み。concave、hole、multiple loop、outsetは未実装）
- Basic bevel（planar convex face-region chamfer foundationは実装済み。general edge、multiple segment、concave／hole／non-planar regionは未実装）
- Mirror（local zero-plane Copy foundationは実装済み。cut、arbitrary plane、live modifierは未実装）
- Array（local-axis Linear／Radial Array foundation実装済み。Grid／Spiral／Helix／live modifierは未実装）
- Merge/Split

## Milestone 6 — Sculpt Production Features

- Flatten
- Crease
- Pinch
- Mask
- Manual subdivision
- Manual linear triangle subdivision（共有辺midpoint、snapshot Undo、実用上限、Debug benchmark）はFoundationで実装済み。Loop smoothing、adaptive/local subdivision、Dynamic Topologyは未実装。
- Sculpt layers
- Alpha/stamp brush
- 高密度メッシュ最適化

## Milestone 7 — Remesh and Print Prep

- Voxel representation research
- Voxel remesh
- Mesh repair
- Diagnosticsで確実に分類できる3項目の限定CleanupはFoundationで実装済み。watertight repair、hole filling、non-manifold/winding repairは未実装。
- Watertight検査
- 厚みヒートマップ
- パーツ分割

## Milestone 8 — Domain Modules

最初の候補:

1. Jewelry
2. Leathercraft
3. Figurine / Miniature
4. General 3D Print Tools

## Milestone 9 — Precision Geometry

- GeometryKernel適合試験
- 無償・商用条件の再調査
- B-Repカーネル採否決定
- 寸法拘束、スイープ、ロフト、精密ブーリアン

この段階までは、特定CADカーネルを製品必須依存にしない。
