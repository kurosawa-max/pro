# Forge3D for iPad Pro

商用販売を前提とする、iPad Pro向けハイブリッド3Dモデリングアプリの設計・開発リポジトリ。

## 製品の核

- Apple Pencil中心のスカルプト
- ポリゴン／メッシュモデリング
- 寸法付きプリミティブ
- 3Dプリント向け検査と出力
- 用途別モジュール（アクセサリー、レザークラフト、フィギュア等）
- 外部CADカーネルに依存しないプロジェクト形式

## 初期方針

初版では有償CADカーネルを採用しない。自前のメッシュエンジン、スカルプト、操作体系、保存形式を製品資産として構築する。精密B-Rep CADは交換可能な `GeometryKernel` 境界の後ろに追加する。

## 最初の実行目標

球体をMetalで表示し、Apple Pencilで Draw / Smooth / Grab を実行し、Undoとプロジェクト保存ができる縦切りプロトタイプを完成させる。

詳細は `docs/ARCHITECTURE.md` と `docs/ROADMAP.md` を参照。

## Foundation Prototype

`Forge3D.xcodeproj` に iPadOS 17+ 向けの最小縦切りを実装済み。Xcode で `Forge3D` scheme を選択し、iPad Simulator または実機で実行する。

実装範囲、操作、保存形式、既知の性能制限、実機検証項目は `docs/FOUNDATION_PROTOTYPE.md` を参照。

STLは`1 coordinate = 1 mm`としてBinary／ASCIIをimportでき、Binary STL export時だけ非破壊ObjectTransformをbakeする。importのexact weld、安全上限、非対応repairは`docs/STL_IMPORT.md`、exportは`docs/STL_EXPORT.md`を参照。
