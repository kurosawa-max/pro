# Forge3D 開発ロードマップ v0.1

## Foundation Prototype status — 2026-07-10

Swift ベースの縦切りとして、iPadOS Xcode target、Metal 球体表示、カメラ操作、CPU picking、Pencil 入力モデル、Draw/Smooth/Grab、ストローク単位 Undo/Redo、Foundation v1 保存、Binary STL、XCTest を実装した。

この実装は各マイルストーンの製品品質完了を意味しない。特に C++ bridge、Half-edge、BVH、GPU/局所更新、ZIP project container、fallback mesh、autosave/recovery、実機性能測定、CI は未完了である。

2026-07-11のreview blocker修正で、weld済みIcosphere、adjacency cache、mesh revision駆動GPU同期、重心Picking、入力分離、macOS CI定義を追加した。CI定義の追加はMilestone 0完了を意味せず、実際のXcode結果とC++ bridgeは引き続き未完了である。

同日の性能計測基盤ではDebug専用の60サンプルProfilerと開閉式HUDを追加する。測定前にBVH、局所法線更新、GPU Computeの優先順位は確定しない。

手動Benchmark scenarioとしてSmall/Medium/LargeのIcosphere切替とMetrics resetを追加する。これは比較条件を揃えるためのDebugツールであり、自動ベンチマーク、性能保証、最適化実装は含まない。Simulator値と実機値は分けて扱う。

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

- `.forge3d`形式
- 自動保存
- 復旧
- STL出力
- OBJ入出力
- サムネイル

終了条件: 実作品を保存し、外部スライサーへ渡せる。

## Milestone 5 — Modeling Tools

- Move/Rotate/Scale
- Face/Edge/Vertex selection
- Extrude
- Inset
- Basic bevel
- Mirror
- Array
- Merge/Split

## Milestone 6 — Sculpt Production Features

- Flatten
- Crease
- Pinch
- Mask
- Manual subdivision
- Sculpt layers
- Alpha/stamp brush
- 高密度メッシュ最適化

## Milestone 7 — Remesh and Print Prep

- Voxel representation research
- Voxel remesh
- Mesh repair
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
