# Performance Instrumentation

**Status:** Debug-only foundation  
**Sample window:** 60 samples

## Purpose

最適化前のForge3D Foundation Prototypeについて、処理時間とメッシュ規模を同じ基準で観測する。計測結果が得られる前にBVH、局所法線更新、GPU Compute等の採否を決めない。

## Diagnostics boundary

`src/Diagnostics/PerformanceProfiler.swift`に次を集約する。

- `PerformanceMetric`: 計測対象の識別子
- `RollingAverage`: 直近60サンプルのlatest/average
- `PerformanceSample`: 1指標の表示値
- `PerformanceSnapshot`: HUD向けの不変スナップショット
- `PerformanceProfiler`: 時計、記録、frame boundary、mesh counts

Geometry、Sculpt、RendererはProfilerの計測境界を呼ぶが、サンプル保持や表示ロジックを持たない。Profilerはプロジェクト保存モデルへ含めない。

## Metrics

| Metric | Meaning |
|---|---|
| Picking ms | CPU ray/triangle picking 1回 |
| Sculpt ms | `SculptBrush.apply` 1回。内部の法線再計算を含む |
| Normal rebuild ms | 頂点法線の全体再計算1回 |
| Vertex upload ms | Metal vertex buffer確保/再利用とCPU copy |
| Index upload ms | topology変更時のindex buffer確保/再利用とCPU copy |
| Frame ms | 1回のdraw callbackにおけるCPU command encoding時間。GPU完了時間ではない |
| FPS | draw callback間隔の60サンプル平均から算出 |
| Vertices / Triangles | 現在メッシュの要素数 |

## Debug and Release

計時、lock、サンプル保持、frame timestamp取得は`#if DEBUG`内だけに存在する。ReleaseではProfilerを生成せず、`measure`はoperationを直接実行し、HUDもコンパイルされない。`PerformanceProfiler.isInstrumentationCompiled`をDebug/Release双方で静的に検証可能にする。

GitHub ActionsではRelease simulator buildを先に実行し、条件コンパイルされたRelease経路もコンパイル可能であることを確認した後、Debug buildとXCTestを実行する。

## HUD

画面右上の`Perf`ボタンで開閉する。展開時は各時間の`latest / average`、Vertices、Triangles、FPSを表示し、0.5秒周期でSnapshotだけを読み取る。

## Manual benchmark presets

Debugビルドでは画面左上の`Bench`パネルから次のIcosphereへ手動で切り替えられる。

| Preset | Subdivision | Vertices | Triangles |
|---|---:|---:|---:|
| Small | 2 | 162 | 320 |
| Medium | 4 | 2,562 | 5,120 |
| Large | 5 | 10,242 | 20,480 |

切替時は進行中ストロークを取り消し、Undo/RedoとProfiler履歴を消去し、新しいtopology identityとmesh countsを反映する。`Reset Metrics`は現在メッシュ数を維持して時間履歴とframe timestampを消去する。プリセット識別子はDebugランタイムだけに存在し、プロジェクト形式へ保存しない。

このパネルは手動比較用であり、自動入力、レポート出力、固定しきい値、性能合否判定を行わない。Simulatorと実機では結果が異なり、Frame CPU msはGPU完了時間ではない。表示値だけで正式な性能保証や最適化優先順位を断定しない。

## Known overhead

Debug時は各計測区間につき時計取得2回と短いlock、60サンプルの更新が発生する。HUD表示時は0.5秒ごとにSnapshotを作る。メッシュ全体の追加コピー、GPU同期待ち、ファイル保存は行わない。Debug計測値は製品Release性能そのものではない。

## Automated benchmark runner

Debug専用RunnerはSmall／Medium／LargeごとにPicking、Draw、Smooth、Grab、全法線再計算、vertex upload、index uploadを固定入力で順番に実行する。設定はwarm-up 10回、計測60回で一元管理し、warm-up値は結果へ含めない。既存Profilerの計測点を再利用するため同じ処理を二重計測しない。

開始前のmesh、camera、brush設定、選択preset、Undo/Redoを保持し、完了・キャンセルのどちらでも復元する。結果は有限容量のlatest／average／minimum／maximum／sampleCountとして保持し、プレーンテキストまたはJSONをクリップボードへコピーできる。プロジェクト形式やクラウドへは送らない。

これはCPU側比較を補助するDebugツールでありGPU完了時間を計測しない。Simulatorと実機の値は直接同一視できず、Debug値はRelease性能を保証しない。固定しきい値による合否や、実測なしの最適化判断は行わない。

Uploadケースはmesh install前後のmetric別sampleCountをDebug Profilerで確認する。5msの非同期sleepでMainActorを解放しながら、各反復で正確に1サンプル増えるまで最大500ms待つ。timeoutまたはcancel時はreportを成功扱いしない。Index uploadは対象presetと同じsubdivisionから毎回新しいtopology identityのmeshを生成するため、reportの規模と実測対象が一致する。GPU完了待ちは行わない。
