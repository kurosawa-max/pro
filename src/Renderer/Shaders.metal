#include <metal_stdlib>
using namespace metal;

struct MeshVertex { float3 position; float3 normal; };
struct Uniforms { float4x4 viewProjection; float4x4 model; };
struct VertexOut { float4 position [[position]]; float3 normal; float3 worldPosition; };

vertex VertexOut meshVertex(uint id [[vertex_id]], constant MeshVertex *vertices [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    float4 world = uniforms.model * float4(vertices[id].position, 1.0);
    out.position = uniforms.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = normalize((uniforms.model * float4(vertices[id].normal, 0.0)).xyz);
    return out;
}

fragment float4 meshFragment(VertexOut in [[stage_in]]) {
    float3 light = normalize(float3(-0.4, 0.8, 0.6));
    float diffuse = max(dot(normalize(in.normal), light), 0.0);
    float rim = pow(1.0 - max(abs(normalize(in.normal).z), 0.0), 2.0);
    float3 color = float3(0.12, 0.48, 0.78) * (0.22 + 0.78 * diffuse) + rim * 0.16;
    return float4(color, 1.0);
}
