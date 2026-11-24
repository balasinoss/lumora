# Lumora

A RAW photo editor for iPhone, built with SwiftUI + Core Image (Metal). Installed by sideloading — no Mac needed.

## Features (v1)
- **Library**: import from Photos (keeps RAW/ProRAW/DNG) or Files; flags, ratings, copy/paste settings, batch paste
- **Light**: Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Auto, point **Curves** (RGB / R / G / B)
- **Color**: White balance presets (RAW), Temp, Tint, Vibrance, Saturation, **Color Mixer** (8 bands × Hue/Sat/Lum), **Color Grading** (shadows/midtones/highlights/global wheels, blending, balance), Black & White mix
- **Effects**: Texture, Clarity, Dehaze, post-crop Vignette (amount, midpoint, roundness, feather, highlights), Grain (amount, size, roughness)
- **Detail**: Sharpening (amount, radius, detail, masking), Noise Reduction (amount, detail, contrast), Color Noise Reduction (amount, detail, smoothness)
- **Optics**: Remove Chromatic Aberration, **lens profile corrections** (distortion, vignetting, lateral CA — auto-detected from EXIF, thousands of lenses via [Lensfun](https://lensfun.github.io)), manual distortion/vignetting, Defringe (purple/green)
- **Geometry**: Vertical, Horizontal, Rotate, Aspect, Scale, Offset X/Y
- **Crop**: aspect ratios, straighten, rotate, flip
- **Looks**: built-in looks with amount
- Undo/redo, before/after (hold the split icon), histogram, pinch-zoom
- **Export**: JPEG / HEIC / PNG, size & quality, Save to Photos, Share
- **iCloud Drive**: pick a folder once → originals + edits are backed up and finished JPEGs are saved automatically (restore on any iPhone)

Coming next: AI masks (subject, sky, background, people + brush/linear/radial), AI Denoise.

## Install on iPhone (Windows PC)
1. Open the **Releases** page of this repo → `latest` → download **Lumora.ipa**.
2. Install [Sideloadly](https://sideloadly.io) and iTunes (from apple.com, not the Microsoft Store) on your PC.
3. Plug in the iPhone, drag `Lumora.ipa` into Sideloadly, enter your Apple ID, press **Start**.
4. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID.
   (iOS 16+: also enable Settings → Privacy & Security → **Developer Mode**.)
5. With a free Apple ID the app must be re-installed every 7 days (your photos stay — and they're backed up in iCloud Drive).

## Build
Every push to `main` builds the app on GitHub Actions (macOS runner, XcodeGen, unsigned build) and publishes `Lumora.ipa` to the `latest` release.

## Credits
Lens profiles: Lensfun database, CC BY-SA 3.0.
