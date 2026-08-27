import Foundation

enum OpticalShaderLibrary {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct AtticVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct AtticUniforms {
        float4 geometry0; // capture width, capture height, panel origin u, panel origin v
        float4 geometry1; // panel normalized width/height, panel physical width/height
        float4 optics0;   // corner radius px, band px, displacement px, capture scale
        float4 optics1;   // frost px, surface opacity, edge shine, tint opacity
        float4 optics2;   // readability, interaction multiplier, blur samples, edge evaluations
        float4 optics3;   // workload maximum displacement, reserved...
        float4 tintColor;
        float4 surfaceColor;
    };

    struct AtticBoundary {
        float signedDistance;
        float2 outwardNormal;
    };

    static inline float attic_smoothstep(float value) {
        float t = clamp(value, 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    static inline AtticBoundary attic_boundary(
        float2 point,
        float2 size,
        float radius
    ) {
        float2 halfSize = max(size * 0.5f, float2(0.0001f));
        float clampedRadius = clamp(radius, 0.0f, min(halfSize.x, halfSize.y));
        float2 centered = point - halfSize;
        float2 signs = select(
            float2(-1.0f),
            float2(1.0f),
            centered >= float2(0.0f)
        );
        float2 q = abs(centered) - (halfSize - clampedRadius);
        float2 positive = max(q, float2(0.0f));

        constexpr float exponent = 5.0f;
        float sum = pow(positive.x, exponent) + pow(positive.y, exponent);
        float roundedDistance = pow(max(sum, 0.0f), 1.0f / exponent);
        float interiorDistance = min(max(q.x, q.y), 0.0f);
        float signedDistance = roundedDistance + interiorDistance - clampedRadius;

        float2 outwardGradient;
        if (positive.x > 0.0f || positive.y > 0.0f) {
            float denominator = pow(
                max(sum, 0.000001f),
                (exponent - 1.0f) / exponent
            );
            outwardGradient = float2(
                pow(positive.x, exponent - 1.0f),
                pow(positive.y, exponent - 1.0f)
            ) / denominator;
            outwardGradient *= signs;
        } else if (q.x > q.y) {
            outwardGradient = float2(signs.x, 0.0f);
        } else if (q.y > q.x) {
            outwardGradient = float2(0.0f, signs.y);
        } else {
            outwardGradient = normalize(signs);
        }

        return AtticBoundary {
            signedDistance,
            normalize(outwardGradient)
        };
    }

    static inline float4 attic_sample_backdrop(
        texture2d<float> backdrop,
        sampler backdropSampler,
        float2 uv,
        float2 textureSize,
        float frostRadiusPixels,
        float captureScale,
        uint blurSampleCount
    ) {
        if (frostRadiusPixels <= 0.001f || blurSampleCount <= 1u) {
            return backdrop.sample(backdropSampler, uv);
        }

        float4 accumulated = float4(0.0f);
        float totalWeight = 0.0f;
        for (uint sampleIndex = 0u; sampleIndex < 13u; ++sampleIndex) {
            if (sampleIndex >= blurSampleCount) {
                break;
            }
            float normalizedIndex = (float(sampleIndex) + 0.5f)
                / max(float(blurSampleCount), 1.0f);
            float angle = float(sampleIndex) * 2.39996323f;
            float radius = sqrt(normalizedIndex)
                * frostRadiusPixels
                * captureScale;
            float2 offset = float2(cos(angle), sin(angle))
                * radius
                / max(textureSize, float2(1.0f));
            float weight = 1.0f - normalizedIndex * 0.42f;
            accumulated += backdrop.sample(backdropSampler, uv + offset) * weight;
            totalWeight += weight;
        }
        return accumulated / max(totalWeight, 0.0001f);
    }

    vertex AtticVertexOut attic_optical_vertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            float2(-1.0f, -1.0f),
            float2( 1.0f, -1.0f),
            float2(-1.0f,  1.0f),
            float2(-1.0f,  1.0f),
            float2( 1.0f, -1.0f),
            float2( 1.0f,  1.0f)
        };
        constexpr float2 uvs[6] = {
            float2(0.0f, 1.0f),
            float2(1.0f, 1.0f),
            float2(0.0f, 0.0f),
            float2(0.0f, 0.0f),
            float2(1.0f, 1.0f),
            float2(1.0f, 0.0f)
        };
        AtticVertexOut output;
        output.position = float4(positions[vertexID], 0.0f, 1.0f);
        output.uv = uvs[vertexID];
        return output;
    }

