# Ring Light

A selfie camera for iPhone with a Snapchat-style ring light, 2000s digicam looks,
and a dozen shooting modes, from photo booth strips to dual camera. Everything saves
straight to your camera roll.

Written in SwiftUI, AVFoundation and Core Image, with no dependencies.

## Features

**Ring light**
- The screen glows around the camera to light your face, built on the same design as
  Snapchat's ring light (solid edges, soft glow, intensity slider).
- Preset colors (white, warm, cool, pink, peach, lavender, blue, red) plus any custom color.
- Colored light actually tints your face: the camera's color balance is locked so it
  doesn't auto-correct the color away.
- Can be turned off.

**Modes**

| Mode | What it does |
| --- | --- |
| Photo / Video | The basics |
| Portrait | Blurs the background behind you (Vision person segmentation), live and in the photo |
| Dual / Dual video | Front and back cameras at once, picture-in-picture (drag the bubble) or split screen |
| Booth | 3-2-1 countdown before each of 4 shots, saved as a photo booth strip |
| Collage | 2 or 4 shots in one picture |
| Burst | Hold the shutter, then pick the shots to keep |
| Boomerang | A short clip that loops forward and back |
| GIF | A choppy, looping animated GIF |
| Slo-mo | Up to 240 fps, saved in slow motion |
| Timelapse | 2 pictures a second, played back at 15× |

**Looks.** Each look is applied identically to the live preview, photos, videos, GIFs and
strips, so what you see is what you get.
- **Digicam:** mid-2000s CCD point-and-shoot (think Nikon Coolpix): ~5 MP, soft blooming
  highlights, pastel-leaning color, fine grain
- **Disposable:** warm, punchy, heavy grain, light leak
- **Polaroid:** faded instant film, saved inside a white instant-photo frame
- **Camcorder:** VHS tape with scanlines, color smear and a `PLAY ▶` overlay
- **B&W**
- **Normal**

**Also**
- Orange digicam date stamp (or a VHS timestamp with the camcorder look)
- Self-timer (3 s / 10 s) and volume-button shutter (hold for burst)
- Back camera: 0.5× ultra-wide and the LED flash (off / auto / on; stays on as a light for video)
- In-app gallery of your shots: swipe, play videos and GIFs, delete
- Photo editor: brightness, contrast, color, warmth, rotate, looks. Edits are saved
  non-destructively, so Photos' **Revert** undoes them.
- The preview is always the exact shape of what gets saved

## Install it on your iPhone (free)

You need a Mac with Xcode and an iPhone on iOS 18 or later. A free Apple ID is enough; no
paid developer account is required.

1. Clone the repo and open `RingLight.xcodeproj` in Xcode.
2. Select the **RingLight** project → **Signing & Capabilities** → choose your own **Team**
   (your Apple ID's Personal Team). Change the **Bundle Identifier** to something unique,
   e.g. `com.yourname.ringlight`.
3. Connect your iPhone by cable the first time, and turn on
   **Settings → Privacy & Security → Developer Mode**.
4. Pick your iPhone as the run destination and press **▶ Run**.
5. On the iPhone, trust your developer certificate once:
   **Settings → General → VPN & Device Management**.

After the first install, Xcode can also install over Wi-Fi. With a free Apple ID the app
expires after 7 days; press **▶ Run** again to refresh it.

Dual camera needs an iPhone that supports multi-camera capture (iPhone XS / XR or later).

## Project layout

| File | What's in it |
| --- | --- |
| `CameraModel.swift` | Camera sessions, every capture mode, saving |
| `ContentView.swift` | The camera screen and controls |
| `GlowView.swift` | The ring light (a Metal shader, drawn as HDR) |
| `CameraPreview.swift` | Live preview with the look applied |
| `Look.swift` | The looks, date stamp, and photo/video processing |
| `DualCamera.swift` | Front + back multi-camera session and layouts |
| `Portrait.swift` | Background blur |
| `Collage.swift` | Photo booth strips and collages |
| `FrameWriter.swift` | Writes frames to video (boomerang, timelapse, dual video) and GIFs |
| `CaptureLibrary.swift`, `GalleryView.swift`, `PhotoEditor.swift`, `BurstPicker.swift` | Gallery, editor and burst picker |

## License

[MIT](LICENSE)
