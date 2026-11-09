// Snowglobe web viewer: shows a shared globe in live 3D in the browser, and plays like the app.
//
// The link only describes the place (?t=title&s=subtitle&lat=…&lon=…&r=radius in meters).
// The real place comes from Google's Photorealistic 3D Tiles, streamed straight into the page,
// cut into a circle and stood inside a glass globe, the same layout as the app (GlobeMetrics.swift):
//   glass sphere radius 1 at the origin, ground at y = -0.40, diorama radius 0.8,
//   octagonal pedestal down to y = -0.77, everything in "globe units".
//
// Like the app's globe screen (GlobeSceneView / SnowController): the globe sits on a turntable
// (drag sideways to spin it, with momentum), the camera orbits up and down and zooms, and the
// snow is a real simulation (snow-simulation.js): spinning swirls it, the Shake button makes the
// globe hop and rattle, tapping the glass flicks the snow, tapping the base knocks it, and on a
// phone, shaking or tilting the phone moves the snow.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { TilesRenderer } from "3d-tiles-renderer";
import { GoogleCloudAuthPlugin, ReorientationPlugin, TilesFadePlugin } from "3d-tiles-renderer/plugins";
import { SnowSimulation, SnowHeightField, GlobeRattle } from "./snow-simulation.js";

const METRICS = {
    groundY: -0.40,
    dioramaRadius: 0.80,
    snowRingRadius: 0.912,
    baseRadius: 1.02,
    baseBottomY: -0.77,
    exaggeration: 1.6,   // vertical, so buildings and hills read well at miniature scale
    domeClearance: 0.88,
};
const SNOW_GROUND_TOP_Y = METRICS.groundY + 0.01;

const CAMERA = {
    target: new THREE.Vector3(0, 0.08, 0),
    pitch: 0.2,          // radians above the horizon
    distance: 3.7,
    distanceRange: [2.4, 6.0],
    pitchRange: [-0.1, 0.8],
    horizontalFov: 38,   // degrees
};

// The turntable, as in the app's GlobeSceneCoordinator.
const TURNTABLE = {
    defaultYaw: 0.3,
    radiansPerPixel: 0.012,
    maxSpinSpeed: 8,     // radians / second
    spinDamping: 2.5,    // per second
};

// The iPhone's own motion, as in the app's SnowController.
const DEVICE = {
    acceleration: 18,        // globe units/s² per g
    stillness: 0.05,         // g
    twistStillness: 0.25,    // radians/s
    gravitySmoothing: 0.12,  // seconds
    flatPhone: 0.25,         // g across the screen
};

const FLAKE_COUNT = 1200;
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

// MARK: - Page setup

const params = new URLSearchParams(location.search);
const globe = {
    title: params.get("t") || "Snowglobe",
    subtitle: params.get("s") || "",
    lat: parseFloat(params.get("lat")),
    lon: parseFloat(params.get("lon")),
    radius: Math.min(Math.max(parseFloat(params.get("r")) || 300, 50), 5000),
};

const statusEl = document.getElementById("status");
const creditsEl = document.getElementById("credits");

function showStatus(message) {
    statusEl.textContent = message;
    statusEl.hidden = !message;
}

document.title = `${globe.title} · Snowglobe`;
document.getElementById("title").textContent = globe.title;
if (globe.subtitle) {
    const subtitleEl = document.getElementById("subtitle");
    subtitleEl.textContent = globe.subtitle;
    subtitleEl.hidden = false;
}

const hasPlace = Number.isFinite(globe.lat) && Number.isFinite(globe.lon)
    && Math.abs(globe.lat) <= 90 && Math.abs(globe.lon) <= 180;
if (hasPlace) {
    const fmt = (v, pos, neg) => `${Math.abs(v).toFixed(4)}° ${v >= 0 ? pos : neg}`;
    document.getElementById("coordinates").textContent = `${fmt(globe.lat, "N", "S")}, ${fmt(globe.lon, "E", "W")}`;
}

const apiKey = window.SNOWGLOBE_CONFIG?.googleMapsApiKey;
const hasKey = apiKey && apiKey !== "PASTE_YOUR_WEB_KEY_HERE";

// MARK: - Renderer, camera, controls

const canvas = document.getElementById("globe");
const stage = canvas.parentElement;
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;

const scene = new THREE.Scene();
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;

// Far plane starts generous so tiles can load wherever the ground turns out to be,
// then tightens once the place is fitted (fewer far-away tiles to fetch).
const camera = new THREE.PerspectiveCamera(36, 1, 0.05, 1000);
camera.position.copy(CAMERA.target).add(
    new THREE.Vector3(0, Math.sin(CAMERA.pitch), Math.cos(CAMERA.pitch)).multiplyScalar(CAMERA.distance));

