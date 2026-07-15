# STL Export and Millimeter Convention

## Decision

Forge3Dは内部1 unitを1 millimeterと定義する。既存Foundation v1 projectをスケール変換しない。unit fieldも追加せず、保存済み数値をそのままmmと解釈する。これはマイグレーションによる意図しない形状変更を避けるためである。

## Pipeline

1. local meshと非破壊ObjectTransformをsnapshotとして読む。
2. local positionsをmodel matrixでworld positionsへ変換する。
3. As Displayedはtranslationを残す。Center at Originは変換後bounds centerを減算する。
4. 変換後triangleからwindingに従ってnormalを再計算する。non-uniform scaleでも編集用vertex normalに依存しない。
5. 80-byte header、UInt32 triangle count、50-byte recordsをlittle-endianで生成する。

world boundsはrotationを正しく含めるためlocal AABBの8 cornersから再構築する。STLに正式なunit metadataはなく、headerの`Forge3D Binary STL | unit=mm`は参考情報のみである。

## Safety and limits

export前にstructure、indices、finite values、Transform、transformed bounds、scale-relative triangle area、`84 + 50T`のoverflowを検証する。512 MiBを超えるSTLはData確保前に拒否する。この上限は出力Dataとtransformed positionsの同時保持によるiPadのpeak memoryを抑えるためである。

exportは読み取り専用で、mesh、Transform、camera、history、revision、topology identity、Renderer uploadを変更しない。active Sculpt/Gizmo/Transform panel transaction中は曖昧なsnapshotを避けるため開始を拒否する。初版は上限付き同期Data生成であり、大規模exportの非同期化は将来の置換点である。

3MF、OBJ/STEP、STL import、multiple object、print bed配置、repairを同時実装しない。STLより明確なunit metadataを持つ3MFは独立した後続設計とする。
