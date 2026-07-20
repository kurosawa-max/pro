# Foundation Prototype 実装仕様

**Status:** Implemented prototype  
**Target:** iPadOS 17+  
**Xcode target:** `Forge3D`

## 実装された縦切り

- SwiftUI 内に `MTKView` を統合し、weld済みIcosphereを Metal で描画する。
- 指1本のドラッグでオービット、指2本でパン、ピンチでズームする。
- 画面レイとCPU BVHの三角形交差判定でメッシュ表面をピッキングする。
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

本プロトタイプの編集コアはCPU実装であり、25万頂点や60 FPSの性能目標を保証しない。Picking BVHとSculpt頂点近傍indexは導入済みだが、Half-edge、GPU Picking、全面的なGPU部分更新は後続マイルストーンで実装する。

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

## Manual mesh subdivision

通常toolbarの`Subdivide`は現在meshをLinear Triangle Subdivisionで1段階だけ細分化する。元頂点を移動せず、共有辺の中点cacheを再利用し、各triangleを4 trianglesへwindingを保って分割する。確認画面は現在値、予測vertices/triangles、保守的なworking-memory概算を表示する。

処理後はnormal、adjacency、boundsと全runtime cacheを新meshとして再構築する。Transform、camera、brush、symmetry、gizmo modeは維持し、1回の操作を`ReplaceMeshCommand` 1件としてUndo/Redoする。保存形式version 1には結果vertices/indicesだけを保存し、subdivision levelやmidpoint metadataは追加しない。

上限は500,000 vertices／1,000,000 trianglesで、超過・overflow・non-manifold・degenerate・非finite入力はmeshと履歴を変更せず拒否する。初版は原子的な状態管理を優先したMainActor同期処理である。Loop/Catmull-Clark、adaptive/local subdivision、Dynamic Topology、GPU subdivision、元頂点再配置は未実装である。

## Millimeter units and STL export

内部1 unitは1 mmであり、既存projectの数値は自動scaleせずそのままmmと解釈する。新規Primitive UIの既定値はSphere radius 10 mm、Cube 20 mm、Cylinder radius 10 mm/height 20 mm、product Brush radiusは2.5 mmである。Debug Benchmarkの固定0.28は比較継続性のため維持する。

Transform panelはlocal AABBの8 cornersから求めたworld-space X/Y/Z実寸をmm表示する。STL export sheetはBinary STL、Millimeters、As Displayed/Center at Origin、dimensions、triangle count、予測file sizeを表示する。sheet開始前にactive Sculpt/Gizmoをcancelし、Transform panel transactionをcommitする。export時だけTransformを軽量positions配列へ適用し、変換後triangleからnormalを再計算する。serializationはsource mesh、Transform、camera、history、revision、topology ID、GPU uploadを変更しない。

STLはunit metadataを標準化していないため、Forge3Dは座標をmmとし、header hintは保証として扱わない。formatVersion 1、local mesh、別Transformを維持し、export optionsは保存しない。3MF/OBJ/STEP、multiple object、print-bed placement、repairは未実装である。

## Binary and ASCII STL import

Filesの`Import STL`はBinaryとASCII STLをpreview後に現在meshへ置き換える。Binaryは`84 + 50T`のexact layout、ASCIIは明示的なfacet grammarで判定するため、`solid`で始まるBinaryも誤判定しない。入力座標はscaleせずmmと解釈し、`-0/+0`を正規化したFloat bit-pattern exact weldを行う。STL facet normalは信用せずgeometryからnormalとadjacencyを再構築する。

boundary meshとclosed manifoldは許可し、non-manifold edge、duplicate/degenerate triangle、NaN/Infinityはrepairせず拒否する。importはidentity Transformとbounds auto-frame cameraを持つ`ReplaceMeshCommand` 1件で、Undo/Redoは元とimport後のmesh/Transform/cameraを復元する。source 256 MiB、1,000,000 triangles、500,000 welded vertices、概算768 MiB working setを上限とする。詳細は`STL_IMPORT.md`を参照。

## Mesh diagnostics

