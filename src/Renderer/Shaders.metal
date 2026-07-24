#include <metal_stdlib>
using namespace metal;

struct MeshVertex { float3 position; float3 normal; };
struct Uniforms { float4x4 viewProjection; float4x4 model; float3x3 normalMatrix; };
struct VertexOut { float4 position [[position]]; float3 normal; float3 worldPosition; };

vertex VertexOut meshVertex(uint id [[vertex_id]], constant MeshVertex *vertices [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    float4 world = uniforms.model * float4(vertices[id].position, 1.0);
    out.position = uniforms.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = normalize(uniforms.normalMatrix * vertices[id].normal);
    return out;
}

fragment float4 meshFragment(VertexOut in [[stage_in]]) {
    float3 light = normalize(float3(-0.4, 0.8, 0.6));
    float diffuse = max(dot(normalize(in.normal), light), 0.0);
    float rim = pow(1.0 - max(abs(normalize(in.normal).z), 0.0), 2.0);
    float3 color = float3(0.12, 0.48, 0.78) * (0.22 + 0.78 * diffuse) + rim * 0.16;
    return float4(color, 1.0);
}

struct FaceSelectionUniforms { float4x4 viewProjection; float4x4 model; };
struct FaceSelectionVertexOut { float4 position [[position]]; };

vertex FaceSelectionVertexOut faceSelectionVertex(
    uint id [[vertex_id]],
    constant MeshVertex *vertices [[buffer(0)]],
    constant FaceSelectionUniforms &uniforms [[buffer(1)]]) {
    FaceSelectionVertexOut out;
    out.position = uniforms.viewProjection * uniforms.model * float4(vertices[id].position, 1.0);
    return out;
}

fragment float4 faceSelectionFragment(FaceSelectionVertexOut in [[stage_in]]) {
    return float4(1.0, 0.56, 0.08, 0.34);
}

struct EdgeSelectionUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float2 viewportSize;
    float thickness;
    float padding;
    float4 color;
};
struct EdgeSelectionVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex EdgeSelectionVertexOut edgeSelectionVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant MeshVertex *vertices [[buffer(0)]],
    constant uint2 *edgePairs [[buffer(1)]],
    constant EdgeSelectionUniforms &uniforms [[buffer(2)]]) {
    uint2 pair = edgePairs[instanceID];
    float4 clipA = uniforms.viewProjection * uniforms.model * float4(vertices[pair.x].position, 1.0);
    float4 clipB = uniforms.viewProjection * uniforms.model * float4(vertices[pair.y].position, 1.0);
    float2 ndcA = clipA.xy / max(clipA.w, 1e-6);
    float2 ndcB = clipB.xy / max(clipB.w, 1e-6);
    float2 pixelDirection = (ndcB - ndcA) * uniforms.viewportSize * 0.5;
    float directionLength = max(length(pixelDirection), 1e-6);
    float2 pixelNormal = float2(-pixelDirection.y, pixelDirection.x) / directionLength;
    float2 ndcOffset = pixelNormal * uniforms.thickness * 2.0 / uniforms.viewportSize;
    const uint endpointPattern[6] = {0, 1, 1, 0, 1, 0};
    const float sidePattern[6] = {-1, -1, 1, -1, 1, 1};
    bool useB = endpointPattern[vertexID] != 0;
    float4 clip = useB ? clipB : clipA;
    clip.xy += ndcOffset * sidePattern[vertexID] * clip.w;
    EdgeSelectionVertexOut out;
    out.position = clip;
    out.color = uniforms.color;
    return out;
}

fragment float4 edgeSelectionFragment(EdgeSelectionVertexOut in [[stage_in]]) {
    return in.color;
}

struct GizmoVertex { float3 position; float4 color; int handle; };
struct GizmoUniforms { float4x4 viewProjection; float3 origin; float scale; int hoverHandle; int activeHandle; };
struct GizmoVertexOut { float4 position [[position]]; float4 color; };

vertex GizmoVertexOut gizmoVertex(uint id [[vertex_id]], constant GizmoVertex *vertices [[buffer(0)]],
                                  constant GizmoUniforms &uniforms [[buffer(1)]]) {
    GizmoVertexOut out;
    GizmoVertex value = vertices[id];
    out.position = uniforms.viewProjection * float4(uniforms.origin + value.position * uniforms.scale, 1.0);
    bool active = value.handle == uniforms.activeHandle;
    bool hovered = value.handle == uniforms.hoverHandle;
    out.color = active ? float4(mix(value.color.rgb, float3(1.0), 0.9), 1.0)
                       : (hovered ? float4(mix(value.color.rgb, float3(1.0), 0.65), 1.0) : value.color);
    return out;
}

fragment float4 gizmoFragment(GizmoVertexOut in [[stage_in]]) { return in.color; }

struct DiagnosticsOverlayVertex { float3 position; float4 color; };
struct DiagnosticsOverlayUniforms { float4x4 viewProjection; float4x4 model; float pointSize; };
struct DiagnosticsOverlayVertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

vertex DiagnosticsOverlayVertexOut diagnosticsOverlayVertex(
    uint id [[vertex_id]],
    constant DiagnosticsOverlayVertex *vertices [[buffer(0)]],
    constant DiagnosticsOverlayUniforms &uniforms [[buffer(1)]]) {
    DiagnosticsOverlayVertexOut out;
    DiagnosticsOverlayVertex value = vertices[id];
    out.position = uniforms.viewProjection * uniforms.model * float4(value.position, 1.0);
    out.color = value.color;
    out.pointSize = uniforms.pointSize;
    return out;
}

fragment float4 diagnosticsOverlayFragment(DiagnosticsOverlayVertexOut in [[stage_in]]) {
    return in.color;
}