// The camera only orbits up and down (and zooms); turning sideways spins the globe itself.
const controls = new OrbitControls(camera, canvas);
controls.target.copy(CAMERA.target);
controls.enablePan = false;
controls.enableDamping = true;
controls.minDistance = CAMERA.distanceRange[0];
controls.maxDistance = CAMERA.distanceRange[1];
controls.minPolarAngle = Math.PI / 2 - CAMERA.pitchRange[1];
controls.maxPolarAngle = Math.PI / 2 - CAMERA.pitchRange[0];
controls.minAzimuthAngle = 0;
controls.maxAzimuthAngle = 0;
controls.update();
controls.saveState();

// Studio lights like the app's GlobeLighting: warm key, cool fill, blue rim.
const key = new THREE.DirectionalLight(0xffeed1, 2.6);
key.position.set(2.2, 3.6, 3.0);
const fill = new THREE.DirectionalLight(0xb3ccff, 0.8);
fill.position.set(-3, 1.2, 2);
const rim = new THREE.DirectionalLight(0x99bfff, 1.1);
rim.position.set(0, 2.5, -3);
scene.add(key, fill, rim, new THREE.HemisphereLight(0xc8d8ff, 0x2a1d12, 0.35));

// MARK: - The globe (glass, snow, pedestal)

function woodTexture(base, grain, width = 512, height = 128, seed = 7) {
    const c = document.createElement("canvas");
    c.width = width; c.height = height;
    const g = c.getContext("2d");
    g.fillStyle = base;
    g.fillRect(0, 0, width, height);
    let s = seed;
    const rand = () => (s = (s * 16807) % 2147483647) / 2147483647;
    for (let i = 0; i < 40; i++) {
        const y = rand() * height, amp = 0.5 + rand() * 2.5, wave = 60 + rand() * 200, phase = rand() * 6.28;
        g.beginPath();
        for (let x = 0; x <= width; x += 4) g.lineTo(x, y + Math.sin(x / wave * 6.28 + phase) * amp);
        g.strokeStyle = grain;
        g.globalAlpha = 0.15 + rand() * 0.3;
        g.lineWidth = 0.6 + rand() * 1.4;
        g.stroke();
    }
    g.globalAlpha = 1;
    const texture = new THREE.CanvasTexture(c);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
    return texture;
}

function plaqueTexture(text) {
    const c = document.createElement("canvas");
    c.width = 512; c.height = 120;
    const g = c.getContext("2d");
    g.fillStyle = "#c9a35f";
    g.fillRect(0, 0, c.width, c.height);
    g.strokeStyle = "#7a5a2a";
    g.lineWidth = 6;
    g.strokeRect(6, 6, c.width - 12, c.height - 12);
    g.fillStyle = "#2e1c0c";
    g.textAlign = "center";
    g.textBaseline = "middle";
    let size = 54;
    do { g.font = `600 ${size}px Inter, system-ui, sans-serif`; size -= 2; } while (g.measureText(text).width > c.width - 50 && size > 20);
    g.fillText(text, c.width / 2, c.height / 2 + 2);
    const texture = new THREE.CanvasTexture(c);
    texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
}

/// The turntable: everything that makes up the globe. It spins, hops and rattles; the camera doesn't.
const globeRoot = new THREE.Group();
scene.add(globeRoot);
/// Inverse of globeRoot's world matrix, shared with shaders that need globe-local positions.
const globeInverse = { value: new THREE.Matrix4() };

// Pedestal: octagonal prism with a flat face toward +Z (where the plaque goes).
const pedestalHeight = METRICS.groundY - METRICS.baseBottomY;
const pedestal = new THREE.Mesh(
    new THREE.CylinderGeometry(METRICS.baseRadius, METRICS.baseRadius, pedestalHeight, 8),
    // White, so the colour comes only from the wood texture (tinting it too made it nearly black).
    new THREE.MeshPhysicalMaterial({ color: 0xffffff, roughness: 0.45, clearcoat: 0.6,
        map: woodTexture("#6b4429", "#2a170b", 512, 128, 11) }),
);
pedestal.rotation.y = Math.PI / 8;
pedestal.position.y = (METRICS.groundY + METRICS.baseBottomY) / 2;
globeRoot.add(pedestal);

const band = new THREE.Mesh(
    new THREE.CylinderGeometry(METRICS.baseRadius + 0.01, METRICS.baseRadius + 0.01, 0.035, 8, 1, true),
    new THREE.MeshStandardMaterial({ color: 0xe3b86b, metalness: 1, roughness: 0.28 }),
);
band.rotation.y = Math.PI / 8;
band.position.y = METRICS.groundY - 0.012;
globeRoot.add(band);

const apothem = METRICS.baseRadius * Math.cos(Math.PI / 8);
const plaque = new THREE.Mesh(
    new THREE.PlaneGeometry(0.62, 0.145),
    new THREE.MeshStandardMaterial({ map: plaqueTexture(globe.title), metalness: 0.6, roughness: 0.35 }),
);
plaque.position.set(0, pedestal.position.y - 0.01, apothem + 0.002);
globeRoot.add(plaque);

