# Snowglobe ❄️

Turn the places in your photos into tiny 3D snowglobes.

Pick a photo → the app reads where it was taken → it builds a miniature of that spot (real buildings from OpenStreetMap, Apple Maps imagery on the ground, real terrain, little snowy trees) inside a glass globe on a wooden pedestal. Globes live on a shelf; tap one to see it up close, **shake your phone to make it snow**, and tap **View in AR** to put it on your desk.

> Hackathon prototype — SwiftUI + RealityKit + ARKit + MapKit. No API keys, no third-party packages, no tests.

## Status: all 6 stages
- [x] **1. Shelf**: home screen with four demo globes (2D drawings), rename/delete, tap to open a globe.
- [x] **2. Live 3D globe**: slim octagonal wooden base, brass name plaque, glass dome, placeholder village inside; drag to spin/tilt, pinch to zoom, double-tap to reset.
- [x] **3. Snow + shake**: 1,500 tumbling, glinting flakes in a swirly liquid that settle on the ground and on the real rooftops. Shake the iPhone, press **Shake**, tap the glass or flick the globe to stir it, and turn the iPhone upside down to make the snow fall to the top of the glass (see *Snow* below).
- [x] **4. Real 3D places inside the globe**: Google Photorealistic 3D Tiles around the globe's location, cut into a disc that fits under the glass. Needs a Google key (see below).
- [x] **5. Add a globe from a photo's location**: the photo button (top right of the shelf) opens the system photo picker; the app reads where and when the photo was taken from its metadata, names the place with Apple Maps, and makes a 300 m globe there. (Place search and size/style pickers aren't built yet.)
- [x] **6. View in AR**: find a table or floor, tap to place the globe (with the real place inside), drag/twist/pinch it. Needs a real iPhone.

The rest of this README describes the full planned app; anything not ticked above isn't built yet.

---

## Opening the project in Xcode

### Requirements
- A Mac with **Xcode 26 or newer** (built with Xcode 27.2).
- **iOS 26+**. The Simulator runs everything except AR; AR needs a real iPhone.
- Internet access the first time each globe is built (map data is downloaded, then cached).

### Run in the Simulator (fastest)
1. Open the project:
   ```bash
   open Snowglobe.xcodeproj
   ```
   (or double-click `Snowglobe.xcodeproj` in Finder, or **File ▸ Open…** in Xcode).
2. In the toolbar, pick the **Snowglobe** scheme and any iPhone simulator (e.g. *iPhone 17*).
3. Press **⌘R**.

On first launch the shelf has four demo globes (Times Square, Venice, Half Dome, Shibuya). Tap one to open it in 3D.

### Run on your iPhone (needed for AR + real shaking)
1. Plug in your iPhone (or pair it over Wi-Fi) and turn on **Developer Mode** on the phone: *Settings ▸ Privacy & Security ▸ Developer Mode*.
2. In Xcode, click the blue **Snowglobe** project in the navigator ▸ select the **Snowglobe** target ▸ **Signing & Capabilities**:
   - **Team**: choose your Apple ID (a free *Personal Team* works — add your account via *Xcode ▸ Settings ▸ Accounts* if the list is empty).
   - **Bundle Identifier**: change `com.example.snowglobe` to something unique, e.g. `com.yourname.snowglobe` (every teammate needs their own if you all use free accounts).
3. Select your iPhone as the run destination and press **⌘R**.
4. First time only: if iOS says the developer is untrusted, go to *Settings ▸ General ▸ VPN & Device Management* and trust your Apple ID, then run again.

### Google Maps key (for photo-realistic globes)
The 3D city data comes from Google's Photorealistic 3D Tiles, which needs a Google Maps Platform API key with the **Map Tiles API** enabled. Keys are never committed:
1. Copy `Secrets.example.plist` (repo root) to `Snowglobe/Secrets.plist`. That path is git-ignored.
2. Open `Snowglobe/Secrets.plist` in Xcode and replace `PASTE_YOUR_KEY_HERE` with the key.
3. Share the key with teammates privately (not on GitHub). Restrict it in Google Cloud to the Map Tiles API and to the app's bundle ID.

Without a key the app still builds and runs; globes just can't download 3D data.

### Simulator tips
- **Shake:** *Device ▸ Shake* in the Simulator menu (**⌃⌘Z**). There's also a Shake button on screen. Without the Simulator app open (e.g. a headless simulator), run
  ```bash
  xcrun simctl spawn booted notifyutil -p com.apple.UIKit.SimulatorShake
  ```
  The Simulator has no motion sensor, so the continuous "shake your iPhone" feel and turning the globe upside down need a real device.
- **Photos with a location:** drag photos from your Mac (e.g. iPhone photos exported from Photos.app, which keep GPS) onto the Simulator window, or run
  ```bash
  xcrun simctl addmedia booted ~/Path/To/photo.jpg
  ```
