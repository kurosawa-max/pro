# Selected Vertex Rotation

## Scope

Vertex SelectとRotate Gizmoの組み合わせは、選択頂点だけをworld-space X／Y／Z軸で回転する。自由回転、local軸、snap、数値入力、soft selection、選択頂点scale、topology編集は含まない。

## Pivot and coordinates

Pivotは選択頂点のobject-local AABB中心を現在の`ObjectTransform`でworldへ変換した点である。各開始local positionをworldへ変換し、既存Rotation Gizmoのunwrapped accumulated angleによるworld quaternionをpivot中心に絶対適用する。結果はinverse model matrixでlocalへ戻して`Float`として保存する。保存値を再度worldへ変換したrender-space位置が理想位置とscale-relative tolerance内で一致しない場合はmutation前に拒否する。ObjectTransformは変更しない。

## Transaction and preview

`VertexRotateTransaction`はworkspace session、project generation、topology ID／revision／fingerprint、vertex revision、source counts、selection version／count、sorted vertex IDs、開始local／world位置、pivot、sanitized Transform、world axis、accumulated angleを固定する。pointer update中にselection bitsetを再列挙しない。Preview meshとPreview BVHはcommitted workspaceから分離され、project bytes、history、Autosave、Recovery、STLへ参加しない。

Beginはread-only prepared phaseで全fallible処理を完了し、成功後だけSculpt、Transform panel transaction、置換対象の通常Object Rotate dragを解消する。他のGizmo dragは開始を拒否する。Commitはcandidate meshとcommitted Picking BVHを準備してから非throwing installを行い、semantic `vertexRotate` commandを統合historyへ1件記録する。Cancel／stale／failureは開始hoverを復元し、commitはhoverをclearする。no-opはhistoryを作らない。

## Rendering and limits

Vertex Select＋Rotate時だけRotation Gizmo originをselected pivotへ上書きする。Object RotateはObject origin、Scaleは従来originを使う。Preview／commit／Undo／Redoはvertex bufferだけを更新し、index bufferとselection ID bufferを更新しない。working-memory preflightはCPU source／preview、GPU active／candidate vertex buffers、選択ID、開始local／world、candidate／dictionary staging、Preview BVH、commit BVHを含み、上限は768 MiBである。

Selection rotationはruntime-only状態で、project formatVersion 1、ObjectTransform、topology identity、selection、camera、tool設定を変更しない。
