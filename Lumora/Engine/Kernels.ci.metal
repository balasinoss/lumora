// Lumora — Core Image kernels written in Metal.
// Compiled with -fcikernel / linked with -cikernel (see project.yml).

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
namespace lumora {

inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

inline float3 srgbToLinear(float3 c) {
    float3 a = abs(c);
    float3 lo = a / 12.92;
    float3 hi = pow((a + 0.055) / 1.055, 2.4);
    float3 r = select(hi, lo, a <= 0.04045);
    return sign(c) * r;
}

inline float3 linearToSrgb(float3 c) {
    float3 a = abs(c);
    float3 lo = a * 12.92;
    float3 hi = 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    float3 r = select(hi, lo, a <= 0.0031308);
    return sign(c) * r;
}

inline float3 linearToOklab(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = sign(l) * pow(abs(l), 1.0 / 3.0);
    float m_ = sign(m) * pow(abs(m), 1.0 / 3.0);
    float s_ = sign(s) * pow(abs(s), 1.0 / 3.0);
    return float3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                  1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                  0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_);
}

inline float3 oklabToLinear(float3 c) {
    float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;
    return float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

inline float3 rgbToHsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Interpolates 8 per-band values at an OKLab hue angle (degrees).
inline float bandValue(float h, float4 a, float4 b) {
    float centers[9] = {25.0, 55.0, 100.0, 142.0, 195.0, 255.0, 290.0, 330.0, 385.0};
    float vals[9] = {a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w, a.x};
    if (h < 25.0) h += 360.0;
    float result = vals[0];
    for (int i = 0; i < 8; i++) {
        if (h >= centers[i] && h < centers[i + 1]) {
            float t = (h - centers[i]) / (centers[i + 1] - centers[i]);
            t = t * t * (3.0 - 2.0 * t);
            result = mix(vals[i], vals[i + 1], t);
        }
    }
    return result;
}

} // namespace lumora

