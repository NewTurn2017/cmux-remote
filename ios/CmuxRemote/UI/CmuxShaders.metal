#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Stitchable scanline + subtle RGB shift effect for SwiftUI layerEffect.
//
// Args:
//   lineHeight — number of pixels per scanline cycle (e.g. 2.5)
//   intensity  — how dark the off-scan band is, 0.0 (none) … 1.0 (black)
//   shift      — chromatic aberration in pixels (e.g. 0.4)
//
// Layer-effect signature: (float2 position, SwiftUI::Layer layer, args...)
[[ stitchable ]] half4 cmuxScanlines(float2 position,
                                     SwiftUI::Layer layer,
                                     float lineHeight,
                                     float intensity,
                                     float shift) {
    // Base sample.
    half4 base = layer.sample(position);

    // Chromatic aberration: pick red from the right, blue from the left.
    half4 r = layer.sample(position + float2(shift, 0));
    half4 b = layer.sample(position - float2(shift, 0));
    half3 rgb = half3(r.r, base.g, b.b);

    // Scanline darken — sine band so the transition is soft, not hard stripes.
    float band = sin(position.y * 3.14159265 / max(lineHeight, 0.5));
    float scan = 1.0 - max(0.0, band) * intensity;

    rgb *= half(scan);
    return half4(rgb, base.a);
}