通常toolbarの`Diagnostics`は現在meshをread-only解析し、vertices/triangles/unique edges、boundary/manifold/non-manifold、duplicate/degenerate、isolated vertices、edge-connected components、shared-edge winding、local/world area、信頼可能なsigned volume、8-corner world dimensionsを表示する。Subdivision/STL capabilityは既存validationへ委譲する。open meshはwarningで、現行STL serializerが許可するnon-manifold出力はdiagnostics Errorとprintability warningを併記する。

report cacheはtopology identity/revisionとObjectTransformをkeyにし、編集後のstale metrics/overlayを表示しない。Metal overlayは最大1,000代表/categoryの独立line/point bufferを診断更新時だけ作り、mesh uploadやinputへ干渉しない。reportと表示設定はformatVersion 1へ保存しない。repair、self-intersection完全検出、wall thicknessは未実装である。詳細は`MESH_DIAGNOSTICS.md`を参照。

## Explicit mesh cleanup

Diagnostics panelの`Cleanup…`は、default OFFのoptionをユーザーが選んだ場合だけdegenerate triangle、duplicate triangle、isolated vertexをpreview後に除去する。duplicateはunordered index keyに対する最初の面とそのwindingを保持する。triangle削除で新たにunreferencedとなったvertexは常に圧縮し、元からisolatedのvertexはoption選択時だけ除去する。position、残存triangle順、windingは変更しない。

結果は新しいEditableMeshとして全normal/adjacency/runtime cacheを再構築し、ObjectTransform、camera、brush、symmetry、Gizmo設定を維持した`ReplaceMeshCommand` 1件でUndo/Redoする。Diagnosticsはstaleになり、結果件数表示から明示的に再解析する。Cleanup設定/report/history/runtime cacheはformatVersion 1へ保存しない。epsilon weld、hole fill、non-manifold repair、winding correction、component削除は未実装である。詳細は`MESH_CLEANUP.md`を参照。

## Autosave and Recovery

保存対象の確定変更はdirty generationを進め、2秒のtrailing debounce後にapp sandboxのsingle Recovery slotへ保存する。snapshotはMainActorでmesh／ObjectTransform／camera／metadataを一度だけ固定し、active Sculpt、Gizmo、Transform panel transaction、Debug Benchmarkの中間状態を含めない。scene inactive/backgroundでは安全な場合だけ即時flushを試みるが、完了は保証しない。

Recovery wrapperは通常project formatVersion 1を変更せず、metadata、長さ、SHA-256、project JSONを持つ。128 MiB project／160 MiB wrapper上限と空き容量確認を行い、一時fileへのwrite、synchronize、read-back validation、backup付きatomic replace、final inspectionがすべて成功した後だけAutosavedへ遷移する。final inspection失敗時は旧Recoveryを復元・再検証する。通常Saveはuser-selected URL、Recoveryは`Application Support/Forge3D/Recovery/current.recovery`であり、Recoveryは明示Saveの代替ではない。

起動時previewからRecover／Discard／Laterを選ぶ。Recoverはmesh／Transform／cameraを復元し、history／Diagnostics／Cleanup状態をclearしてruntime cacheを再構築したdirty Workspaceを開始する。Discardは確認後にRecoveryだけを削除し、Laterは再表示導線を残す。Undo history、runtime identity/cache、Metal buffer、profiler、UI stateは永続化しない。single slot、iCloudなし、非常に大きいprojectのencode時間とmemory、background完了非保証が既知の制限である。詳細は`AUTOSAVE_RECOVERY.md`を参照。

## Face Selection foundation

通常toolbarのSculpt／Face Select切替で、Pencil tapから現在meshのtriangle faceを選択できる。face IDはindex順のtriangle番号で、source topology ID／revision／triangle count付きdense bitsetへ保存する。Replace／Add／Remove／Toggle、Clear／Select All／Invert、共有edgeによるSelect Connectedを提供する。Gizmo handleはface pickより優先し、finger camera gestureはFace Select中も維持する。

Rendererはmesh vertex bufferを再利用し、選択faceのindexだけを独立bufferへ選択変更時にuploadする。半透明fillの後にDiagnostics、続いてGizmoを描くため、診断edgeと操作handleを隠さない。Sculpt vertex変更、camera、Transformではselection indexを再uploadしない。