// Snow on the pedestal top, under and around the miniature.
const snowGround = new THREE.Mesh(
    new THREE.CircleGeometry(METRICS.snowRingRadius, 96),
    new THREE.MeshStandardMaterial({ color: 0xf2f7ff, roughness: 0.85 }),
);
snowGround.rotation.x = -Math.PI / 2;
snowGround.position.y = METRICS.groundY + 0.001;
globeRoot.add(snowGround);

// Glass dome: a sphere cut off where it meets the pedestal.
const glass = new THREE.Mesh(
    new THREE.SphereGeometry(1, 96, 64, 0, Math.PI * 2, 0, Math.acos(METRICS.groundY)),
    new THREE.MeshPhysicalMaterial({
        color: 0xffffff, metalness: 0, roughness: 0.04, transparent: true, opacity: 0.16,
        clearcoat: 1, clearcoatRoughness: 0.04, envMapIntensity: 1.4, depthWrite: false,
    }),
);
glass.renderOrder = 10;
globeRoot.add(glass);

// MARK: - Snow

const snow = new SnowSimulation(FLAKE_COUNT);
if (!reduceMotion) snow.scatter();   // as if the globe had just been picked up

// One point per flake: soft dots, sized in globe units, glinting as they tumble.
const flakePositions = new Float32Array(FLAKE_COUNT * 3);
const flakeSizes = new Float32Array(FLAKE_COUNT);
const flakeGlints = new Float32Array(FLAKE_COUNT);
const flakeGeometry = new THREE.BufferGeometry();
flakeGeometry.setAttribute("position", new THREE.BufferAttribute(flakePositions, 3));
flakeGeometry.setAttribute("aSize", new THREE.BufferAttribute(flakeSizes, 1));
flakeGeometry.setAttribute("aGlint", new THREE.BufferAttribute(flakeGlints, 1));
const flakeMaterial = new THREE.ShaderMaterial({
    uniforms: { uPixelsPerUnit: { value: 800 } },
    vertexShader: `
        attribute float aSize;
        attribute float aGlint;
        uniform float uPixelsPerUnit;
        varying float vGlint;
        void main() {
            vec4 mv = modelViewMatrix * vec4(position, 1.0);
            gl_Position = projectionMatrix * mv;
            gl_PointSize = max(1.5, 2.0 * aSize * uPixelsPerUnit / -mv.z);
            vGlint = aGlint;
        }`,
    fragmentShader: `
        varying float vGlint;
        void main() {
            float d = length(gl_PointCoord - 0.5);
            float alpha = smoothstep(0.5, 0.12, d) * (0.78 + 0.22 * vGlint);
            gl_FragColor = vec4(vec3(0.9 + 0.5 * vGlint), alpha);
        }`,
    transparent: true,
    depthWrite: false,
});
const flakes = new THREE.Points(flakeGeometry, flakeMaterial);
flakes.frustumCulled = false;
flakes.renderOrder = 11;
globeRoot.add(flakes);

function drawSnow() {
    const list = snow.flakes;
    for (let i = 0; i < list.length; i++) {
        const f = list[i];
        flakePositions[i * 3] = f.position[0];
        flakePositions[i * 3 + 1] = f.position[1];
        flakePositions[i * 3 + 2] = f.position[2];
        flakeSizes[i] = f.size;
        // Drifting flakes catch the light as they tumble; glitter flashes more often.
        flakeGlints[i] = f.isResting ? 0 : Math.pow(Math.max(0, Math.cos(f.tumble)), f.isGlitter ? 4 : 14);
    }
    flakeGeometry.attributes.position.needsUpdate = true;
    flakeGeometry.attributes.aSize.needsUpdate = true;
    flakeGeometry.attributes.aGlint.needsUpdate = true;
}
drawSnow();

// MARK: - The real place (Google Photorealistic 3D Tiles)

// Keeps only the part of each tile inside the diorama circle and under the dome (in globe space,
// so it stays put while the globe spins, hops and rattles).
function clipToGlobe(material) {
    if (material.userData.snowglobeClip) return;
    material.userData.snowglobeClip = true;
    material.onBeforeCompile = (shader) => {
        shader.uniforms.globeInverse = globeInverse;
        shader.vertexShader = shader.vertexShader
            .replace("#include <common>", "#include <common>\nuniform mat4 globeInverse;\nvarying vec3 vGlobePos;")
            .replace("#include <project_vertex>",
                "#include <project_vertex>\nvGlobePos = (globeInverse * modelMatrix * vec4(transformed, 1.0)).xyz;");
        shader.fragmentShader = shader.fragmentShader
            .replace("#include <common>", "#include <common>\nvarying vec3 vGlobePos;")
            .replace("void main() {", `void main() {
                float rho = length(vGlobePos.xz);
                if (rho > ${METRICS.dioramaRadius.toFixed(3)}) discard;
                if (vGlobePos.y > sqrt(max(1.0 - rho * rho, 0.0)) * ${METRICS.domeClearance.toFixed(3)}) discard;
                if (vGlobePos.y < ${(METRICS.groundY - 0.03).toFixed(3)}) discard;`);
    };
    material.customProgramCacheKey = () => "snowglobe-clip";
    material.needsUpdate = true;
}