    fragment float4 attic_optical_fragment(
        AtticVertexOut input [[stage_in]],
        constant AtticUniforms& uniforms [[buffer(0)]],
        texture2d<float> backdrop [[texture(0)]],
        sampler backdropSampler [[sampler(0)]]
    ) {
        float2 captureTextureSize = max(uniforms.geometry0.xy, float2(1.0f));
        float2 panelOrigin = uniforms.geometry0.zw;
        float2 panelNormalizedSize = uniforms.geometry1.xy;
        float2 panelPhysicalSize = max(uniforms.geometry1.zw, float2(1.0f));
        float2 captureUV = panelOrigin + input.uv * panelNormalizedSize;

        float cornerRadiusPixels = uniforms.optics0.x;
        float bandPixels = uniforms.optics0.y;
        float displacementPixels = uniforms.optics0.z;
        float captureScale = uniforms.optics0.w;
        AtticBoundary boundary = attic_boundary(
            input.uv * panelPhysicalSize,
            panelPhysicalSize,
            cornerRadiusPixels
        );
        if (boundary.signedDistance > 0.0f) {
            discard_fragment();
        }

        float distanceInside = max(0.0f, -boundary.signedDistance);
        float edgeInfluence = 0.0f;
        float2 warpedUV = captureUV;

        // Exact coordinate identity for Refraction 0 and for the clear center.
        if (bandPixels > 0.0f
            && displacementPixels > 0.0f
            && distanceInside < bandPixels) {
            uint edgeEvaluationCount = uint(clamp(
                round(uniforms.optics2.w),
                1.0f,
                5.0f
            ));
            float2 normalSum = boundary.outwardNormal;
            float2 tangent = float2(
                -boundary.outwardNormal.y,
                boundary.outwardNormal.x
            );
            for (uint evaluationIndex = 1u; evaluationIndex < 5u; ++evaluationIndex) {
                if (evaluationIndex >= edgeEvaluationCount) {
                    break;
                }
                float centeredIndex = float(evaluationIndex)
                    - float(edgeEvaluationCount - 1u) * 0.5f;
                AtticBoundary neighbor = attic_boundary(
                    clamp(
                        input.uv * panelPhysicalSize + tangent * centeredIndex * 0.75f,
                        float2(0.0f),
                        panelPhysicalSize
                    ),
                    panelPhysicalSize,
                    cornerRadiusPixels
                );
                normalSum += neighbor.outwardNormal;
            }
            float2 outwardNormal = normalize(normalSum);
            float2 inwardNormal = -outwardNormal;
            edgeInfluence = attic_smoothstep(1.0f - distanceInside / bandPixels);
            float bottomWeight = attic_smoothstep((input.uv.y - 0.58f) / 0.42f);
            float cornerWeight = min(
                1.0f,
                2.0f * abs(inwardNormal.x * inwardNormal.y)
            );
            float edgeMultiplier = min(
                1.0f,
                0.68f + 0.14f * bottomWeight + 0.18f * cornerWeight
            );
            float maximumDisplacement = max(uniforms.optics3.x, 0.0f);
            float interactionDisplacement = displacementPixels
                * max(uniforms.optics2.y, 1.0f);
            float effectiveDisplacement = min(
                maximumDisplacement,
                interactionDisplacement
            );
            warpedUV += inwardNormal
                * effectiveDisplacement
                * edgeMultiplier
                * edgeInfluence
                * captureScale
                / captureTextureSize;
        }

        uint blurSampleCount = uint(clamp(
            round(uniforms.optics2.z),
            1.0f,
            13.0f
        ));
        float4 backdropColor = attic_sample_backdrop(
            backdrop,
            backdropSampler,
            warpedUV,
            captureTextureSize,
            uniforms.optics1.x,
            captureScale,
            blurSampleCount
        );

        float3 color = backdropColor.rgb;
        color = mix(color, uniforms.surfaceColor.rgb, uniforms.optics1.y);
        color = mix(color, uniforms.tintColor.rgb, uniforms.optics1.w);

        float centerReadability = uniforms.optics2.x * (1.0f - edgeInfluence);
        color = mix(color, uniforms.surfaceColor.rgb, centerReadability);

        float2 lightDirection = normalize(float2(-0.55f, -0.84f));
        float directionalShine = dot(boundary.outwardNormal, lightDirection)
            * 0.5f + 0.5f;
        float shine = uniforms.optics1.z
            * edgeInfluence
            * (0.35f + 0.65f * directionalShine);
        color = mix(color, float3(1.0f), clamp(shine, 0.0f, 1.0f));

        return float4(clamp(color, 0.0f, 1.0f), 1.0f);
    }
    """#
}
