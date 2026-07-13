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

struct GizmoVertex { float3 position; float4 color; int handle; };
struct GizmoUniforms { float4x4 viewProjection; float3 origin; float scale; int hoverHandle; int activeHandle; };
struct GizmoVertexOut { float4 position [[position]]; float4 color; };

vertex GizmoVertexOut gizmoVertex(uint id [[vertex_id]], constant GizmoVertex *vertices [[buffer(0)]],
                                  constant GizmoUniforms &uniforms [[buffer(1)]]) {
    GizmoVertexOut out;
    GizmoVertex value = vertices[id];
    out.position = uniforms.viewProjection * float4(uniforms.origin + value.position * uniforms.scale, 1.0);
    bool highlighted = value.handle == uniforms.activeHandle || value.handle == uniforms.hoverHandle;
    out.color = highlighted ? float4(mix(value.color.rgb, float3(1.0), 0.65), 1.0) : value.color;
    return out;
}

fragment float4 gizmoFragment(GizmoVertexOut in [[stage_in]]) { return in.color; }