let tiles = null;
const diorama = new THREE.Group();   // scales and lifts the real place into the globe
globeRoot.add(diorama);

function updateCredits() {
    if (!tiles) return;
    const attributions = tiles.getAttributions();
    creditsEl.replaceChildren();
    const google = document.createElement("strong");
    google.textContent = "Google Maps";
    creditsEl.append(google);
    for (const item of attributions) {
        if (item.type === "image") {
            const img = document.createElement("img");
            img.src = item.value;
            img.alt = "Google";
            creditsEl.append(img);
        } else if (item.type === "string" && item.value && item.value !== "Google") {
            const span = document.createElement("span");
            span.textContent = item.value;
            creditsEl.append(span);
        }
    }
    creditsEl.hidden = false;
}

// Lift the place so its streets / valley floor sit on the snow (the tiles start at sea level).
const raycaster = new THREE.Raycaster();
let fitted = false;
let fitAttempts = 0;
function fitGround() {
    if (!tiles || fitAttempts > 40) return;
    globeRoot.updateMatrixWorld(true);
    const down = new THREE.Vector3(0, -1, 0).applyQuaternion(globeRoot.quaternion);
    const samples = [[0, 0]];
    for (let i = 0; i < 8; i++) {
        const a = (i / 8) * Math.PI * 2;
        samples.push([Math.cos(a) * 0.45, Math.sin(a) * 0.45]);
    }
    let lowest = Infinity;
    for (const [x, z] of samples) {
        raycaster.set(globeRoot.localToWorld(new THREE.Vector3(x, 500, z)), down);
        const hit = raycaster.intersectObject(tiles.group, true)[0];
        if (hit) lowest = Math.min(lowest, globeRoot.worldToLocal(hit.point.clone()).y);
    }
    if (!Number.isFinite(lowest)) return;
    fitAttempts++;
    const shift = METRICS.groundY + 0.004 - lowest;
    diorama.position.y += shift;
    if (Math.abs(shift) < 0.003 && !fitted) {
        fitted = true;
        camera.far = 14;          // the place is in the glass now; skip tiles far outside it
        camera.updateProjectionMatrix();
    }
}

// MARK: - Where snow lands (rooftops and streets)

// The topmost surface of the place, measured by rendering it straight down from above with each
// pixel's height packed into its colour (like the app's SnowHeightField, 64 × 64 cells).
const SURFACE = { resolution: 64, extent: METRICS.snowRingRadius };
const heightTarget = new THREE.WebGLRenderTarget(SURFACE.resolution, SURFACE.resolution);
const heightRange = { min: METRICS.groundY - 0.05, span: 1.15 };
const heightMaterial = new THREE.ShaderMaterial({
    uniforms: { globeInverse },
    vertexShader: `
        uniform mat4 globeInverse;
        varying float vHeight;
        void main() {
            vHeight = (globeInverse * modelMatrix * vec4(position, 1.0)).y;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        }`,
    fragmentShader: `
        varying float vHeight;
        void main() {
            float h = clamp((vHeight - ${heightRange.min.toFixed(3)}) / ${heightRange.span.toFixed(3)}, 0.0, 1.0);
            float packed = floor(h * 65535.0);
            gl_FragColor = vec4(floor(packed / 256.0) / 255.0, mod(packed, 256.0) / 255.0, 0.0, 1.0);
        }`,
    side: THREE.DoubleSide,
    toneMapped: false,
});
const topCamera = new THREE.OrthographicCamera(-SURFACE.extent, SURFACE.extent, SURFACE.extent, -SURFACE.extent, 0.01, 6);
topCamera.up.set(0, 0, -1);           // top of the image = north (-z), like the app's grid rows
topCamera.position.set(0, 3, 0);
topCamera.lookAt(0, 0, 0);
globeRoot.add(topCamera);
const heightPixels = new Uint8Array(SURFACE.resolution * SURFACE.resolution * 4);

