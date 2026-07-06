# MinuteModem — Android Asset Set

Dark HF/ALE tactical-terminal identity. Amber `#E8C84A` on near-black `#0A0A0A`,
secondary dark-green `#0E1A0E`, grey `#9A9A9A`. Type: **Chakra Petch** (display/wordmark),
**JetBrains Mono** (spec labels / subtitle). Hard-edged (square corners), matching the app UI.

Two concepts — pick one for shipping:
- **Concept A · CARRIER** — continuous sine carrier + dotted oscilloscope baseline. Modern-minimal.
- **Concept B · SHIFT** — FSK frequency-shift waveform + tactical corner brackets. Military.

## Contents
```
svg/                         Vector sources (scalable, edit these)
  mark_a.svg / mark_b.svg              icon mark, 100×100, transparent
  ic_launcher_foreground_a/b.svg       adaptive foreground, 108dp safe-zone
  ic_launcher_a/b.svg                  full square icon, 512, black bg
  ic_launcher_round_a/b.svg            round-masked icon
  wordmark_a/b.svg                     horizontal logo lockup (needs webfont)
  ChakraPetch-700/600.woff2            embedded display font faces
concept_a/  concept_b/       Ready-to-ship PNGs per concept
  mipmap-mdpi … xxxhdpi/
    ic_launcher.png                    legacy launcher (square, 22% radius)
    ic_launcher_round.png              legacy round launcher
    ic_launcher_foreground.png         adaptive foreground layer (108dp)
    ic_launcher_background.png         adaptive background layer (solid #0A0A0A)
  playstore_icon_512.png               Play Store listing icon
  feature_graphic_1024x500.png         Play Store feature graphic
  splash_icon_1152.png                 Android 12+ splash icon (round-masked)
  wordmark_1440x400.png                logo lockup raster (on black)
```

## Android install (chosen concept)
1. Copy each `mipmap-*/` folder into `android/app/src/main/res/`.
2. Adaptive icon `res/mipmap-anydpi-v26/ic_launcher.xml` (+ `ic_launcher_round.xml`):
```xml
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@mipmap/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
```
3. Splash (Android 12+), in `themes.xml`:
```xml
<item name="android:windowSplashScreenBackground">#0A0A0A</item>
<item name="android:windowSplashScreenAnimatedIcon">@mipmap/splash_icon_1152</item>
```
4. Play Console: upload `playstore_icon_512.png` (icon) and `feature_graphic_1024x500.png`.

Densities: mdpi 48 · hdpi 72 · xhdpi 96 · xxhdpi 144 · xxxhdpi 192 (launcher);
foreground/background at 108dp equivalents (108/162/216/324/432 px).
