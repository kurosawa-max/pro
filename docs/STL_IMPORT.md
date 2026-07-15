# STL Import

## Scope and units

Forge3DはBinary STLとASCII STLを単一objectの`EditableMesh`として読み込む。STLには信頼できるunit metadataがないため、すべての座標を変換せずmillimeterとして解釈する（`1 STL coordinate = 1 Forge3D unit = 1 mm`）。header、solid名、facet normalから単位を推測せず、既存project値も自動変換しない。

## Format detection and parsing

Binary判定は80-byte headerの文字列ではなく、offset 80のlittle-endian triangle countから求めた`84 + 50T`と実ファイル長の厳密一致を優先する。このため`solid`で始まるBinary STLもBinaryとして扱う。一致しない場合だけUTF-8 ASCII STLとして、`solid`、`facet normal`、`outer loop`、3個の`vertex`、`endloop`、`endfacet`、`endsolid`を行単位の有限状態機械で解析する。ASCIIは空白、tab、CRLF/LF、keyword case、scientific notationを許容するが、grammar外のtoken、欠損record、過長行、NaN、Infinityを拒否する。

Binary attribute byte countとsource facet normalは読み飛ばす。windingは入力index順を保持し、normalはweld後のtriangleから面積加重で再構築する。自動的なwinding反転、hole fill、mesh repairは行わない。

## Exact weld and validation

STLのtriangle soupはpositionのFloat bit patternが完全一致する頂点だけを共有する。`-0.0`は`+0.0`へ正規化するが、epsilon weldは行わないため、近接していても異なるbit patternの頂点は別頂点のままである。最初に現れたpositionとtriangle windingを決定論的に保持する。

importは次をinstall前に検証する。

- 全positionがfinite
- index範囲とtriangle構造が有効
- scale-aware epsilonを超える非縮退triangle
- 頂点集合が同じduplicate triangleがない（winding差もduplicate）
- 1 edgeを共有するtriangleが2個以下（boundary edgeとclosed manifoldは許可）
- 再計算normalがfiniteかつunit length
- adjacency cacheを構築可能

失敗時はWorkspaceを変更しない。repairが必要なfileは外部toolで修復してから再importする。

## Limits and memory

- source file: 256 MiB
- source triangles: 1,000,000
- welded vertices: 500,000
- ASCII line: 4,096 UTF-8 bytes

`STLImportEstimate`はsource、triangleごとのposition/index一時領域、上限付きwelded vertex/dictionary概算を合算する。初版は上限付き同期parseであり、大きなfileではsheet表示までUIが一時停止する可能性がある。streaming parse、progress、cancel、peak-memory実測は後続課題である。

概算はparse buffer、positions/indices、weld dictionary、EditableMesh、Undo snapshot、adjacency、BVH、Spatial Index、Metal buffersを含み、768 MiBを超える作業集合は配列生成前に拒否する。これはOSの正確なpeak-memory予測ではなく、明らかに危険な入力を早期拒否する保守的な上限である。

## Workspace transaction

Files UIで`.stl`を選ぶと、format、triangle数、weld後vertex数、mm寸法、file size、unit警告を確認してからinstallする。installはactive Sculptをcancelし、active Gizmo dragをcancelし、Transform panel transactionをcommitした後、identity `ObjectTransform`とauto-framed cameraで新しいmeshを置く。Brush、Brush settings、symmetry、Gizmo mode、Gizmo表示設定は維持する。

置換は`ReplaceMeshCommand`一件として統合historyに記録し、Undoで直前のmesh／Transform／camera、Redoでimport結果を復元する。import meshは新規runtime topology ID、adjacency、Picking BVH／Sculpt spatial index／Renderer bufferの通常の再構築経路を使う。project formatVersion 1には通常のmeshとして保存され、STL filename、format、unit optionなどのimport metadataは保存しない。再度Binary STLへexportできる。

## Non-goals

STL unit auto-detection、repair、winding correction、epsilon weld、multiple object、STL scene hierarchy、color/material、STL import metadata永続化、OBJ／3MF／STEP importは含まない。