function measureSnowSurface() {
    globeRoot.updateMatrixWorld(true);
    globeInverse.value.copy(globeRoot.matrixWorld).invert();
    const hidden = [pedestal, band, plaque, snowGround, glass, flakes];
    hidden.forEach((o) => { o.visible = false; });
    const clearColor = renderer.getClearColor(new THREE.Color());
    const clearAlpha = renderer.getClearAlpha();
    renderer.setClearColor(0x000000, 0);
    scene.overrideMaterial = heightMaterial;
    renderer.setRenderTarget(heightTarget);
    renderer.clear();
    renderer.render(scene, topCamera);
    renderer.readRenderTargetPixels(heightTarget, 0, 0, SURFACE.resolution, SURFACE.resolution, heightPixels);
    renderer.setRenderTarget(null);
    scene.overrideMaterial = null;
    renderer.setClearColor(clearColor, clearAlpha);
    hidden.forEach((o) => { o.visible = true; });

    const n = SURFACE.resolution, e = SURFACE.extent;
    const heights = new Float32Array(n * n);
    for (let pixelRow = 0; pixelRow < n; pixelRow++) {
        const row = n - 1 - pixelRow;    // pixels are read bottom-up; grid row 0 is the north edge
        const z = -e + (row + 0.5) * (2 * e / n);
        for (let col = 0; col < n; col++) {
            const x = -e + (col + 0.5) * (2 * e / n);
            const rho = Math.hypot(x, z);
            const k = (pixelRow * n + col) * 4;
            let y = SNOW_GROUND_TOP_Y;
            if (heightPixels[k + 3] > 0 && rho < METRICS.dioramaRadius) {
                const h = (heightPixels[k] * 256 + heightPixels[k + 1]) / 65535;
                y = heightRange.min + h * heightRange.span;
                const dome = Math.sqrt(Math.max(0, 1 - rho * rho)) * METRICS.domeClearance;
                y = Math.min(Math.max(y, SNOW_GROUND_TOP_Y), dome);
            }
            heights[row * n + col] = y;
        }
    }
    snow.setSurface(new SnowHeightField(n, e, heights));
    drawSnow();
}

let surfaceTimer = null;
function measureSnowSurfaceSoon() {
    clearTimeout(surfaceTimer);
    surfaceTimer = setTimeout(measureSnowSurface, 1200);   // once tiles stop arriving for a moment
}

function startTiles() {
    const unitsPerMeter = METRICS.dioramaRadius / globe.radius;
    diorama.scale.set(unitsPerMeter, unitsPerMeter * METRICS.exaggeration, unitsPerMeter);

    tiles = new TilesRenderer();
    tiles.registerPlugin(new GoogleCloudAuthPlugin({ apiToken: apiKey, autoRefreshToken: true, useRecommendedSettings: true }));
    tiles.registerPlugin(new ReorientationPlugin({
        lat: THREE.MathUtils.degToRad(globe.lat),
        lon: THREE.MathUtils.degToRad(globe.lon),
        height: 0,
        up: "+y",
        recenter: true,
    }));
    tiles.registerPlugin(new TilesFadePlugin());
    tiles.setCamera(camera);
    tiles.setResolutionFromRenderer(camera, renderer);
    diorama.add(tiles.group);

    let loadedAny = false;
    tiles.addEventListener("load-model", ({ scene: model }) => {
        loadedAny = true;
        model.traverse((child) => {
            if (!child.isMesh) return;
            const materials = Array.isArray(child.material) ? child.material : [child.material];
            materials.forEach(clipToGlobe);
        });
    });
    tiles.addEventListener("tiles-load-end", () => {
        if (!loadedAny) return;
        fitGround();
        updateCredits();
        if (fitted) {
            showStatus("");
            measureSnowSurfaceSoon();
        } else {
            showStatus("Building your miniature…");
        }
    });
    tiles.addEventListener("load-error", ({ tile, error }) => {
        console.warn("Snowglobe: tile failed to load", error);
        if (!tile || !loadedAny) {
            showStatus("Couldn't load this place from Google. The web key may be missing the Map Tiles API or this site's address.");
        }
    });
    showStatus("Finding Google's 3D tiles…");
}

// MARK: - The turntable: drag to spin, tap to flick, double-tap to reset

let yaw = TURNTABLE.defaultYaw;
let spinVelocity = 0;
let rattleTime = null;      // seconds into a Shake rattle, or null
const pointers = new Map(); // active pointers (two = pinching)
let drag = null;            // { id, startX, startY, lastX, lastTime, velocity, moved, startTime }
let lastTapTime = 0;

canvas.addEventListener("pointerdown", (event) => {
    pointers.set(event.pointerId, event);
    if (pointers.size > 1) { drag = null; return; }
    drag = { id: event.pointerId, startX: event.clientX, startY: event.clientY, lastX: event.clientX,
        lastTime: performance.now(), velocity: 0, moved: false, startTime: performance.now() };
    spinVelocity = 0;
});

canvas.addEventListener("pointermove", (event) => {
    if (!drag || event.pointerId !== drag.id) return;
    const now = performance.now();
    const dx = event.clientX - drag.lastX;
    if (Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) > 8) drag.moved = true;
    yaw += dx * TURNTABLE.radiansPerPixel;
    const dt = Math.max((now - drag.lastTime) / 1000, 1 / 240);
    drag.velocity = drag.velocity * 0.6 + (dx * TURNTABLE.radiansPerPixel / dt) * 0.4;
    drag.lastX = event.clientX;
    drag.lastTime = now;
});

