# Snowglobe ❄️

Turn the places in your photos into tiny 3D snowglobes.

Pick a photo → the app reads where it was taken → it builds a miniature of that spot (real buildings from OpenStreetMap, Apple Maps imagery on the ground, real terrain, little snowy trees) inside a glass globe on a wooden pedestal. Globes live on a shelf; tap one to see it up close, **shake your phone to make it snow**, and tap **View in AR** to put it on your desk.

> Hackathon prototype — SwiftUI + RealityKit + ARKit + MapKit. No API keys, no third-party packages, no tests.

## Status: stage 2 of 6
- [x] **1. Shelf**: home screen with four demo globes (2D drawings), rename/delete, tap to open a globe.
- [x] **2. Live 3D globe**: slim octagonal wooden base, brass name plaque, glass dome, placeholder village inside; drag to spin/tilt, pinch to zoom, double-tap to reset.
- [ ] **3. Snow + shake**: device shake / Shake button makes the snow swirl.
- [ ] **4. Real map data inside the globe**: approach being decided (Apple Maps imagery + OpenStreetMap 3D buildings, or Apple's own 3D map view behind the glass).
- [ ] **5. Add a globe from a photo's location.**
- [ ] **6. View in AR.**

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

### Simulator tips
- **Shake:** *Device ▸ Shake* in the Simulator menu (**⌃⌘Z**). There's also a Shake button on screen.
- **Photos with a location:** drag photos from your Mac (e.g. iPhone photos exported from Photos.app, which keep GPS) onto the Simulator window, or run
  ```bash
  xcrun simctl addmedia booted ~/Path/To/photo.jpg
  ```
- **No photo handy?** In the add sheet, tap *No photo? Pick a place* and search, or choose one of the *Famous places*.

---

## Using the app
| Screen | What you can do |
|---|---|
| **Shelf** (home) | Tap a globe to open it. **+** adds a globe. Long-press a globe to rename, rebuild or delete it. |
| **Add a globe** | Choose a photo (its GPS location is read from the photo's metadata) or search for a place. Pick the size (Block 150 m → Landscape 1.5 km) and style (Satellite / Map / Winter), then **Make Snowglobe**. |
| **Globe** | Drag sideways to spin it, drag up/down to tilt, pinch to zoom, double-tap to reset. Shake the phone, tap the globe, or press **Shake** to make it snow. **Info** shows the map, data sources and a rebuild button. |
| **AR** | Move the phone to find a table or floor, tap to place the globe, then drag, rotate or pinch it. Dragging it around makes the snow slosh. |

---

## How it works

```
Photo ──► GPS + date (ImageIO EXIF, or PHAsset.location)
             │
             ▼
   ┌─────────────── downloaded in parallel, cached per globe ───────────────┐
   │ OpenStreetMap (Overpass API)   buildings + heights, trees, parks/forests │
   │ Terrarium elevation tiles      terrain height map                        │
   │ Apple Maps (MKMapSnapshotter)  ground texture: satellite / map / winter  │
   └──────────────────────────────────────────────────────────────────────────┘
             │  DioramaData (meters)  ── offline fallback: procedural village
             ▼
   DioramaMeshBuilder  → terrain disk + extruded buildings + trees (globe units)
             ▼
   GlobeEntityFactory  → RealityKit entity: pedestal, brass plaque, diorama, glass
             ▼
   SnowSystem (RealityKit ECS) → flakes that swirl when shaken and settle on roofs
             ▼
   Shelf thumbnail (RealityRenderer, offscreen) · live 3D view (ARView) · AR (ARKit)
```

All globe geometry uses **globe units**: the glass sphere has radius 1, the pedestal top is at `y = -0.40`, `+X` = east, `-Z` = north. The whole globe is scaled to ~16 cm tall in AR. See `Snowglobe/Core/GlobeMetrics.swift`.

### Project layout
| Folder | What's inside |
|---|---|
| `Snowglobe/Core/` | Shared contracts: models (`SnowGlobe`), real-world geometry (`DioramaData`), globe layout (`GlobeMetrics`), mesh types, math helpers, theme colours. |
| `Snowglobe/Services/MapData/` | OpenStreetMap + terrain downloads, lat/lon ↔ meters, procedural fallback town. |
| `Snowglobe/Services/Location/` | Photo GPS extraction, reverse geocoding, place search, ground imagery. |
| `Snowglobe/Rendering/Mesh/` | Pure geometry: terrain, building extrusion, trees, polygon math, snow height field. |
| `Snowglobe/Rendering/Globe/` | RealityKit globe assembly, materials, procedural textures, lighting, thumbnails. |
| `Snowglobe/Rendering/Snow/` | Snow flakes + physics (`SnowSystem`) + `SnowController.shake(...)`. |
| `Snowglobe/Store/` | `GlobeStore`: persistence, background build queue, sample globes, entity cache. |
| `Snowglobe/App/`, `Views/Shelf/`, `Views/Add/` | App entry, shelf home screen, add-from-photo flow. |
| `Snowglobe/Views/Detail/`, `Views/AR/` | Single-globe 3D view, gestures, shake detection, AR placement. |

The Xcode project uses a **synchronized folder**: any `.swift` file you create under `Snowglobe/` is compiled automatically. No project-file edits, no merge conflicts in `project.pbxproj`.

### Handy knobs
- **Look of the miniature:** `GlobeMetrics` (diorama size, building/terrain exaggeration, AR size, flake count).
- **Area presets:** `RadiusPreset` in `Core/SnowGlobe.swift`.
- **Snow feel:** constants at the top of the files in `Rendering/Snow/`.
- **Colours & materials:** `Core/Theme.swift` and `Rendering/Globe/`.
- **Demo globes:** `Store/` (sample list); delete the app to see first-launch seeding again.

### Data & credits
- Map data © OpenStreetMap contributors (ODbL), via the public Overpass API. Builds run one at a time to respect its fair-use limits.
- Elevation: Terrain Tiles (Mapzen / AWS Open Data: SRTM, USGS and others).
- Ground imagery: Apple Maps via MapKit snapshots.

### Ideas for next steps
- Swap in Google Photorealistic 3D Tiles (needs an API key) for photogrammetry instead of extruded boxes.
- OSM `building:part` and roof shapes, landmarks, water surfaces.
- Shake sound effects, share a globe (USDZ export / image), iCloud sync for the shelf.
- Render snow with a single `LowLevelMesh` to support thousands of flakes.

### Troubleshooting
- **"Signing for Snowglobe requires a development team"**: pick a Team under Signing & Capabilities (see above).
- **A globe stays on "Building…"**: the Overpass servers can be busy. Long-press the globe ▸ *Rebuild*.
- **A globe shows a little generic village**: the map download failed (offline?), so the app used its procedural fallback. *Rebuild* once you're online.
- **"AR needs a real iPhone"**: expected in the Simulator.