selection versionはruntime UUID identityとUInt64 valueで構成し、value上限後は新identityへ切り替えてoverlay cache keyのwrapを防ぐ。非empty overlayはindex検証、buffer確保、copy成功後だけcache済みにし、失敗時は古いoverlayを隠して次frameで再試行する。panelはsafe-area insetとadaptive gridを使い、compact widthとaccessibility Dynamic Typeではoperationをmenu表示する。

selectionはmeshを変更せず、dirty generation、Autosave、Recovery、Workspace history、project formatVersion 1へ含めない。Primitive、Subdivision、STL Import、Cleanup、Load、Recover、topology Undo／Redoでclearし、Sculpt、Transform、camera、Save、Diagnosticsでは維持する。詳細と上限は`FACE_SELECTION.md`を参照。Edge／Vertex／Box／Lasso selection、selection Undo、selection永続化、general edge bevelは未実装である。

## Face Extrude foundation

Face Select panelの`Extrude…`は、共有edgeで接続された選択componentごとにworld-space area-weighted normalを求め、signed millimeter distanceだけ平行移動したtop facesとboundary side wallsを生成する。distanceはlocal→world displacement→inverse localの順に適用するため、rotationと非一様scale下でもworld mmを維持する。同一componentの元vertexは1回duplicateし、vertex-only接触component間では分離する。元selected interior vertexは決定論的にcompactする。

全selected incident edgeはglobal use 2件と反対windingを必要とし、selected open boundary、non-manifold、winding conflict、boundaryのないwhole-shell selectionを拒否する。さらにmesh全体へinvalid index、non-finite、degenerate、duplicateがないことを保守的に要求し、選択外のboundary／non-manifold／winding issueは結果で件数不変の場合だけ維持する。previewはtopology／vertex／selection／Transformの非巻戻しruntime identity、distance、解析fingerprintへ結合し、再計算開始時に旧previewを無効化してApply時に全再計算一致を要求する。resultはWorkspace外でnormal、adjacency、Diagnostics invariants、Picking BVHまで検証してから1回installする。

成功は`ReplaceMeshCommand` 1件としてUndo／Redoし、新topologyでselectionとpreviewをclearする。Applyはthrow可能なprepared phaseとnonthrowing commit phaseを分離し、snapshot許可flagを履歴record中の`defer` scopeへ閉じる。Undo／RedoのPicking BVH rebuildが失敗した場合はcacheをinvalidateし、mesh表示とhistory結果を維持して後続pickで再試行する。Transform、camera、brush、symmetry、Gizmo mode、Face Select mode、selection operationは維持する。Applyだけがdirty generationを1回進めAutosaveをscheduleし、preview／Cancel／failureはproject状態を変更しない。formatVersion 1には結果vertices／indicesだけを保存する。2,000,000 vertices、4,000,000 triangles、1,000,000 selected faces、768 MiB working estimateを上限とする。同期処理、self-intersection非検出、open surface／whole shell非対応、general edge bevel／multiple object未実装が既知の制限である。詳細は`FACE_EXTRUDE.md`を参照。

## Face Inset foundation

Face InsetはFace Selectionのshared-edge componentをworld-spaceへ投影し、positive millimeter widthのconstant-width inner boundaryとring triangleを生成する。初版はplanar、simple、strictly convex、single-loop、disk topologyのcomponentだけを許可し、concave、hole、multiple loop、non-planar、collapse、unsafe miterを明示的に拒否する。boundary頂点をoffsetし、選択内点は同じ位置でcomponentごとに複製する。local Floatへの格納後にworldへ戻した実座標でedge距離、strict interior、inner edge交差、triangle overlap／fold-over、area充填、preview boundsを再検証する。pairwise交差検査はcomponentごとに8,000,000 pairを安全上限とする。

preview source identity、prepared／nonthrowing commit、全mesh validation、fresh topology、normal／adjacency／BVH／Spatial Index再構築、ReplaceMeshCommand 1件、selection clear、dirty／Autosave挙動はFace Extrudeと同じ安全境界を使う。snapshot許可flagは履歴recordの同期scopeだけで有効になる。preview、Cancel、failureはWorkspace不変で、formatVersion 1には通常のresult meshだけを保存する。詳細は`FACE_INSET.md`を参照する。