function endPointer(event) {
    pointers.delete(event.pointerId);
    if (!drag || event.pointerId !== drag.id) return;
    const wasTap = !drag.moved && performance.now() - drag.startTime < 350;
    if (wasTap) {
        // A single tap flicks straight away (it doesn't wait to rule out a double-tap), like the app.
        tap(event.clientX, event.clientY);
        if (performance.now() - lastTapTime < 320) resetView();
        lastTapTime = performance.now();
    } else if (performance.now() - drag.lastTime < 80) {
        // A flick keeps the globe spinning, slowing to a stop.
        spinVelocity = THREE.MathUtils.clamp(drag.velocity, -TURNTABLE.maxSpinSpeed, TURNTABLE.maxSpinSpeed);
    }
    drag = null;
}
canvas.addEventListener("pointerup", endPointer);
canvas.addEventListener("pointercancel", endPointer);

function resetView() {
    spinVelocity = 0;
    yaw = TURNTABLE.defaultYaw;
    controls.reset();
    lastTapTime = 0;
}

/// A tap on the glass flicks the snow away from the finger; a tap on the base knocks the globe.
function tap(clientX, clientY) {
    enableDeviceMotion();
    const rect = canvas.getBoundingClientRect();
    const ndc = new THREE.Vector2(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1);
    raycaster.setFromCamera(ndc, camera);
    globeRoot.updateMatrixWorld(true);
    const origin = globeRoot.worldToLocal(raycaster.ray.origin.clone());
    const direction = raycaster.ray.direction.clone().applyQuaternion(globeRoot.quaternion.clone().invert()).normalize();

    const t = hitSphere(origin, direction, 1);
    if (t !== null) {
        const point = origin.clone().addScaledVector(direction, t);
        if (point.y > METRICS.groundY) {
            snow.flick([point.x, point.y, point.z]);
            stirred();
            return;
        }
    }
    if (hitsBase(origin, direction)) {
        snow.knock();
        stirred();
    }
}

/// Distance along a unit ray to where it first enters (or, from inside, leaves) a sphere at the origin.
function hitSphere(origin, direction, radius) {
    const b = origin.dot(direction);
    const c = origin.dot(origin) - radius * radius;
    const discriminant = b * b - c;
    if (discriminant < 0) return null;
    const root = Math.sqrt(discriminant);
    if (-b - root >= 0) return -b - root;
    return -b + root >= 0 ? -b + root : null;
}

/// Whether a ray hits the pedestal (its sides, or the ring of its top around the glass).
function hitsBase(origin, direction) {
    const radius = METRICS.baseRadius + 0.06;
    const a = direction.x * direction.x + direction.z * direction.z;
    if (a > 1e-8) {
        const b = origin.x * direction.x + origin.z * direction.z;
        const c = origin.x * origin.x + origin.z * origin.z - radius * radius;
        const discriminant = b * b - a * c;
        if (discriminant >= 0) {
            const root = Math.sqrt(discriminant);
            for (const t of [(-b - root) / a, (-b + root) / a]) {
                if (t < 0) continue;
                const y = origin.y + direction.y * t;
                if (y >= METRICS.baseBottomY && y <= METRICS.groundY + 0.02) return true;
            }
        }
    }
    if (Math.abs(direction.y) > 1e-6) {
        const t = (METRICS.groundY - origin.y) / direction.y;
        if (t >= 0) {
            const x = origin.x + direction.x * t, z = origin.z + direction.z * t;
            if (Math.hypot(x, z) <= radius) return true;
        }
    }
    return false;
}

// MARK: - Shake

const shakeButton = document.getElementById("shake");
shakeButton?.addEventListener("click", () => {
    enableDeviceMotion();
    if (reduceMotion) {
        snow.shake();
    } else {
        rattleTime = 0;            // the globe hops and rattles; its motion stirs the snow
        snow.shake(0.5);
    }
    stirred();
});

/// Once the snow has been stirred, the hint has done its job.
function stirred() {
    const hint = document.getElementById("hint");
    if (hint && !hint.dataset.done) {
        hint.dataset.done = "1";
        hint.textContent = "Drag to spin · Pinch to zoom · Double-tap to reset";
    }
}

// MARK: - The phone's own motion

// Safari on iPhone only shares motion after asking, from a tap; elsewhere it just starts.
let motionRequested = false;
let latestMotion = null;
function enableDeviceMotion() {
    if (motionRequested || typeof DeviceMotionEvent === "undefined") return;
    motionRequested = true;
    const listen = () => addEventListener("devicemotion", (event) => { latestMotion = event; });
    if (typeof DeviceMotionEvent.requestPermission === "function") {
        DeviceMotionEvent.requestPermission().then((state) => { if (state === "granted") listen(); }).catch(() => {});
    } else {
        listen();
    }
}

