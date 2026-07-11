# Forge3D AI Development Instructions

このリポジトリで作業するすべてのAIエージェントは、最初に以下を読むこと。

1. `docs/PROJECT_CONSTITUTION.md`
2. `README.md`
3. `docs/ARCHITECTURE.md`
4. `docs/ROADMAP.md`
5. 関連ADR
6. 担当モジュールの仕様書

## 最優先ルール

- Project Constitutionは最高位規則である。
- 設計を独断で変更しない。
- 作業範囲外の大規模変更を混ぜない。
- 外部依存を無断で追加しない。
- ビルドやテストを実行していない場合、成功したと報告しない。
- 変更した設計とドキュメントを一致させる。
- 重要な判断はADRとして提案する。
- ユーザーデータの安全性を性能や実装速度より優先する。

## 作業開始時

以下を簡潔に提示してから実装する。

- Repository Assessment
- Implementation Plan
- Files to Change
- Test Plan
- Risks and Assumptions

重大な障害がない限り、合理的な仮定を明記して作業を進める。

## 作業完了時

以下を報告する。

- Completed
- Architecture Impact
- Files Changed
- Tests and Build Results
- Known Limitations
- Technical Debt
- Documentation Updated
- Next Recommended Task（1件のみ）
