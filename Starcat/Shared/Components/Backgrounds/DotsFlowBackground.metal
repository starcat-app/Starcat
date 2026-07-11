//
//  DotsFlowBackground.metal
//  Starcat
//
//  从 ShipSwift（`refer/ShipSwift/ShipSwift/SWPackage/SWAnimation/SWMetal/SWDotsFlow.metal`）
//  原样移植的 stitchable SwiftUI color effect。**导出函数名保持 `swDotsFlow`**——
//  SwiftUI `ShaderLibrary.default` 按函数名解析，Swift 端 `DotsFlowBackground.swift`
//  里 `ShaderFunction(name: "swDotsFlow")` 与此处必须严格一致；要重命名两边一起改。
//
//  Flow 样式：curl-like 平面流场，每个点亮度沿 wavefronts（与流向正交的等相位线）
//  脉动。没有 3D 透视、没有地平线，整屏均匀流动，适合做页面/sheet 装饰背景。
//
//  Requires macOS 14+ / iOS 17+。Starcat 部署 macOS 15.0 满足。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Signature 保留 ShipSwift 原版完整 13 参——其中 `horizon / amplitude / depthFade`
// 属于 3D perspective 样式（wavy / mountains / ocean / standing）的参数，flow 这种
// 平面样式不消耗它们，用 `(void)x;` 显式标注"故意不使用"避免编译告警。
[[ stitchable ]] half4 swDotsFlow(float2 position,
                                  half4  color,
                                  float4 boundingRect,
                                  float  time,
                                  float  speed,
                                  float  brightness,
                                  half4  tint,
                                  half4  background,
                                  float  dotSize,
                                  float  gridDensity,
                                  float  patternScale,
                                  float  vignette,
                                  float  horizon,
                                  float  amplitude,
                                  float  depthFade) {
    (void)horizon;
    (void)amplitude;
    (void)depthFade;

    float2 size = boundingRect.zw;
    float2 uv   = (position - 0.5 * size) / size.y;
    float  t    = time * speed;

    float  grid       = 0.020 / max(gridDensity, 0.01);
    float2 cell       = round(uv / grid) * grid;
    float  distToDot  = length(uv - cell);
    float  pxR        = (1.4 / size.y) * dotSize;
    float  mask       = smoothstep(pxR * 1.4, pxR * 0.6, distToDot);

    float n = sin(cell.x * 3.0 * patternScale + t * 0.4) *
              cos(cell.y * 3.0 * patternScale - t * 0.35) +
              0.5 * sin(cell.x * 7.0 * patternScale - t * 0.6) *
                    sin(cell.y * 7.0 * patternScale + t * 0.55);

    float fronts = sin(n * 6.0 + length(cell) * 8.0 * patternScale - t * 1.8);
    float bright = pow(max(fronts, 0.0), 1.8);

    float2 vUV   = (position - 0.5 * size) / size;
    float  vig   = clamp(1.0 - dot(vUV, vUV) * 0.85 * vignette, 0.0, 1.0);
    float  intensity = mask * (0.10 + 1.0 * bright) * vig;

    float3 bg  = float3(background.rgb);
    float3 fg  = float3(tint.rgb) * brightness;
    float3 col = mix(bg, fg, intensity);
    return half4(half3(col), 1.0h);
}

// Plasma 样式同样来自 ShipSwift `SWDotsPlasma.metal`。它仍是平面网格，
// 不消耗 3D 参数，适合做比 flow 更密集、更有能量感的静态区域底纹。
[[ stitchable ]] half4 swDotsPlasma(float2 position,
                                    half4  color,
                                    float4 boundingRect,
                                    float  time,
                                    float  speed,
                                    float  brightness,
                                    half4  tint,
                                    half4  background,
                                    float  dotSize,
                                    float  gridDensity,
                                    float  patternScale,
                                    float  vignette,
                                    float  horizon,
                                    float  amplitude,
                                    float  depthFade) {
    (void)horizon;
    (void)amplitude;
    (void)depthFade;

    float2 size = boundingRect.zw;
    float2 uv   = (position - 0.5 * size) / size.y;
    float  t    = time * speed;

    float  grid      = 0.018 / max(gridDensity, 0.01);
    float2 cell      = round(uv / grid) * grid;
    float  distToDot = length(uv - cell);
    float  pxR       = (1.6 / size.y) * dotSize;
    float  mask      = smoothstep(pxR * 1.4, pxR * 0.6, distToDot);

    float v = sin(cell.x * 8.0 * patternScale + t * 1.3) +
              sin(cell.y * 8.0 * patternScale + t * 1.1) +
              sin((cell.x + cell.y) * 6.0 * patternScale + t * 1.5) +
              sin(length(cell) * 10.0 * patternScale - t * 1.8);
    v = v * 0.25;
    float bright = clamp(0.5 + 0.5 * v, 0.0, 1.0);
    bright = pow(bright, 2.5);

    float2 vUV  = (position - 0.5 * size) / size;
    float  vig  = clamp(1.0 - dot(vUV, vUV) * 0.9 * vignette, 0.0, 1.0);
    float  intensity = mask * bright * vig;

    float3 bg  = float3(background.rgb);
    float3 fg  = float3(tint.rgb) * brightness;
    float3 col = mix(bg, fg, intensity);
    return half4(half3(col), 1.0h);
}

// Snake 样式来自 ShipSwift `SWDotsSnake.metal`。亮点沿 flow phase 移动，
// 比 plasma 更像有方向的轨迹，适合通行证预览的“活卡面”效果。
[[ stitchable ]] half4 swDotsSnake(float2 position,
                                   half4  color,
                                   float4 boundingRect,
                                   float  time,
                                   float  speed,
                                   float  brightness,
                                   half4  tint,
                                   half4  background,
                                   float  dotSize,
                                   float  gridDensity,
                                   float  patternScale,
                                   float  vignette,
                                   float  horizon,
                                   float  amplitude,
                                   float  depthFade) {
    (void)horizon;
    (void)amplitude;
    (void)depthFade;

    float2 size = boundingRect.zw;
    float2 uv   = (position - 0.5 * size) / size.y;
    float  t    = time * speed;

    float  grid      = 0.018 / max(gridDensity, 0.01);
    float2 cell      = round(uv / grid) * grid;
    float  distToDot = length(uv - cell);
    float  pxR       = (1.5 / size.y) * dotSize;
    float  mask      = smoothstep(pxR * 1.4, pxR * 0.6, distToDot);

    float angle = sin(cell.x * 4.0 * patternScale + t * 0.6) * 1.2 +
                  cos(cell.y * 4.0 * patternScale - t * 0.5) * 1.2 +
                  sin((cell.x + cell.y) * 3.0 * patternScale + t * 0.9);
    float2 flow = float2(cos(angle), sin(angle));

    float phase  = dot(cell, flow) * 12.0 * patternScale - t * 4.0;
    float bright = 0.5 + 0.5 * sin(phase);
    bright = pow(bright, 4.0);

    float2 vUV   = (position - 0.5 * size) / size;
    float  vig   = clamp(1.0 - dot(vUV, vUV) * 0.7 * vignette, 0.0, 1.0);
    float  intensity = mask * (0.10 + 1.1 * bright) * vig;

    float3 bg  = float3(background.rgb);
    float3 fg  = float3(tint.rgb) * brightness;
    float3 col = mix(bg, fg, intensity);
    return half4(half3(col), 1.0h);
}