## Face Bevel foundation

Face BevelはFace Insetと共有するplanar region geometryを使い、positive world-mm widthのinner boundaryをcomponent normalへsigned world-mm heightだけ移動し、outer boundaryとの間へ2 triangles/edgeのchamfer ringとshifted inner capを作る。初版はplanar、simple、strictly convex、single-loop diskだけを許可する。local Float格納後の実world座標でwidth、height、slope、inner intersection／coverage、ring degeneracy、result boundsを検証し、一般collisionやautomatic repairは行わない。

preview source identity、prepared／nonthrowing commit、fresh topology、normal／adjacency／BVH／Spatial Index再構築、ReplaceMeshCommand 1件、selection clear、record-only Autosave snapshot scope、dirty／failure atomicityはInsetと同じである。stored Float頂点からworld width／height／edge垂直断面slopeとring windingを検証し、minimum dimensionをFloat精度で保持できない場合は拒否する。width／height／previewは保存せずproject formatVersion 1を維持する。normalはarea-weighted shared-vertex方式のためsharp chamferがviewportで滑らかに見える場合がある。general edge bevel、concave／hole／multiple-loop／non-planar region、複数segment、hard-normal split、multiple objectは未実装である。詳細は`FACE_BEVEL.md`を参照する。

## 実機検証項目

## Mirror Copy foundation

通常toolbarの`Mirror`は、現在meshをobject-local `X/Y/Z = 0`面で破壊的に複製する。planeを跨ぐmeshは切断せず拒否する。Union-Find後のedge列を1回だけcomponent別へgroup化する。plane非接触のclosed shellはdetached copy、boundary全体がplane上のclosed degree-2 loopであるopen half meshはseam vertex共有のwelded copyとして扱い、bow-tie vertex ID共有は拒否する。seamはscale-aware tolerance内だけexact zeroへsnapし、boundary edge数とmaximum snap距離をPreview表示する。snap後のcollapse／geometry duplicate、別vertexが同一点になる衝突、nearby-only weldはmutation前に拒否する。

source vertex/triangle順を保持し、mirror vertexはsource index順、mirror triangleは`(a,c,b)`で追加する。結果はboundary 0、expected component count、finite/normalized normal、degenerate/duplicate/non-manifold/winding、symmetry、local/world bounds、adjacency、Picking BVHをinstall前に検証する。previewはmesh/Transformの非巻戻しidentity、axis、分類、fingerprintへ結合する。

Applyはprepared／nonthrowing commit境界を使い、`ReplaceMeshCommand` 1件としてUndo/Redoする。Transform、camera、brush、symmetry、Gizmo、interaction modeを維持し、Face Selectionとtopology previewをclearする。Applyだけがdirty generationを1回進め、Autosave snapshot許可はhistory record中だけ有効である。resultは通常meshとしてformatVersion 1へ保存され、Mirror axis/tolerance/planは保存しない。Rendererはfresh topologyのvertex/index bufferを通常経路で各1回uploadする。詳細は`MIRROR_COPY.md`を参照する。

## Linear Array foundation

通常toolbarの`Linear Array`は、sourceをcopy 0として含むCount `2...256`とsigned Spacing `±0.001...1000 mm`を使い、mesh全体をobject-local X/Y/Z方向へ破壊的に複製する。local axisをObjectTransformのlinear部でworldへ変換・正規化し、各copyをsourceから直接Double world座標で計算する。local Floatへ格納した実頂点をworldへ戻し、全copyのsigned spacing、距離、垂直driftを検証するため、巨大座標でminimum spacingを保持できない場合は安全に拒否する。

vertex/triangleはcopy-majorで決定論的に並び、copy 0のsource position/indexを保持する。各copyはdetachedで、component数とboundary edge数はCount倍になる。normal、adjacency、bounds、Diagnostics topology、exact geometry duplicateをApply前に検証するが、一般collision、self-intersection、proximity weld、Boolean unionは行わない。