extern "C" {
namespace coreimage {

using namespace lumora;

// ---------------------------------------------------------------------------
// Lens correction: distortion, lateral CA (TCA) and vignetting, Lensfun models.
// Coefficients are prepared on the CPU (LensCorrection.swift).
//   dist = (a, b, c, d), factor(r) = d + c r + b r^2 + a r^3 + e r^4
//   tcaR / tcaB = (v, c, b), factor(r) = v + c r + b r^2
//   vig = (k1, k2, k3), pa model, divide by 1 + k1 r^2 + k2 r^4 + k3 r^6
// ---------------------------------------------------------------------------
float4 lensCorrect(sampler src, float2 center, float distNorm, float4 dist, float e,
                   float3 tcaR, float3 tcaB, float vigNorm, float3 vig, float fitScale,
                   float manualDist, float2 manualVig, destination dest)
{
    float2 p = (dest.coord() - center) * fitScale;
    float ru = length(p) / distNorm;
    float r2 = ru * ru;
    float f = dist.w + dist.z * ru + dist.y * r2 + dist.x * r2 * ru + e * r2 * r2;
    f *= 1.0 + manualDist * r2;
    float2 pd = p * f;
    float rd = ru * f;
    float fr = tcaR.x + tcaR.y * rd + tcaR.z * rd * rd;
    float fb = tcaB.x + tcaB.y * rd + tcaB.z * rd * rd;

    float4 cg = src.sample(src.transform(center + pd));
    float4 cr = src.sample(src.transform(center + pd * fr));
    float4 cb = src.sample(src.transform(center + pd * fb));
    float4 c = float4(cr.r, cg.g, cb.b, cg.a);

    float rv = length(pd) / vigNorm;
    float v2 = rv * rv;
    float v = 1.0 + vig.x * v2 + vig.y * v2 * v2 + vig.z * v2 * v2 * v2;
    c.rgb /= max(v, 0.05);

    // Manual optics vignetting: x = amount (-1...1), y = midpoint (0...1)
    float mv = smoothstep(manualVig.y * 0.9, 1.25, rv);
    c.rgb *= 1.0 + manualVig.x * 0.9 * mv;
    return c;
}

// ---------------------------------------------------------------------------
// Automatic chromatic-aberration clean-up for photos without a lens profile:
// near strong edges, replace the pixel's chroma with the surrounding chroma.
// ---------------------------------------------------------------------------
float4 caRemove(sampler src, sampler wide, float amount, float radius, destination dest)
{
    float2 d = dest.coord();
    float4 c = src.sample(src.transform(d));
    float lx0 = luma(src.sample(src.transform(d - float2(radius, 0))).rgb);
    float lx1 = luma(src.sample(src.transform(d + float2(radius, 0))).rgb);
    float ly0 = luma(src.sample(src.transform(d - float2(0, radius))).rgb);
    float ly1 = luma(src.sample(src.transform(d + float2(0, radius))).rgb);
    float g = abs(lx1 - lx0) + abs(ly1 - ly0);
    float edge = smoothstep(0.03, 0.18, g);

    float l = luma(c.rgb);
    float4 w = wide.sample(wide.transform(d));
    float3 chromaC = c.rgb - l;
    float3 chromaW = w.rgb - luma(w.rgb);
    float diff = smoothstep(0.015, 0.08, length(chromaC - chromaW));
    float3 fixedRGB = l + chromaW;
    c.rgb = mix(c.rgb, fixedRGB, clamp(edge * diff * amount, 0.0, 1.0));
    return c;
}

// ---------------------------------------------------------------------------
// Defringe: desaturate purple / green fringes along high-contrast edges.
// Hue ranges are in degrees (HSV).
// ---------------------------------------------------------------------------
float4 defringe(sampler src, float purpleAmt, float2 purpleRange, float greenAmt, float2 greenRange,
                destination dest)
{
    float2 d = dest.coord();
    float4 c = src.sample(src.transform(d));
    float amt = max(purpleAmt, greenAmt);
    if (amt <= 0.0) return c;
    float r = 1.0 + amt * 0.3;
    float lmax = 0.0, lmin = 10.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.785398;
        float l = luma(src.sample(src.transform(d + float2(cos(a), sin(a)) * r)).rgb);
        lmax = max(lmax, l);
        lmin = min(lmin, l);
    }
    float edge = smoothstep(0.05, 0.25, lmax - lmin);
    float3 hsv = rgbToHsv(clamp(c.rgb, 0.0, 1.0));
    float h = hsv.x * 360.0;
    float sat = smoothstep(0.08, 0.3, hsv.y);
    float inP = smoothstep(purpleRange.x - 12.0, purpleRange.x, h) * (1.0 - smoothstep(purpleRange.y, purpleRange.y + 12.0, h));
    float inG = smoothstep(greenRange.x - 12.0, greenRange.x, h) * (1.0 - smoothstep(greenRange.y, greenRange.y + 12.0, h));
    float k = clamp(edge * sat * (inP * min(purpleAmt / 6.0, 1.0) + inG * min(greenAmt / 6.0, 1.0)), 0.0, 1.0);
    float l = luma(c.rgb);
    c.rgb = mix(c.rgb, float3(l), k);
    return c;
}

// ---------------------------------------------------------------------------
// Tone: highlights, shadows, whites, blacks, contrast (gamma-encoded input).
// `local` is a blurred luminance image used for local adaptation.
// p = (highlights, shadows, whites, blacks) / 100
// ---------------------------------------------------------------------------
float4 tone(sample_t s, sample_t local, float4 p, float contrast)
{
    float3 c = s.rgb;
    float y = luma(c);
    float bl = luma(local.rgb);
    float yy = clamp(y, 0.0, 1.5);

    float hm = smoothstep(0.35, 1.0, bl);
    float sm = 1.0 - smoothstep(0.0, 0.6, bl);
    float y2 = yy;
    y2 += p.x * hm * 0.45 * (p.x < 0.0 ? yy : (1.0 - min(yy, 1.0)));
    y2 += p.y * sm * 0.5 * (p.y > 0.0 ? (1.0 - min(yy, 1.0)) * smoothstep(0.0, 0.15, yy + 0.02) : yy);
    y2 += p.z * 0.3 * smoothstep(0.45, 1.0, yy);
    y2 += p.w * 0.22 * (1.0 - smoothstep(0.0, 0.5, yy));

    float y3 = y2;
    if (contrast > 0.0) {
        float t = clamp(y2, 0.0, 1.0);
        float sc = t * t * (3.0 - 2.0 * t);
        y3 = mix(y2, sc + (y2 - t), contrast * 0.9);
    } else if (contrast < 0.0) {
        y3 = y2 + (0.5 - y2) * (-contrast) * 0.45;
    }

    float ratio = y3 / max(y, 1.0e-4);
    float3 mult = c * ratio;
    float3 add = c + (y3 - y);
    float3 o = mix(add, mult, smoothstep(0.02, 0.1, y));
    return float4(o, s.a);
}

// Texture / clarity: luminance detail boost against a blurred copy.
float4 localContrast(sample_t s, sample_t blur, float amount, float midtoneOnly)
{
    float y = luma(s.rgb);
    float d = y - luma(blur.rgb);
    float w = 1.0;
    if (midtoneOnly > 0.5) {
        float t = clamp(y, 0.0, 1.0) * 2.0 - 1.0;
        w = 1.0 - t * t * 0.85;
    }
    float3 o = s.rgb + amount * d * w;
    return float4(o, s.a);
}

// Dehaze using a blurred dark channel as the haze estimate.
float4 dehaze(sample_t s, sample_t dark, float amount)
{
    float3 c = s.rgb;
    if (amount > 0.0) {
        float hz = clamp(dark.r, 0.0, 1.0);
        float t = 1.0 - amount * 0.9 * hz;
        float A = 0.95;
        c = (c - A * (1.0 - t)) / max(t, 0.15);
        c = mix(s.rgb, c, 0.85);
        // keep some saturation boost characteristic of dehaze
        float y = luma(c);
        c = y + (c - y) * (1.0 + amount * 0.25);
    } else {
        float k = -amount;
        c = mix(c, float3(0.82), k * 0.55);
    }
    return float4(c, s.a);
}

// ---------------------------------------------------------------------------
// Colour: mixer (8 bands, hue/sat/lum), vibrance, saturation, B&W mix.
// Works in OKLab (input is gamma-encoded sRGB).
// ---------------------------------------------------------------------------
float4 colorMixer(sample_t s, float4 hueA, float4 hueB, float4 satA, float4 satB,
                  float4 lumA, float4 lumB, float vibrance, float saturation,
                  float bw, float4 bwA, float4 bwB)
{
    float3 lin = srgbToLinear(s.rgb);
    float3 lab = linearToOklab(lin);
    float C = length(lab.yz);
    float h = atan2(lab.z, lab.y) * 57.29578;
    if (h < 0.0) h += 360.0;
    float colorful = smoothstep(0.0, 0.06, C);

    if (bw > 0.5) {
        float mixv = bandValue(h, bwA, bwB);
        float L = lab.x + mixv * C * 0.9 * colorful;
        float3 g = oklabToLinear(float3(L, 0.0, 0.0));
        return float4(linearToSrgb(g), s.a);
    }

    float dh = bandValue(h, hueA, hueB);
    float ds = bandValue(h, satA, satB);
    float dl = bandValue(h, lumA, lumB);

    float h2 = h + dh * 30.0 * colorful;
    float C2 = C * max(0.0, 1.0 + ds);
    float L2 = lab.x + dl * 0.22 * colorful * (0.4 + 0.6 * smoothstep(0.02, 0.12, C));

    // Vibrance: boosts muted colours more than saturated ones, protects skin tones.
    if (vibrance != 0.0) {
        float skin = smoothstep(20.0, 40.0, h2) * (1.0 - smoothstep(75.0, 95.0, h2));
        float k = vibrance > 0.0 ? vibrance * (1.0 - smoothstep(0.0, 0.22, C2)) * (1.0 - 0.6 * skin) : vibrance;
        C2 *= max(0.0, 1.0 + k);
    }
    C2 *= max(0.0, 1.0 + saturation);

    float hr = h2 * 0.0174533;
    float3 lab2 = float3(L2, C2 * cos(hr), C2 * sin(hr));
    float3 o = linearToSrgb(oklabToLinear(lab2));
    return float4(o, s.a);
}

// ---------------------------------------------------------------------------
// Colour grading. Each wheel: rgb = chroma offset, a = luminance offset.
// ---------------------------------------------------------------------------
float4 colorGrade(sample_t s, float4 sh, float4 mi, float4 hi, float4 gl, float blending, float balance)
{
    float3 c = s.rgb;
    float L = clamp(luma(c), 0.0, 1.0);
    float pivot = 0.5 - balance * 0.3;
    float w = 0.12 + blending * 0.55;
    float sW = 1.0 - smoothstep(max(pivot - w, 0.0), pivot, L);
    float hW = smoothstep(pivot, min(pivot + w, 1.0), L);
    float mW = clamp(1.0 - sW - hW, 0.0, 1.0);
    float3 o = c + sW * sh.rgb + mW * mi.rgb + hW * hi.rgb + gl.rgb;
    o += sW * sh.a + mW * mi.a + hW * hi.a + gl.a;
    return float4(o, s.a);
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
// Colour noise reduction: replace chroma with blurred chroma.
float4 chromaNR(sample_t s, sample_t blur, float amount, float detail)
{
    float y = luma(s.rgb);
    float3 chroma = s.rgb - y;
    float3 chromaB = blur.rgb - luma(blur.rgb);
    float keep = detail * smoothstep(0.03, 0.15, length(chroma - chromaB));
    float k = clamp(amount * (1.0 - keep), 0.0, 1.0);
    return float4(y + mix(chroma, chromaB, k), s.a);
}

// Luminance noise reduction: edge-aware blend toward a blurred copy.
float4 lumaNR(sample_t s, sample_t blur, float amount, float detail, float contrastKeep)
{
    float y = luma(s.rgb);
    float yb = luma(blur.rgb);
    float diff = abs(y - yb);
    float edge = smoothstep(0.02 + (1.0 - detail) * 0.08, 0.12 + (1.0 - detail) * 0.15, diff);
    float k = clamp(amount * (1.0 - edge), 0.0, 1.0);
    float ny = mix(y, yb, k);
    ny = mix(ny, y + (ny - y) * (1.0 - contrastKeep * 0.5), contrastKeep);
    return float4(s.rgb + (ny - y), s.a);
}

// Sharpening with edge masking (masking 0...1: 0 = sharpen everything).
float4 sharpen(sample_t s, sample_t blur, sample_t wide, float amount, float detail, float masking)
{
    float y = luma(s.rgb);
    float d = y - luma(blur.rgb);
    // detail controls halo suppression: low detail = softer response on big differences
    float limit = 0.04 + detail * 0.25;
    d = clamp(d, -limit, limit);
    float edge = abs(luma(blur.rgb) - luma(wide.rgb));
    float m = masking <= 0.0 ? 1.0 : smoothstep(masking * 0.05, masking * 0.05 + 0.03, edge);
    return float4(s.rgb + amount * d * m, s.a);
}

// Black & white preview of where sharpening is applied (white = sharpened).
float4 sharpenMask(sample_t s, sample_t blur, sample_t wide, float masking)
{
    float edge = abs(luma(blur.rgb) - luma(wide.rgb));
    float m = masking <= 0.0 ? 1.0 : smoothstep(masking * 0.05, masking * 0.05 + 0.03, edge);
    return float4(m, m, m, 1.0);
}

// Red overlay showing the selected mask (mask value in mask.r).
float4 maskOverlay(sample_t s, sample_t mask, float opacity)
{
    float m = clamp(mask.r, 0.0, 1.0) * opacity;
    float3 red = float3(1.0, 0.18, 0.25);
    return float4(mix(s.rgb, red, m * 0.55), s.a);
}

// Combine a mask with brush strokes: add = max, erase = multiply by (1 - erase).
float4 maskCombine(sample_t base, sample_t add, sample_t erase, float invert, float opacity)
{
    float m = clamp(base.r, 0.0, 1.0);
    if (invert > 0.5) m = 1.0 - m;
    m = max(m, add.r);
    m = m * (1.0 - erase.r);
    m *= opacity;
    return float4(m, m, m, 1.0);
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------
float4 vignette(sample_t s, float2 center, float2 halfSize, float amount, float midpoint,
                float roundness, float feather, float highlights, destination dest)
{
    float2 p = (dest.coord() - center) / halfSize;
    float n = roundness >= 0.0 ? 2.0 + roundness * 6.0 : 2.0 + roundness * 1.0;
    float2 ap = abs(p);
    // roundness > 0 => more circular relative to frame aspect
    float aspect = halfSize.x / halfSize.y;
    if (roundness > 0.0) {
        float2 q = p;
        q.x *= mix(1.0, aspect, roundness);
        ap = abs(q) / float2(mix(1.0, aspect, roundness), 1.0);
        n = 2.0;
    }
    float d = pow(pow(ap.x, n) + pow(ap.y, n), 1.0 / n);
    float r0 = 0.25 + midpoint * 0.95;
    float f = 0.05 + feather * 1.1;
    float m = smoothstep(r0 - f * 0.5, r0 + f * 0.5, d);
    float3 c = s.rgb;
    float3 o;
    if (amount < 0.0) {
        o = c * (1.0 + amount * m);
        float y = luma(c);
        o = mix(o, c, highlights * smoothstep(0.6, 1.0, y) * m);
    } else {
        o = c + (1.0 - c) * amount * m;
    }
    return float4(o, s.a);
}

float4 grainBlend(sample_t s, sample_t noise, float amount)
{
    float n = noise.r - 0.5;
    float y = luma(s.rgb);
    float w = 1.0 - abs(y * 2.0 - 1.0) * 0.6;   // grain is most visible in midtones
    return float4(s.rgb + n * amount * w, s.a);
}

// Dark channel (min RGB), input for dehaze.
float4 darkChannel(sample_t s)
{
    float m = min(min(s.r, s.g), s.b);
    return float4(m, m, m, s.a);
}

} // namespace coreimage
} // extern "C"