// Browsers disagree on the sign of accelerationIncludingGravity. The phone is held the right way
// up when the page opens (you're looking at it), so the first clear reading decides which sign means down.
let gravitySign = 0;
let screenGravity = null;            // smoothed down across the screen (x right, y up), in g
let deviceDown = new THREE.Vector3(0, -1, 0);
let deviceSpin = 0;

/// A device-axes vector (x right, y up, z out of the screen) in screen axes, allowing for rotation.
function toScreen(x, y, z) {
    const angle = THREE.MathUtils.degToRad(screen.orientation?.angle ?? window.orientation ?? 0);
    const c = Math.cos(angle), s = Math.sin(angle);
    return new THREE.Vector3(x * c + y * s, -x * s + y * c, z);
}

/// Feeds the phone's motion to the snow: shaking jolts the glass, twisting turns it under the
/// liquid, and the tilt across the screen decides which way the snow sinks (like the app's SnowController).
function applyDeviceMotion(dt, globeInverseQuaternion) {
    const event = latestMotion;
    if (!event || dt <= 0) return;
    const withGravity = event.accelerationIncludingGravity;
    const motion = event.acceleration;
    if (!withGravity || withGravity.x === null) return;
    const ax = motion?.x ?? 0, ay = motion?.y ?? 0, az = motion?.z ?? 0;

    // Gravity alone, device axes, in g.
    const gx = (withGravity.x - ax) / 9.81, gy = (withGravity.y - ay) / 9.81, gz = (withGravity.z - az) / 9.81;
    if (gravitySign === 0) {
        const lean = gy + gz;   // held up or lying face up, down points along -y or -z
        if (Math.abs(lean) > 0.4) gravitySign = lean < 0 ? 1 : -1;
        else return;
    }
    const screenAxesToGlobe = (v) => v.applyQuaternion(camera.quaternion).applyQuaternion(globeInverseQuaternion);

    // Shaking: the phone's acceleration (made to follow the same sign as gravity) moves the glass.
    const acceleration = toScreen(-gravitySign * ax / 9.81, -gravitySign * ay / 9.81, -gravitySign * az / 9.81);
    const strength = acceleration.length();
    let velocityChange = [0, 0, 0];
    if (strength > DEVICE.stillness) {
        acceleration.multiplyScalar((strength - DEVICE.stillness) / strength);
        const v = screenAxesToGlobe(acceleration).multiplyScalar(DEVICE.acceleration * dt);
        velocityChange = [v.x, v.y, v.z];
        if (strength > 0.8) stirred();
    }
    // Twisting around the globe's vertical axis turns the glass under the liquid.
    const rate = event.rotationRate;
    let spinChange = 0;
    if (rate && rate.alpha !== null) {
        const r = toScreen(THREE.MathUtils.degToRad(rate.beta ?? 0), THREE.MathUtils.degToRad(rate.gamma ?? 0),
            THREE.MathUtils.degToRad(rate.alpha ?? 0));
        const twist = screenAxesToGlobe(r).y;
        const spin = Math.abs(twist) > DEVICE.twistStillness ? twist - DEVICE.twistStillness * Math.sign(twist) : 0;
        spinChange = spin - deviceSpin;
        deviceSpin = spin;
    }
    snow.jolt(velocityChange, spinChange);

    // Down for the snow: only the tilt across the screen counts (like turning a steering wheel).
    const across = toScreen(gravitySign * gx, gravitySign * gy, 0);
    if (!screenGravity) screenGravity = new THREE.Vector2(across.x, across.y);
    else screenGravity.lerp(new THREE.Vector2(across.x, across.y), 1 - Math.exp(-dt / DEVICE.gravitySmoothing));
    const g = screenGravity.length();
    if (g > DEVICE.flatPhone) {
        const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion);
        right.y = 0;
        if (right.lengthSq() < 1e-6) right.set(1, 0, 0);
        right.normalize();
        deviceDown = right.multiplyScalar(screenGravity.x / g).add(new THREE.Vector3(0, screenGravity.y / g, 0));
    }
}

// MARK: - How the glass moved (the app's GlassMotionTracker)

