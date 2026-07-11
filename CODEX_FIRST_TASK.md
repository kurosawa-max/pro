# Codex First Task — Foundation Prototype

## Objective

iPadOS向けForge3Dの最小縦切りプロトタイプを作成する。

## Required Outcome

- iPadOSアプリとして起動する
- Metalで球体または細分化メッシュを表示する
- 回転、ズーム、パンができる
- メッシュ表面をピッキングできる
- Apple Pencilの位置、筆圧、傾きを入力モデルへ変換する
- Draw、Smooth、Grabブラシの最小実装を持つ
- 1ストローク単位でUndoできる
- プロジェクトを保存・再読込できる
- Binary STLを出力できる
- 主要ロジックにXCTestがある

## Explicitly Out of Scope

- Dynamic Topology
- Voxel Remesh
- CAD Kernel
- Open CASCADE
- STEP
- Parametric History
- Boolean Operations
- Fillet
- Texture Painting
- Cloud Sync
- Accounts
- Billing
- Paid SDKs

## Mandatory Workflow

1. `AGENTS.md`と設計文書を読む
2. リポジトリを評価する
3. 計画と変更予定ファイルを提示する
4. 最小のビルド可能状態から段階的に実装する
5. テストを作成・実行する
6. 差分を自己レビューする
7. 文書を更新する
8. 実行結果と未解決事項を正直に報告する
