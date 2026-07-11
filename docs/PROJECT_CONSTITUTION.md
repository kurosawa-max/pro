# Forge3D Project Constitution

**Version:** 1.0  
**Status:** Active  
**Document Type:** Project Constitution (Highest Authority)

## 1. Purpose

Forge3Dは、Apple Pencilを中心とした次世代3Dモデリングプラットフォームを構築することを目的とする。

Forge3Dは単なる3Dモデラーではない。長期的には以下を統合する。

- Polygon Modeling
- Sculpting
- Parametric Modeling
- CAD
- 3D Printing
- Product Design
- Jewelry Design
- Leather Craft Design
- Figure Modeling
- Mechanical Design
- Educational Modeling

Forge3Dは短期的な完成を目的としない。10年以上継続的に進化するプラットフォームを構築する。

## 2. Mission

Forge3Dの使命は、**世界最高水準のiPad向け3D制作環境を提供すること**である。

そのために、直感的操作、高精度、高速性、拡張性、保守性を同時に追求する。

## 3. Vision

Forge3Dは、初心者でも使え、プロフェッショナルでも妥協しない、iPad向け統合3D制作環境になることを目標とする。

## 4. Core Values

### 4.1 User First
ユーザー体験を最優先する。

### 4.2 Apple Pencil First
Apple Pencilを第一入力デバイスとして設計する。

### 4.3 Offline First
主要機能はインターネット接続なしで利用できること。

### 4.4 Performance First
速度は品質である。遅い実装を放置しない。

### 4.5 Quality over Quantity
機能数ではなく品質で評価する。

### 4.6 Long-term Maintainability
短期実装より10年後の保守性を優先する。

### 4.7 Data Ownership
ユーザー作品はユーザーの資産である。

### 4.8 Open Architecture
将来の拡張を妨げない設計を行う。

## 5. Design Principles

### 5.1 Architecture before Features
新機能追加より設計品質を優先する。

### 5.2 Simplicity
必要以上に複雑な設計は禁止する。

### 5.3 Separation of Concerns
責務を明確に分離する。

### 5.4 Replaceability
重要コンポーネントは交換可能であること。

### 5.5 Testability
テストできない設計を避ける。

### 5.6 Deterministic Behavior
同じ入力から同じ結果が得られること。

## 6. Non-Goals

初期バージョンでは以下を目標としない。

- ゲームエンジン
- DCC全部入りソフト
- クラウド依存アプリ
- AI自動生成を中核とするアプリ
- 映像制作ソフト

## 7. Dependency Policy

外部依存は最小限とする。外部ライブラリの採用には、以下を必須とする。

- 商用利用条件が明確である
- 継続的なライセンス料を必須としない
- 長期保守の見込みがある
- ソースまたは十分な技術仕様を確認できる
- 独自境界を介して将来置換できる
- 採用理由と代替案をADRへ記録する

Apple標準フレームワークは、プラットフォーム基盤として積極的に採用する。有料SDK、月額SDK、停止すれば主要編集機能が失われるクラウドAPIを必須依存にしてはならない。

## 8. Architecture Rules

必須の論理モジュールは以下とする。

- App
- UI
- Input
- Renderer
- GeometryCore
- SculptCore
- ModelingCore
- FileIO
- Undo
- Export
- Import
- Tests

以下を厳守する。

- 循環依存を禁止する
- RendererはGeometryを変更しない
- GeometryCoreはUIを参照しない
- SculptCoreはRendererや画面部品を参照しない
- FileIOはUIを参照しない
- UIは低レベルMetal実装を直接操作しない
- モジュール間の通信は明示的なインターフェースを介する

## 9. Technology Policy

初期の標準技術構成を以下とする。

- UI: SwiftUI
- Input: UIKit併用
- Rendering: Metal / MetalKit
- GPU Compute: Metal Compute
- Core Logic: Swift
- Performance-Critical Logic: C++
- Swift/C++ Bridge: Objective-C++
- Testing: XCTest

新言語や新基盤の導入には、明確な利点、移行費用、保守性、ライセンス、代替案を記載したADRを必要とする。

## 10. Geometry Policy

Forge3Dは以下を独立したエンジン領域として扱う。

- Polygon Engine
- Sculpt Engine
- Parametric Engine
- CAD Engine

これらは相互の内部実装へ直接依存してはならない。変換や連携は明示的な中間表現またはアダプターを介する。

CADエンジンを外部実装で補う場合も、製品データ、UI、スカルプト機能をその実装へ密結合させてはならない。

## 11. File Format Policy

Forge3Dはバージョン付き独自プロジェクト形式を採用する。

最低限、以下を保存可能とする。

- ファイル形式バージョン
- シーン情報
- メッシュ
- カメラ
- モデリング情報
- スカルプト情報
- マテリアル情報
- メタデータ
- 復旧用フォールバックメッシュ

主要な交換形式との相互運用を重視する。

- STL
- OBJ
- 3MF
- USDZ
- 将来的なSTEP等

独自形式だけにユーザーデータを閉じ込めてはならない。

## 12. Performance Targets

目標値は測定条件と対象端末を明記して管理する。

初期目標:

