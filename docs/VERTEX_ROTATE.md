# Selected Vertex Rotation

## Scope

Vertex SelectとRotate Gizmoの組み合わせは、選択頂点だけをworld-space X／Y／Z軸で回転する。自由回転、local軸、snap、数値入力、soft selection、選択頂点scale、topology編集は含まない。

## Pivot and coordinates

Pivotは選択頂点のobject-local AABB中心である。Geometry計算は各`startLocal`から`pivotLocal`を引いたoffsetだけをmodel matrixへ`w=0`で渡し、world vectorへ変換する。既存Rotation Gizmoのunwrapped accumulated angleによるworld X／Y／Z quaternionでvectorを絶対回転し、inverse model matrixへ`w=0`で渡してlocal offsetへ戻した後に`pivotLocal`を加える。absolute per-vertex world positionは保存も使用もしないため、`ObjectTransform.translation`はrotation結果へ影響しない。`pivotWorld`はGizmo interaction専用であり、ObjectTransform自体は変更しない。

## Transaction and preview

`VertexRotateTransaction`はworkspace session、project generation、topology ID／revision／fingerprint、vertex revision、source counts、selection version／count、sorted vertex IDs、開始local位置、local／world pivot、sanitized Transform、world axis、accumulated angleを固定する。pointer update中にselection bitsetを再列挙しない。Preview meshとPreview BVHはcommitted workspaceから分離され、project bytes、history、Autosave、Recovery、STLへ参加しない。

Geometryはabsolute world座標を保存しない。開始local位置からlocal pivotを引き、model matrixへ`w=0`で渡してworld vectorへ変換し、world X／Y／Z quaternionで回転後、inverse model matrixへ`w=0`で渡してlocal offsetへ戻す。最後にlocal pivotを加えるため、ObjectTransform translationが100,000,000 mm規模でもvertex rotation結果はtranslationから独立する。`pivotWorld`はring描画、hit test、drag plane、camera-relative sizingだけに使用する。precision toleranceもabsolute translationではなくlocal／world offsetとrotation radiusを基準にする。

Beginはaxis component、squared length、normalized axisがfiniteであることを要求し、Rotation Gizmoと同じ`0.00001`のminimum length以下を拒否する。zero、tiny、finite componentでもlength計算がoverflowするaxisはtransaction生成前に`invalidAxis`となる。有効なnon-unit axisは一度だけ正規化する。

BeginはVertex Select時にread-only prepared phaseで全fallible処理を完了し、成功後だけSculpt、Transform panel transaction、置換対象の通常Object Rotate dragを解消する。他のGizmo dragは開始を拒否する。通常のObject Rotateは従来どおり既存transactionを確定／cancelしてからsessionを開始する。Commitはcandidate meshとcommitted Picking BVHを準備してからnonthrowing installを行い、semantic `vertexRotate` commandを統合historyへ1件記録する。Preview BVH失敗はpreviewを破棄し、commit BVH失敗は確定meshを変更しないため、次のdragで再試行できる。Cancel／stale／failureは開始hoverを復元し、commitはhoverをclearする。0および整数full-turnはno-opとしてhistory、dirty、Autosaveを変更しない。

## Rendering and limits

Vertex Select＋Rotate時だけRotation Gizmo originをselected pivotへ上書きする。Object RotateはObject origin、Scaleは従来originを使う。Preview／commit／Undo／Redoはvertex bufferだけを更新し、index bufferとselection ID bufferを更新しない。working-memory preflightはCPU source／preview、GPU active／candidate vertex buffers、選択ID、開始local位置とoffset staging、candidate／dictionary staging、Preview BVH、commit BVHを含み、上限は768 MiBである。

Selection rotationはruntime-only状態で、project formatVersion 1、ObjectTransform、topology identity、selection、camera、tool設定を変更しない。
