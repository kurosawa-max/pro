# Foundation Prototype 実装仕様

**Status:** Implemented prototype  
**Target:** iPadOS 17+  
**Xcode target:** `Forge3D`

## 実装された縦切り

- SwiftUI 内に `MTKView` を統合し、UV sphere を Metal で描画する。
- 指1本のドラッグでオービット、指2本でパン、ピンチでズームする。
- 画面レイと全三角形の CPU 交差判定でメッシュ表面をピッキングする。
- Pencil の座標、正規化筆圧、altitude、azimuth、timestamp を `PencilSample` に変換する。
- Draw、Smooth、Grab を固定トポロジーの頂点変形として実行する。
- touchesBegan から touchesEnded までの変更頂点のみを1個の Undo コマンドに保存する。
- `.forge3d` プロジェクトを保存・再読込し、Binary STL を出力する。
- コアロジックを XCTest から検証する。

## Foundation 保存形式 v1

Foundation Prototype の `.forge3d` は UTF-8 JSON であり、次を格納する。

- `formatVersion`（現在値 `1`）
- `mesh.vertices`（position / normal）
- `mesh.indices`
- `camera`（yaw / pitch / distance / target）
- `metadata`

読み込み境界では 128 MiB、200万頂点、1200万インデックスを上限とし、範囲外インデックス、NaN、Infinity、未知の形式版を拒否する。書き出し前にも同じメッシュ検証を行う。

## アーキテクチャ上の位置付け

これは `docs/ARCHITECTURE.md` で規定した最終 ZIP コンテナ形式の代替決定ではない。Foundation 段階の読み書き可能な最小形式であり、ZIP コンテナ、fallback OBJ、アトミック保存、自動復旧への移行が必要である。`ProjectCodec` の境界を維持し、UI と形式実装を分離する。

本プロトタイプのブラシ、ピッキング、隣接探索は CPU の線形処理であり、25万頂点や60 FPSの性能目標を保証しない。BVH、Half-edge、局所法線更新、GPU 部分更新は後続マイルストーンで実装する。

## 実機検証項目

1. iPadOS 17+ の iPad で起動し、球体が表示される。
2. 指操作と Pencil ストロークが競合しない。
3. Pencil hover のブラシ円、筆圧、Draw/Smooth/Grab を確認する。
4. Undo/Redo、Files 経由の保存・再読込、STL のスライサー読込を確認する。
5. Instruments でフレーム時間、入力遅延、メモリを測定する。
