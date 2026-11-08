// Depth-aware projected illumination for a single holographic contact.
// Lua scissors each invocation to the contact's small screen-space influence.

sampler WorldPositionTexture : register(s0);

const float4 EyeAndTime      : register(c0); // xyz eye position, w time
const float4 ContactAndRange : register(c1); // xyz contact position, w radius
const float4 TintAndStrength : register(c2); // rgb tint, w intensity
const float4 AxisAndHeight   : register(c3); // xyz table up, w vertical bias
const float2 TexelSize       : register(c4);

struct PS_INPUT {
    float2 pixel : VPOS;
    float2 uv    : TEXCOORD0;
};

float4 main(PS_INPUT input) : COLOR0 {
    float2 uv = (input.pixel + 0.5) * TexelSize;
    float3 packedWorld = tex2D(WorldPositionTexture, uv).rgb;
    if (abs(packedWorld.x) < 0.0000001
        || abs(packedWorld.y) < 0.0000001
        || abs(packedWorld.z) < 0.0000001) discard;
    float3 scenePosition = 1.0 / packedWorld;
    if (abs(scenePosition.x) > 32768.0
        || abs(scenePosition.y) > 32768.0
        || abs(scenePosition.z) > 32768.0) discard;
    float3 rayDirection = normalize(scenePosition - EyeAndTime.xyz);
    float3 normal = cross(ddy(scenePosition), ddx(scenePosition));
    float normalLengthSquared = dot(normal, normal);
    if (normalLengthSquared < 0.000001) discard;
    normal *= rsqrt(normalLengthSquared);
    if (dot(normal, rayDirection) > 0.0) normal = -normal;

    float3 axis = normalize(AxisAndHeight.xyz);
    float3 lightPosition = ContactAndRange.xyz
        + axis * AxisAndHeight.w;
    float3 toLight = lightPosition - scenePosition;
    float distanceToLight = length(toLight);
    float range = max(ContactAndRange.w, 0.01);
    float attenuation = 1.0 - smoothstep(range * 0.18, range,
        distanceToLight);
    attenuation *= attenuation;
    float facing = saturate(dot(normal, toLight
        / max(distanceToLight, 0.001)));

    // Keep the pool centered below the contact instead of illuminating walls
    // and geometry far above it with an ordinary spherical point light.
    float vertical = dot(scenePosition - ContactAndRange.xyz, axis);
    float verticalGate = 1.0 - smoothstep(range * 0.45, range,
        abs(vertical));
    float pulse = 0.92 + 0.08 * sin(EyeAndTime.w * 3.1
        + dot(ContactAndRange.xyz, float3(0.017, 0.013, 0.011)));
    float intensity = attenuation * verticalGate * (0.22 + facing * 0.78)
        * TintAndStrength.w * pulse;
    if (intensity < 0.0005) discard;
    return float4(TintAndStrength.rgb * intensity, intensity);
}