const tracker = {
    previousPosition: null, previousQuaternion: null,
    velocity: new THREE.Vector3(), spin: 0,
    update(position, quaternion, dt) {
        const result = { velocityChange: [0, 0, 0], spinChange: 0 };
        const last = this.previousPosition;
        const lastQ = this.previousQuaternion;
        this.previousPosition = position.clone();
        this.previousQuaternion = quaternion.clone();
        if (!(dt > 0) || !last) { this.velocity.set(0, 0, 0); this.spin = 0; return result; }

        const moved = position.clone().sub(last);
        const turn = lastQ.clone().invert().multiply(quaternion);   // this frame's turn, in the globe's axes
        if (turn.w < 0) turn.set(-turn.x, -turn.y, -turn.z, -turn.w);
        const angle = 2 * Math.acos(Math.min(1, turn.w));
        if (moved.length() >= 0.5 || angle >= 0.5) { this.velocity.set(0, 0, 0); this.spin = 0; return result; }

        const newVelocity = this.velocity.clone().add(moved.divideScalar(dt).sub(this.velocity).multiplyScalar(1 - Math.exp(-dt / 0.08)));
        const sinHalf = Math.sqrt(Math.max(0, 1 - turn.w * turn.w));
        const rawSpin = angle > 1e-7 && sinHalf > 1e-7 ? (turn.y / sinHalf) * angle / dt : 0;
        const newSpin = this.spin + (rawSpin - this.spin) * (1 - Math.exp(-dt / 0.15));
        const velocityChange = newVelocity.clone().sub(this.velocity).applyQuaternion(quaternion.clone().invert());
        let spinChange = newSpin - this.spin;
        this.velocity.copy(newVelocity);
        this.spin = newSpin;

        // Soft dead zones, so jitter doesn't keep stirring the snow.
        const acceleration = velocityChange.length() / dt;
        if (acceleration > 2) velocityChange.multiplyScalar((acceleration - 2) / acceleration);
        else velocityChange.set(0, 0, 0);
        const spinAcceleration = Math.abs(spinChange) / dt;
        spinChange = spinAcceleration > 1 ? spinChange * ((spinAcceleration - 1) / spinAcceleration) : 0;
        result.velocityChange = [velocityChange.x, velocityChange.y, velocityChange.z];
        result.spinChange = spinChange;
        return result;
    },
};

// MARK: - Sizing and the render loop

function resize() {
    const { clientWidth: w, clientHeight: h } = stage;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    // Keep the whole globe in view: horizontal FOV on portrait screens, a minimum vertical FOV on wide ones.
    const fromHorizontal = THREE.MathUtils.radToDeg(2 * Math.atan(Math.tan(THREE.MathUtils.degToRad(CAMERA.horizontalFov / 2)) / camera.aspect));
    camera.fov = Math.max(fromHorizontal, 34);
    camera.updateProjectionMatrix();
    // Pixels per globe unit one unit in front of the camera, for sizing the flakes.
    flakeMaterial.uniforms.uPixelsPerUnit.value =
        renderer.getDrawingBufferSize(new THREE.Vector2()).y / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2));
    tiles?.setResolutionFromRenderer(camera, renderer);
}
new ResizeObserver(resize).observe(stage);
resize();

if (!hasPlace) {
    showStatus("This link is missing the place. Ask for the link again from the Snowglobe app.");
} else if (!hasKey) {
    showStatus("This viewer isn't set up yet: add a Google Maps web key in config.js.");
} else {
    startTiles();
}

const clock = new THREE.Clock();
const yAxis = new THREE.Vector3(0, 1, 0);
const zAxis = new THREE.Vector3(0, 0, 1);
renderer.setAnimationLoop(() => {
    const dt = Math.min(clock.getDelta(), 0.1);

    // The turntable keeps spinning after a flick, slowing to a stop.
    if (!drag && Math.abs(spinVelocity) > 0.001) {
        yaw += spinVelocity * dt;
        spinVelocity *= Math.exp(-TURNTABLE.spinDamping * dt);
    }
    // A Shake rattle moves the whole globe: up, side to side (to the viewer) and back down.
    let pose = { x: 0, y: 0, roll: 0 };
    if (rattleTime !== null) {
        rattleTime += dt;
        pose = GlobeRattle.pose(rattleTime);
        if (rattleTime >= GlobeRattle.duration) rattleTime = null;
    }
    globeRoot.position.set(pose.x, pose.y, 0);
    globeRoot.quaternion.setFromAxisAngle(zAxis, pose.roll).multiply(new THREE.Quaternion().setFromAxisAngle(yAxis, yaw));
    globeRoot.updateMatrixWorld(true);
    globeInverse.value.copy(globeRoot.matrixWorld).invert();

    controls.update();
    camera.updateMatrixWorld();

    // The snow feels how the glass moved (spun, rattled) and how the phone moved.
    const motion = tracker.update(globeRoot.position, globeRoot.quaternion, dt);
    snow.jolt(motion.velocityChange, motion.spinChange);
    const toGlobe = globeRoot.quaternion.clone().invert();
    applyDeviceMotion(dt, toGlobe);
    const down = (latestMotion && gravitySign !== 0 ? deviceDown.clone() : new THREE.Vector3(0, -1, 0)).applyQuaternion(toGlobe);
    snow.setGravity([down.x, down.y, down.z]);
    if (!snow.isAsleep) {
        snow.step(dt);
        drawSnow();
    }

    tiles?.update();
    renderer.render(scene, camera);
});
