# Dependency Register

## Required platform dependencies

| Dependency | Owner | Purpose | Cost model | Lock-in treatment |
|---|---|---|---|---|
| SwiftUI/UIKit | Apple | UI/input | OS SDK | Presentation層へ限定 |
| Metal/MetalKit | Apple | rendering/GPU | OS SDK | Renderer interfaceで隔離 |
| simd | Apple | vector math | OS SDK | Core型への変換境界を持つ |

## Optional dependencies

| Dependency | Status | License/Cost | Rule |
|---|---|---|---|
| Open CASCADE Technology | Not integrated | LGPL 2.1 + exception / commercial option | 法務・配布条件確認後、KernelAdapterとしてのみ採用可 |

依存を追加するPull Requestでは、ライセンス、更新停止時の対応、置換難易度、ソース保管方法を必須記載する。
