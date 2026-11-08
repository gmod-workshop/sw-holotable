// Depth-aware projector volume for the optional GShader path.
// GShader stores reciprocal world position in _rt_WPDepth.rgb.

sampler WorldPositionTexture : register(s0);

const float4 EyeAndTime       : register(c0); // xyz eye position, w time
const float4 BaseAndStrength  : register(c1); // xyz projector base, w intensity
const float4 AxisAndSoftness  : register(c2); // xyz table up, w edge softness
const float4 TintAndRadius    : register(c3); // rgb linear tint, w base radius
const float2 TexelSize        : register(c4);
static const float PROJECTOR_HEIGHT = 58.0;

struct PS_INPUT
{
    float2 pixel : VPOS;
    float2 uv    : TEXCOORD0;
};

float hash31(float3 p)
{
    p = frac(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return frac((p.x + p.y) * p.z);
}

float4 main(PS_INPUT input) : COLOR0
{
    float2 uv = (input.pixel + 0.5) * TexelSize;
    float3 packedWorld = tex2D(WorldPositionTexture, uv).rgb;
    float3 scenePosition = 1.0 / packedWorld;

    float3 rayVector = scenePosition - EyeAndTime.xyz;
    float sceneDistance = length(rayVector);
    float3 rayDirection = rayVector / max(sceneDistance, 0.001);
    sceneDistance = min(sceneDistance, 32768.0);

    float3 axis = normalize(AxisAndSoftness.xyz);
    float coneSoftness = saturate(AxisAndSoftness.w);
    float3 basisReference = abs(axis.z) < 0.9
        ? float3(0, 0, 1) : float3(0, 1, 0);
    float3 basisX = normalize(cross(basisReference, axis));
    float3 basisY = cross(axis, basisX);
    float3 localEye = EyeAndTime.xyz - BaseAndStrength.xyz;
    float eyeHeight = dot(localEye, axis);
    float rayHeight = dot(rayDirection, axis);

    float pulse = 0.92 + 0.08 * sin(EyeAndTime.w * 3.1);

    // Light the opaque table/rim around the closest point on the emitter ring.
    // Reconstructing a screen-space normal keeps this compatible with every
    // GShader normal-buffer format while still responding to real geometry.
    float3 surfaceOffset = scenePosition - BaseAndStrength.xyz;
    float surfaceHeight = dot(surfaceOffset, axis);
    float3 surfaceRadial = surfaceOffset - axis * surfaceHeight;
    float surfaceRadius = length(surfaceRadial);
    float3 surfaceRadialDirection = surfaceRadial / max(surfaceRadius, 0.001);
    float ringRadius = TintAndRadius.w;
    float radialDistanceToRing = ringRadius - surfaceRadius;
    float emitterDistance = sqrt(radialDistanceToRing * radialDistanceToRing
        + surfaceHeight * surfaceHeight);
    float3 towardEmitter = surfaceRadialDirection * radialDistanceToRing
        - axis * surfaceHeight;

    float3 surfaceNormal = normalize(cross(ddy(scenePosition), ddx(scenePosition)));
    if (dot(surfaceNormal, rayDirection) > 0.0) surfaceNormal = -surfaceNormal;
    float facingEmitter = saturate(dot(surfaceNormal,
        towardEmitter / max(emitterDistance, 0.001)));

    float emitterX = dot(surfaceRadialDirection, basisX);
    float emitterY = dot(surfaceRadialDirection, basisY);
    float emitterWave = abs(4.0 * emitterX * emitterY
        * (emitterX * emitterX - emitterY * emitterY));
    float emitterSegment = pow(saturate(emitterWave), 6.0);
    float emitterPulse = 0.78 + 0.22
        * sin(EyeAndTime.w * 2.3 + emitterX * 2.7 + emitterY * 4.1);
    float spillHeightFade = 1.0 - smoothstep(22.0, 42.0, abs(surfaceHeight));
    float spill = exp(-emitterDistance * 0.085) * spillHeightFade
        * (0.32 + facingEmitter * 0.68)
        * (0.34 + emitterSegment * 0.66) * emitterPulse
        * BaseAndStrength.w * pulse * 1.65;

    // Intersect a cylinder that tightly bounds the tapered projector volume.
    // Samples below perform the exact soft-cone test. This avoids an expensive
    // distance-field march while remaining independent of the camera angle.
    float3 radialEye = localEye - axis * eyeHeight;
    float3 radialRay = rayDirection - axis * rayHeight;
    float cylinderA = dot(radialRay, radialRay);
    float cylinderB = 2.0 * dot(radialEye, radialRay);
    float volumeBoundRadius = TintAndRadius.w * 1.22;
    float cylinderC = dot(radialEye, radialEye)
        - volumeBoundRadius * volumeBoundRadius;

    float radialNear = -65536.0;
    float radialFar = 65536.0;
    float volumeValid = 1.0;
    if (cylinderA > 0.00001)
    {
        float discriminant = cylinderB * cylinderB
            - 4.0 * cylinderA * cylinderC;
        if (discriminant > 0.0)
        {
            float root = sqrt(discriminant);
            float inverseDenominator = 0.5 / cylinderA;
            radialNear = (-cylinderB - root) * inverseDenominator;
            radialFar = (-cylinderB + root) * inverseDenominator;
        }
        else
        {
            volumeValid = 0.0;
        }
    }
    else if (cylinderC > 0.0)
    {
        volumeValid = 0.0;
    }

    float heightNear = -65536.0;
    float heightFar = 65536.0;
    if (abs(rayHeight) > 0.00001)
    {
        float h0 = -eyeHeight / rayHeight;
        float h1 = (PROJECTOR_HEIGHT - eyeHeight) / rayHeight;
        heightNear = min(h0, h1);
        heightFar = max(h0, h1);
    }
    else if (eyeHeight < 0.0 || eyeHeight > PROJECTOR_HEIGHT)
    {
        volumeValid = 0.0;
    }

    float segmentStart = max(0.0, max(radialNear, heightNear));
    float segmentEnd = min(sceneDistance, min(radialFar, heightFar));
    float segmentLength = max(0.0, segmentEnd - segmentStart);
    volumeValid *= step(0.001, segmentLength);

    float density = 0.0;
    float interruptionTime = EyeAndTime.w * 0.62;
    float interruptionCell = floor(interruptionTime);
    float interruptionPhase = frac(interruptionTime);
    float interruptionGate = step(0.86, hash31(
        BaseAndStrength.xyz * 0.017 + interruptionCell));
    float interruptionEnvelope = interruptionGate
        * (1.0 - smoothstep(0.0, 0.12, interruptionPhase));
    float interruptionHeight = 0.12 + 0.72 * hash31(float3(
        interruptionCell, BaseAndStrength.x * 0.01,
        BaseAndStrength.y * 0.01));
    pulse *= 1.0 - interruptionEnvelope * 0.08;

    [unroll]
    for (int sampleIndex = 0; sampleIndex < 6; ++sampleIndex)
    {
        float sampleFraction = (sampleIndex + 0.5) / 6.0;
        float distanceAlongRay = segmentStart + segmentLength * sampleFraction;
        float3 samplePosition = localEye + rayDirection * distanceAlongRay;
        float sampleHeight = dot(samplePosition, axis);
        float heightFraction = saturate(sampleHeight / PROJECTOR_HEIGHT);
        float3 radialPosition = samplePosition - axis * sampleHeight;

        // The adjustable radius is shared by the physical emitter and cone
        // base; the light then expands outward above that exact ring.
        float radialLength = length(radialPosition);
        float sampleRadius = TintAndRadius.w * lerp(1.0, 1.22, heightFraction);
        float radiusFraction = radialLength / sampleRadius;
        float edgeWidth = lerp(0.055, 0.32, coneSoftness);
        float inside = 1.0 - smoothstep(1.0 - edgeWidth, 1.0, radiusFraction);

        float lowerFade = smoothstep(0.0, 0.055, heightFraction);
        float upperFade = 1.0 - smoothstep(0.76, 1.0, heightFraction);
        float verticalFade = lowerFade * upperFade;

        float softCore = 0.022 + 0.032
            * pow(saturate(1.0 - radiusFraction), 2.0);
        float coneEdge = smoothstep(0.62, 0.84, radiusFraction)
            * (1.0 - smoothstep(0.84, 1.0, radiusFraction));
        float coneEdgeStrength = lerp(0.1, 0.012, coneSoftness);

        // A narrow source glow close to the physical inner rim. It is part of
        // the volume itself, so it has no billboard or beam silhouette.
        float sourceRing = exp(-sampleHeight * 0.19)
            * (1.0 - smoothstep(1.5, 7.0,
                abs(radialLength - TintAndRadius.w)));

        float safeRadialLength = max(radialLength, 0.001);
        float sampleX = dot(radialPosition, basisX) / safeRadialLength;
        float sampleY = dot(radialPosition, basisY) / safeRadialLength;
        float segmentWave = abs(4.0 * sampleX * sampleY
            * (sampleX * sampleX - sampleY * sampleY));
        float segmentedEmitter = 0.28
            + 0.72 * pow(saturate(segmentWave), 6.0);
        segmentedEmitter *= 0.8 + 0.2
            * sin(EyeAndTime.w * 2.3 + sampleX * 2.7 + sampleY * 4.1);

        float scan = 0.96 + 0.04
            * sin(sampleHeight * 0.42 - EyeAndTime.w * 2.0);
        float signal = 0.975 + 0.025
            * hash31(samplePosition * 0.071 + EyeAndTime.w * 0.13);
        float interruptionBand = 1.0 - smoothstep(0.018, 0.055,
            abs(heightFraction - interruptionHeight));
        float continuity = 1.0
            - interruptionEnvelope * interruptionBand * 0.38;

        density += volumeValid * inside * signal * scan * continuity
            * ((softCore + coneEdge * coneEdgeStrength) * verticalFade
                + sourceRing * segmentedEmitter * 0.68);
    }

    float opticalDepth = density * (segmentLength / 6.0) / 50.0;
    // The user-facing strength remains useful in the lower half of its range;
    // additive HDR output otherwise makes the default 0.28 nearly invisible.
    float intensity = saturate(opticalDepth * BaseAndStrength.w * pulse * 2.2);
    float totalIntensity = intensity + spill;
    if (totalIntensity < 0.0005) discard;

    // The material uses additive blending. Keeping alpha equal to intensity
    // also behaves correctly on branches that select SRC_ALPHA/ONE blending.
    return float4(TintAndRadius.rgb * totalIntensity, totalIntensity);
}
