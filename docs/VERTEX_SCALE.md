# Selected Vertex Scale

## Scope

Vertex Selectと既存Scale Gizmoの組み合わせは、選択頂点だけをworld X／Y／Z軸またはuniform factorで拡大・縮小する。local軸、plane handle、negative scale、mirror、pivot crossing、snap、数値入力、soft selection、Face／Edge Scale、topology編集は含まない。

## Pivot and geometry

Pivotはselected vertexのobject-local AABB中心であり、centroidではない。各開始local positionから`pivotLocal`を引き、model matrixへ`w = 0`で渡してworld offsetへ変換する。X／Y／Z handleは対応world componentだけへfactorを適用し、uniform handleは全componentへ同じfactorを適用する。その後inverse model matrixへ`w = 0`で渡し、local offsetへ戻してpivotを加える。

Geometry transactionはabsolute world vertex positionを保持しない。`pivotWorld`はGizmo描画、hit test、drag、camera-relative sizingだけに使用する。このためObject translationが非常に大きくてもcandidate local positionはtranslationから独立する。rotationとnon-uniform ObjectTransform scaleがある場合も、単純なlocal-axis scaleへ置き換えない。

## Factor contract

Factorはdrag開始snapshotに対するabsolute valueである。各previewはimmutableな開始local positionsから再生成する。`1`はsemantic no-op、許容範囲は`0.001...1000`で、zero、negative、NaN、Infinity、範囲外およびfinite candidateを作れない値をGeometryCore境界で拒否する。negative scale、mirror、pivot crossingは未対応である。

## Transaction and atomicity

`VertexScaleTransaction`はworkspace session、project generation、topology ID／revision／fingerprint、vertex revision、source counts、selection version／count、sorted vertex IDs、開始local positions、local／world pivot、sanitized Transform、handleを固定する。pointer update中にselection bitsetを再走査しない。

Preview meshとpreview Picking BVHはcommitted workspaceから分離する。Commitは最終candidate、history command、committed Picking BVHをinstall前に準備し、その後の境界をnonthrowing mutationとして扱う。失敗またはcancelではpreview、preview BVH、transactionだけを破棄し、committed mesh、Transform、selection、history、dirty generation、Autosave、Recoveryを変更しない。working-memory preflightの上限は768 MiBである。

## History, rendering, and persistence

意味のある1 dragをsemantic `vertexScale` command 1件として統合historyへ記録する。Undo／Redoは該当vertex positionsだけを戻し、topology、indices、ObjectTransform、selectionを維持する。Factor 1はhistoryを追加せずRedoも破棄しない。

Preview／commit／Undo／Redoはvertex-only更新である。Rendererはvertex bufferを更新し、index bufferとselected-vertex ID bufferを更新しない。Previewはproject serialization、STL export、Autosave、Recoveryへ含めず、commit済みmeshだけがproject formatVersion 1へ保存される。

## Known limitations

local-axis scale、plane handle、negative／mirror scale、custom pivot、snapping、numeric entry、soft selection、individual origins、Face／Edge Scale、multiple object、collision／self-intersection correction、persisted live transactionは未実装である。
