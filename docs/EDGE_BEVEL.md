# Edge Bevel

Edge Bevelは、Edge Selectionで選択した互いに頂点を共有しないmanifold interior edgeを、1 segmentのlinear chamferへ置換する破壊的topology editである。幅は表示中のFloat render-space geometryからworld-space millimeterで計算し、ObjectTransformはmeshへ焼き込まず維持する。

## 対応範囲

選択edgeはvertex-disjointで、affected one-ringも相互に接触してはならない。各edgeは向きが逆の2 incident face、valence 4以上でboundaryに触れない単一manifold endpoint fan、4本のside edgeごとに異なるsupport faceを持つ必要がある。6 affected facesは全て異なり、support faceはsplit対象side edgeを1本だけ含む。tetrahedronのvalence-3 endpointやsupport face重複はcorner miterが必要なため拒否する。boundary、non-manifold、bow-tie、coplanar／near-coplanar、隣接chain／cycleもmutation前に拒否する。幅は`0.001...1000 mm`で、2 incident triangleのworld-space altitudeから安全上限を求め、上限以上を自動clampせず拒否する。

## 決定論的topology

edge ID昇順に、`low/face0`、`high/face0`、`low/face1`、`high/face1`の4頂点を追加する。元incident face slotは、元index順を保ったtrimmed triangleへ置換する。4本のside edgeに接するsupport faceはsource windingのdirected edgeへoffset vertexを挿入し、第1 childを元face slotへ、第2 childをappendする。そのpartial topologyからsource low、4 offsets、source highで構成されるsimple six-edge cavityを実測し、boundary useと逆向きになるstrip 2 trianglesとendpoint cap 2 trianglesで閉じる。

閉じた三角形2-manifoldでcomponentとboundaryを維持するにはEuler関係と`3F = 2E`から`ΔF = 2ΔV`が必要である。このため、1 edgeあたりの結果は`V + 4`、`T + 8`となる。4 support split childrenを省いた`T + 4`構成はincident faceとの間にcrackを残すため採用しない。

生成後はnormal、adjacency、Diagnosticsを再構築し、component／boundary不変、non-manifold／winding conflict／degenerate／duplicateが0であることをcommit前に検証する。一般collisionとself-intersectionは検出しない。

## Previewとcommit

PreviewはUUID request identityを使用し、width、selection、mesh、Transform、dismissalでstale化する。Applyはruntime identityを軽量確認した後、estimateとanalysis fingerprintを再計算して一致を要求する。result mesh、Workspace snapshot、Picking BVHまでをfallible prepared phaseで完成させ、nonthrowing commitでfresh topologyを1回installし、`ReplaceMeshCommand` 1件を記録する。

Preview、Cancel、failureはproject、history、dirty、Autosave、Recoveryを変更しない。Apply／Undo／Redoはそれぞれgenerationを1回進め、完成meshだけをformatVersion 1へ保存する。selectionとPreviewは永続化・Undo対象ではない。

## 制限

初版はMainActor同期、1 segment固定である。adjacent edge bevel、chain／cycle、valence-3 endpoint miter、general corner miter、multiple segments、miter/profile、boundary bevel、collision repair、multiple objectは未実装である。上限は2,000,000 vertices、4,000,000 triangles、保守的working set 768 MiBである。