- 通常操作: 60 FPSを維持
- 対応端末: 120 FPSを目標
- Pencil入力から表示更新: 16 ms以内を目標
- 通常のUndo: 1秒以内
- 一般的なプロジェクト保存: 5秒以内
- 通常起動: 3秒以内を目標

目標を満たせない実装は、計測結果と改善計画を記録する。

## 13. Memory Policy

- 不要な全体コピーを避ける
- 巨大オブジェクトの暗黙的複製を禁止する
- Undoは原則として差分保存する
- GPU/CPU間転送量を計測する
- メモリ上限を超えた際はクラッシュより安全な劣化を選ぶ

## 14. Error Handling and Recovery

- クラッシュより安全な失敗を選択する
- 書き込みは可能な限りアトミックに行う
- 自動保存と復旧を考慮する
- 破損ファイルを無条件に読み込まない
- 開発者向け情報とユーザー向け表示を分離する
- 回復不能な操作は実行前に明示する

## 15. Security and Privacy

- ユーザー作品を無断送信しない
- クラウド機能は明示的な同意を必要とする
- 個人情報は必要最小限のみ扱う
- 外部通信の目的を明示する
- 主要編集機能はアカウントなしでも利用可能であることを基本とする

## 16. AI Development Policy

AIは開発チームの一員として扱うが、設計権限を無制限に与えない。

AIは以下を遵守する。

- Constitutionを最優先する
- 作業前に関連文書を読む
- 指定された作業範囲を守る
- 設計を独断で変更しない
- 重要な変更はADRを提案する
- テストを追加・更新する
- 実装と文書を一致させる
- 不明点を隠さず、仮定を明示する
- 実行していないビルドやテストを成功と報告しない
- 無関係なリファクタリングを混ぜない

## 17. Coding Standards

必須原則:

- Single Responsibility
- High Cohesion
- Low Coupling
- Readable Code
- Testable Code
- 明示的な所有権とライフサイクル
- 境界での入力検証

禁止事項:

- God Class / God Object
- 根拠のない巨大関数
- 意味不明なMagic Number
- Copy-and-Paste Programmingの放置
- Hidden Global Mutable State
- エラーの握り潰し
- 説明のない一時しのぎ

## 18. Documentation Policy

設計変更時はコードと同時に関連文書を更新する。

対象:

- Project Constitution
- Product Vision
- Requirements
- Architecture
- ADR
- Roadmap
- Module Specifications
- File Format Specifications

文書と実装が矛盾する場合、作業は未完了とする。

## 19. Architecture Decision Records

重要な設計判断はADRとして記録する。

ADRには最低限以下を含める。

- Context / Problem
- Decision
- Alternatives Considered
- Rationale
- Consequences
- Risks
- Migration or Reversal Strategy
- Status

## 20. Testing Policy

Definition of Doneにはテストを含む。

必要に応じて以下を使用する。

- Unit Tests
- Integration Tests
- Serialization Tests
- Geometry Invariant Tests
- Performance Tests
- Regression Tests
- Golden File Tests
- Device Tests

浮動小数点計算では、厳密一致ではなく妥当な許容誤差と不変条件を定義する。

## 21. Backward Compatibility

- 可能な限り旧プロジェクトを開けるようにする
- ファイル形式はバージョンを持つ
- 互換性を破る場合はマイグレーション手段を提供する
- マイグレーション不能な場合は、可能な限りフォールバックメッシュを救出する
- 保存形式の変更にはテスト用旧形式サンプルを保持する

## 22. Definition of Done

機能完成とは、以下を満たした状態を指す。

- 実装が要求範囲を満たす
- 対象環境でビルドできる
- 必要なテストが成功する
- コードレビューが完了する
- 関連文書が更新される
- 性能とメモリへの影響が確認される
- 既知の制限と技術的負債が記録される
- ユーザーデータを破損させる重大な問題がない

## 23. Project Governance

文書の優先順位を以下とする。

1. Project Constitution
2. 承認済みADR
3. Product Vision / Requirements
4. Software Architecture
5. Module Specifications
6. Source Code
7. 一時的なタスク指示

下位の文書と実装は上位規則に反してはならない。矛盾を発見した場合は隠さず報告し、修正する。

## 24. Change Management

Constitutionの変更は例外的に行う。

変更には以下を必要とする。

- 変更理由
- 影響範囲
- 既存設計との矛盾
- リスク
- 移行方法
- 長期的影響
- バージョン更新

単なる実装都合でConstitutionを弱めてはならない。

## 25. Success Criteria

Forge3Dは以下で評価する。

- 操作性
- 安定性
- パフォーマンス
- 保守性
- 拡張性
- データの安全性
- コード品質
- 実際に作品を完成させられるか

機能数だけでは評価しない。

## 26. Long-Term Commitment

Forge3Dは短期間で完成するソフトウェアではない。数年から十年以上にわたり成長し続けるプラットフォームとして設計する。

すべての実装者およびAIは、短期的な実装速度だけを理由に、長期的な品質、保守性、データ安全性、交換可能性を犠牲にしてはならない。

本ConstitutionはForge3Dプロジェクトにおける最高位の規則であり、すべての設計、実装、レビュー、テスト、運用はこれに従う。