- **No photo handy?** In the add sheet, tap *No photo? Pick a place* and search, or choose one of the *Famous places*.

---

## Using the app
| Screen | What you can do |
|---|---|
| **Shelf** (home) | Tap a globe to open it. The **photo button** (top right) adds a globe from a photo. Long-press a globe to rename, rebuild or delete it. |
| **Add a globe** | Choose a photo (its GPS location is read from the photo's metadata) or search for a place. Pick the size (Block 150 m → Landscape 1.5 km) and style (Satellite / Map / Winter), then **Make Snowglobe**. |
| **Globe** | Drag sideways to spin it, drag up/down to tilt, pinch to zoom, double-tap to reset. The first time a globe is opened, a **size slider** picks how much of the place fits under the glass (¼× to 4× its starting size); **Lock In Size** (or leaving the globe) fixes it for good. While choosing, every zoom is cut from one wide download, so dragging never waits on the network; locking then downloads sharp tiles for just the chosen size. Pressing **Lock In Size** also hides the globe under a big **Shake to Reveal** cover: shake the iPhone (or press **Shake** on the cover) and it appears in a snowstorm. Snow is already drifting down when a globe opens (as if you'd just picked it up) and settles on the ground and roofs. **Shake your iPhone** for a snowstorm, twist it to swirl the snow, **tap the glass** to puff snow away from your finger, or press **Shake** to make the globe hop and rattle. Flick it to spin and the liquid lags behind, then keeps swirling. Snow always falls toward the real ground: **turn the iPhone upside down** and it sinks to the top of the glass and piles up there, then falls back when you turn it over again. Tip it more than ~40° and settled snow slides off the roofs. **Info** shows the map, data sources and a rebuild button. |
| **AR** | Move the phone to find a table or floor, tap to place the globe, then drag, rotate or pinch it. The globe stands on the table, so moving or turning the phone doesn't stir the snow or change which way it falls: dragging or twisting the globe sloshes it, tapping the globe puffs it up, and **Shake** makes the globe hop and rattle. |

---

## How it works

```
Globe location (lat/lon) + radius
        │
        ▼
TileSelector            walks Google's 3D Tiles tree and picks the ~60-70 tiles covering the circle,
                        at a detail level that suits the globe's size (8 m for a 300 m globe)
        ▼
TileDownloader          downloads the .glb tiles, 8 at a time (no Draco: Google serves plain glTF)
  + GLBParser           reads each tile's mesh, JPEG texture and copyright credits
        ▼
PhotorealDioramaBuilder Earth-centred coordinates → local meters, finds the ground, cuts a clean
                        circle, scales into globe units and squeezes tall towers under the dome
        ▼
PhotorealDioramaEntity  unlit textured RealityKit models (photos already contain real lighting)
        ▼
GlobeEntityFactory      pedestal + brass plaque + snow + the miniature + glass dome, in an ARView
```

Each globe's tiles are saved on the device after the first download (`TileStore`, in Application Support), so a globe downloads once and then opens offline.
Heads-up: Google's Map Tiles API policies only allow keeping tiles for their Cache-Control lifetime (a few hours). Keeping them is fine for a private prototype; set `TileStore.keepTilesForever = false` before any public release.
If loading fails (no key, offline), a little procedural village appears instead, with a Try Again button.

All globe geometry uses **globe units**: the glass sphere has radius 1, the pedestal top is at `y = -0.40`, `+X` = east, `-Z` = north. The whole globe is scaled to ~16 cm tall in AR. See `Snowglobe/Core/GlobeMetrics.swift`.

### Snow
```
how the glass moved ──► SnowController ──► SnowSimulation ──► SnowRenderer
 (spun, rattled, dragged   reads the globe's    1,500 flakes in a     one LowLevelMesh: a quad per
  in AR, the iPhone's own  motion each frame;   swirly liquid         flake, facing the camera,
  motion, taps)            taps → flick/knock                         rewritten each frame
```
- **The liquid** (`SnowSimulation`) is three flows that fade within seconds: *slosh* (the snow lags behind the glass's jolts), *swirl* (spin the glass and the liquid lags, then keeps turning after it stops, like tea in a cup), and *turbulence*, two layers of a chaotic, volume-preserving "ABC flow" plus each flake's own wandering, so a storm tumbles instead of flowing in streams. Flakes sink slowly, flutter, tumble, bounce off the glass, and come to rest where the flow is calm enough. A resting flake is picked up again when the flow around it beats its own lift threshold, so a gentle stir lifts only the lightest snow and a hard shake lifts all of it. Once everything rests, the simulation sleeps (no CPU) until something stirs it.
- **Where snow lands** is a top-down height map of the miniature (`SnowHeightField`), measured from Google's triangles while the place is built and carried on the content entity as a `SnowSurfaceComponent`, so snow settles on rooftops, treetops and streets, and slides off walls instead of popping onto roofs.
- **How the glass moved**: `SnowController` compares the globe's world transform frame to frame (`GlassMotionTracker`, smoothed so a slow finger drag doesn't read as jerking). On the globe screen it also reads Core Motion (`DeviceMotion`): the globe is "in your hand". In AR it isn't, so only the globe's own motion counts. The Shake button plays `GlobeRattle` (a hop, a rattle with haptic ticks, a landing), and the snow reacts to that motion like any other.
- **Which way is down**: on the globe screen, the iPhone's gravity, but only its tilt across the screen (turning the phone like a steering wheel). Tipping the phone back to look at it doesn't count, or the snow would always slide to the back of the globe. Lying flat, the snow keeps its last direction. In AR, down is the real world's down. Settled snow stays put on anything tipped less than snow's angle of repose (~37°). Past that it slides off, piling against walls and the glass, and on the glass each flake slides a little further or less far so the pile is thickest in the middle.
- **Drawing**: unlit, not tone-mapped white sprites (soft dots, plus star glints when a tumbling flake's face catches the light), with no depth writes. They are drawn after the far side of the glass and before the near side (`ModelSortGroupComponent`; the dome is two half-meshes), so snow always looks inside the glass. Reduce Motion skips the opening flurry and the rattle.

### Project layout
| Folder | What's inside |
|---|---|
| `Snowglobe/Core/` | Shared types: models (`SnowGlobe`), globe layout (`GlobeMetrics`), math helpers, theme colours, `Secrets`. |
| `Snowglobe/Services/Photos/` | Reads a photo's GPS location and capture date (`PhotoMetadataReader`) and names the place (`PlaceNamer`). |
| `Snowglobe/Services/GoogleTiles/` | Google Photorealistic 3D Tiles: client, tile selection, .glb parsing, circle cutting, loader. |
| `Snowglobe/Rendering/Globe/` | RealityKit globe: pedestal, glass dome, materials, lighting, photo-real miniature entities. |
| `Snowglobe/Rendering/Snow/` | The snow: physics (`SnowSimulation`), drawing (`SnowRenderer`), where it lands (`SnowSurface`), and the glue that feeds it the globe's and the iPhone's motion (`SnowController`, `DeviceMotion`, `GlobeRattle`). |
| `Snowglobe/Store/` | `GlobeStore` (saved globes) and the demo globes. |
| `Snowglobe/App/`, `Views/Shelf/` | App entry and the shelf home screen. |
| `Snowglobe/Views/Detail/` | Single-globe 3D view, touch controls, loading/credits overlay, the Shake to Reveal cover. |
| `Snowglobe/Views/Import/` | The sheet that turns a picked photo into a new globe. |
| `Snowglobe/Views/AR/` | AR placement: world tracking, coaching overlay, tap to place, move/rotate/resize gestures. |

The Xcode project uses a **synchronized folder**: any `.swift` file you create under `Snowglobe/` is compiled automatically. No project-file edits, no merge conflicts in `project.pbxproj`.

### Handy knobs
- **Look of the miniature:** `GlobeMetrics` (diorama size, building/terrain exaggeration, AR size, flake count).
- **Area presets:** `RadiusPreset` in `Core/SnowGlobe.swift`.
- **Snow feel:** constants at the top of the files in `Rendering/Snow/`: `SnowSimulation.Tuning` (flake sizes, sinking speed, how long storms last, how easily snow lifts), `SnowController.Tuning` (how hard shaking the iPhone stirs it), `GlobeRattle` (the Shake button's hop and rattle).
- **Colours & materials:** `Core/Theme.swift` and `Rendering/Globe/`.
- **Demo globes:** `Store/` (sample list); delete the app to see first-launch seeding again.

### Data & credits
- 3D places: Google Photorealistic 3D Tiles (Map Tiles API). The app shows "Google Maps" and the data credits from each tile while a globe is on screen, as Google's terms require.

### Ideas for next steps
- OSM `building:part` and roof shapes, landmarks, water surfaces.
- Shake sound effects, share a globe (USDZ export / image), iCloud sync for the shelf.
- A snow style per globe (classic snow, silver glitter, gold flakes), chosen when the globe is made.

### Troubleshooting
- **"Signing for Snowglobe requires a development team"**: pick a Team under Signing & Capabilities (see above).
- **A globe stays on "Building…"**: the Overpass servers can be busy. Long-press the globe ▸ *Rebuild*.
- **A globe shows a little generic village**: the map download failed (offline?), so the app used its procedural fallback. *Rebuild* once you're online.
- **"AR needs a real iPhone"**: expected in the Simulator.
