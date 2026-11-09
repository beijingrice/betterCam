# betterCam for Android

Kotlin + Jetpack Compose + Camera2 port of the iOS betterCam app (`../betterCam`).

## Build

Test APK (signed with the local debug key, installs directly):

```bash
./gradlew :app:assembleRelease   # -> app/build/outputs/apk/release/app-release.apk
```

Debug build:

Open this folder in Android Studio, or:

```bash
./gradlew :app:assembleDebug
```

Requires JDK 17–21 (Android Studio's bundled JBR works), compileSdk 35, minSdk 30.

## iOS → Android map

| iOS | Android |
| --- | --- |
| `Camera.swift` | `CameraModel.kt` (ViewModel, same state + bindings) |
| `SessionManager.swift` | `camera/CameraController.kt` (Camera2), `camera/CaptureProcessor.kt` |
| `ParameterManager.swift`, `ExposureParameter.swift`, `DialNavigation.swift` | `data/ParameterManager.kt`, `data/ExposureParameter.kt`, `CameraModel.changeParameter` |
| `Lens.swift`, `LensManager.swift`, `PhotoDimensions.swift` | `camera/Lens.kt` |
| `FilmEngine*.swift` (Core Image) | `engine/FilmEngine.kt`, `engine/BuiltInLooks.kt` (CPU stills), `engine/PreviewRenderer.kt` (GLES live preview) |
| `MetalWHProcessor` + `.metal` | `engine/ExposureAnalyzer.kt` (fed by the preview renderer) |
| `CIRAWFilter` (ZERO PROCESSING) | `camera/RawDeveloper.kt` |
| Views (`ContentView`, `LandscapeWorkspace`, `ScreenView`, bars, dial, shutter, menu, LUT manager, tutorial) | `ui/*.kt` (same layout maths) |
| `ShutterManager` + WidgetKit widget | `data/ShutterCounter.kt` + `widget/ShutterWidgetProvider.kt` |
| Control widget (Action button launch) | `widget/LaunchTileService.kt` (Quick Settings tile) |
| `AVCaptureEventInteraction` (volume buttons) | `MainActivity.onKeyDown` (volume / camera keys) |

## Platform differences

- **Apple ProRAW** has no Android equivalent and always shows as unavailable. DNG / DNG+J / ZERO PROCESSING need a camera with the Camera2 RAW capability.
- **Lenses**: ultra-wide and telephoto lenses are exposed as zoom ratios of the logical camera (how most Android phones work), plus any standalone back cameras.
- **Resolution** follows the phone instead of the iPhone's fixed 24/48 MP: *standard* is the sensor's normal 4:3 size, *high* is the largest size the phone really offers (e.g. 50 MP through the maximum-resolution mode of quad-bayer sensors), shown as N/A when there is none.
- **Light meter** (EV readout in manual mode): Android has no `exposureTargetOffset`, so it is computed from the preview luminance relative to 18% grey.
- **`.cube` LUTs** run on linearised input, the same way `CIColorCube` does in Core Image's linear working space, so photos look like the iOS app. To apply LUTs to gamma-encoded values instead, set `linearInput = false` in `FilmEngine`.
- The **built-in looks** (CHROME, INSTANT, FADE, PROCESS, TRANSFER, MONO, NOIR, TONAL) are hand-tuned approximations of Apple's `CIPhotoEffect*` filters.
- The iOS tip jar (buy me a coffee) is not included on Android.
- Photos are saved to `DCIM/betterCam` through MediaStore, so no storage permission is needed.

## Diagnostics

`adb logcat -s CameraController CaptureProcessor CameraModel LensDiscovery FilmEngine` shows the lens list,
every capture, processing times and warnings, e.g. when the camera HAL never answers a capture request
(the shutter is unlocked after 10 s and the shot is reported as failed).
