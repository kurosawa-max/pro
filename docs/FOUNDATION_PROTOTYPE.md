# Foundation Prototype 実装仕様

**Status:** Implemented prototype  
**Target:** iPadOS 17+  
**Xcode target:** `Forge3D`

## 実装された縦切り

- SwiftUI 内に `MTKView` を統合し、weld済みIcosphereを Metal で描画する。
- 指1本のドラッグでオービット、指2本でパン、ピンチでズームする。
- 画面レイと全三角形の CPU 交差判定でメッシュ表面をピッキングする。
- Pencil の座標、正規化筆圧、altitude、azimuth、timestamp を `PencilSample` に変換する。
- Draw、Smooth、Grab を固定トポロジーの頂点変形として実行する。
- touchesBegan から touchesEnded までの変更頂点のみを1個の Undo コマンドに保存する。
- Pencilキャンセル時は進行中ストロークを破棄し、カメラジェスチャーは指入力だけを受け付ける。
- `.forge3d` プロジェクトを保存・再読込し、Binary STL を出力する。
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

現段階ではTransformのUndo/Redo、3D gizmo、複数object、pivot、snap、STLへのTransform bakeを実装しない。STLは従来どおりlocal meshを出力する。

## 実機検証項目

1. iPadOS 17+ の iPad で起動し、球体が表示される。
2. 指操作と Pencil ストロークが競合しない。
3. Pencil hover のブラシ円、筆圧、Draw/Smooth/Grab を確認する。
4. Undo/Redo、Files 経由の保存・再読込、STL のスライサー読込を確認する。
5. Instruments でフレーム時間、入力遅延、メモリを測定する。