mandatory PreviewはUUID request identityを使い、最新requestだけがUI／model Preview、error、busy状態を更新する。parameter変更とsheet dismissalはrequestを無効化してghost Previewを防ぐ。軽量runtime identity判定はUI描画でDiagnosticsやfingerprintを再計算せず、Apply prepared phaseがestimateとanalysis fingerprintを完全照合する。`ReplaceMeshCommand` 1件、record-only Autosave snapshot scope、selection／他topology Preview／Diagnostics clear、BVH／Spatial Index再構築、通常Renderer upload経路を使用する。Transform、camera、tool/mode設定は維持し、formatVersion 1には通常のresult meshだけを保存する。2,000,000 vertices、4,000,000 triangles、Count 256、768 MiB estimateが上限で、初版はMainActor同期である。Grid Array、per-copy transform、selected-face Array、non-destructive modifier、multiple objectは未実装である。詳細は`LINEAR_ARRAY.md`を参照する。

## Radial Array foundation

通常toolbarの`Radial Array`はlocal X/Y/Z軸とlocal originを現在Transformでworld axis/pivotへ写し、Full Circleまたはsigned Open Arcへmesh全体を破壊的に複製する。Full Circleは`±360° / Count`で終点を重複させず、Open Arcは`Sweep / (Count - 1)`で両端を含む。Countはsource copy 0を含む`2...256`である。

Rendererと同じFloat `worldPosition`／`worldDirection`で現在表示中のsource、local-origin pivot、local axisを確定し、その値をDoubleへ変換してideal rotationを計算する。Double inverseからlocal Floatへ格納後、再びFloat `worldPosition`へ通したactual render-space位置でradius、axis projection、signed angle、source／adjacent chord、edge length、world area／windingを検証する。axis専用ULP分類、minimum positive radius、minimum feature chordによりtiny off-axisをglobal toleranceでaxis扱いしない。表示済みsource collapse、表現不能なangle、local exact collinearity、render-space collapse／exact duplicateを拒否する。non-uniform scale下でlocal area一致は要求しない。

Full Circleはhidden Sweep、Open Arcはhidden Directionをcanonical化し、同一geometryのPreview source identityとfingerprintを安定させる。Previewにはworld pivot／axis、axis/off-axis数、radial range、minimum chord、分離したradius／axis／angle toleranceと実測最大errorを表示する。

mandatory PreviewはLinear Arrayと共通のUUID request coordinatorを使い、最新requestだけがUI／model状態を更新する。parameter変更とdismissalはghost Previewを防ぎ、Applyは軽量runtime identityに加えてcomplete estimate／fingerprintを再検証する。prepared/nonthrowing commit、`ReplaceMeshCommand` 1件、record-only Autosave、selection／preview／Diagnostics clear、BVH／Spatial Index再構築、通常Renderer upload、formatVersion 1維持もLinear Arrayと同じである。2,000,000 vertices、4,000,000 triangles、Count 256、768 MiBが上限である。Grid／Spiral／Helix、custom pivot、weld／Boolean、general collision、live modifier、multiple objectは未実装である。詳細は`RADIAL_ARRAY.md`を参照する。

1. iPadOS 17+ の iPad で起動し、球体が表示される。
2. 指操作と Pencil ストロークが競合しない。
3. Pencil hover のブラシ円、筆圧、Draw/Smooth/Grab を確認する。
4. Undo/Redo、Files 経由の保存・再読込、STL のスライサー読込を確認する。
5. Instruments でフレーム時間、入力遅延、メモリを測定する。

## Exact Seam Merge / Split foundation

Face Selectの単一edge-connected regionを、selected側の境界vertexだけ複製して2つのdetached componentへ分離する。source vertex／triangle順、face ID、position、bounds、winding、triangle countを維持し、cap／wall／gapは生成しない。

Split由来のselected component全体と別componentのsingle boundary loopを、`+0`／`-0`だけ正規化したbit-exact local Float positionで一対一対応させて再接続する。counterpart側をsurvivorとしてselected seam duplicateだけを決定論的にcompactする。曖昧pair、同方向winding、non-manifold／duplicate結果はrepairせず拒否する。PreviewはUUID identityと完全plan fingerprintへ結合し、Applyはprepared BVH後の1 install、1 ReplaceMeshCommand、1 Autosaveを使う。詳細は`EXACT_SEAM_MERGE_SPLIT.md`を参照する。
