// Snowglobe web viewer: shows a shared globe in live 3D in the browser.
//
// The link only describes the place (?t=title&s=subtitle&lat=…&lon=…&r=radius in meters).
// The real place comes from Google's Photorealistic 3D Tiles, streamed straight into the page,
// cut into a circle and stood inside a glass globe, the same layout as the app (GlobeMetrics.swift):
//   glass sphere radius 1 at the origin, ground at y = -0.40, diorama radius 0.8,
//   octagonal pedestal down to y = -0.77, everything in "globe units".

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { TilesRenderer } from "3d-tiles-renderer";
import { GoogleCloudAuthPlugin, ReorientationPlugin, TilesFadePlugin } from "3d-tiles-renderer/plugins";

const METRICS = {
    groundY: -0.40,
    dioramaRadius: 0.80,
    snowRingRadius: 0.912,
    baseRadius: 1.02,
    baseBottomY: -0.77,
    exaggeration: 1.6,   // vertical, so buildings and hills read well at miniature scale
    domeClearance: 0.88,
};

const CAMERA = {
    target: new THREE.Vector3(0, 0.08, 0),
    yaw: 0.3,
    pitch: 0.2,          // radians above the horizon
    distance: 3.7,
    distanceRange: [2.4, 6.0],
    pitchRange: [-0.1, 0.8],
    horizontalFov: 38,   // degrees
};

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
renderer.localClippingEnabled = false;

const scene = new THREE.Scene();
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;

// Far plane starts generous so tiles can load wherever the ground turns out to be,
// then tightens once the place is fitted (fewer far-away tiles to fetch).
const camera = new THREE.PerspectiveCamera(36, 1, 0.05, 1000);
const controls = new OrbitControls(camera, canvas);
controls.target.copy(CAMERA.target);
controls.enablePan = false;
controls.enableDamping = true;
controls.minDistance = CAMERA.distanceRange[0];
controls.maxDistance = CAMERA.distanceRange[1];
controls.minPolarAngle = Math.PI / 2 - CAMERA.pitchRange[1];
controls.maxPolarAngle = Math.PI / 2 - CAMERA.pitchRange[0];
controls.autoRotate = !matchMedia("(prefers-reduced-motion: reduce)").matches;
controls.autoRotateSpeed = 0.6;
controls.addEventListener("start", () => { controls.autoRotate = false; });

camera.position.copy(CAMERA.target).add(new THREE.Vector3(
    Math.sin(CAMERA.yaw) * Math.cos(CAMERA.pitch),
    Math.sin(CAMERA.pitch),
    Math.cos(CAMERA.yaw) * Math.cos(CAMERA.pitch),
).multiplyScalar(CAMERA.distance));
controls.update();
controls.saveState();
canvas.addEventListener("dblclick", () => controls.reset());

// Studio lights like the app's GlobeLighting: warm key, cool fill, blue rim.
const key = new THREE.DirectionalLight(0xffeed1, 2.6);
key.position.set(2.2, 3.6, 3.0);
const fill = new THREE.DirectionalLight(0xb3ccff, 0.8);
fill.position.set(-3, 1.2, 2);
const rim = new THREE.DirectionalLight(0x99bfff, 1.1);
rim.position.set(0, 2.5, -3);
scene.add(key, fill, rim, new THREE.HemisphereLight(0xc8d8ff, 0x2a1d12, 0.35));

// MARK: - The globe (glass, snow, pedestal, shelf)

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

const globeRoot = new THREE.Group();
scene.add(globeRoot);

// Pedestal: octagonal prism with a flat face toward +Z (where the plaque goes).
const pedestalHeight = METRICS.groundY - METRICS.baseBottomY;
const pedestal = new THREE.Mesh(
    new THREE.CylinderGeometry(METRICS.baseRadius, METRICS.baseRadius, pedestalHeight, 8),
    new THREE.MeshPhysicalMaterial({ color: 0x5c3821, roughness: 0.4, clearcoat: 0.7,
        map: woodTexture("#5c3821", "#2a170b", 512, 128, 11) }),
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

// Spruce shelf the globe stands on (same palette as the app's shelves).
const shelf = new THREE.Mesh(
    new THREE.BoxGeometry(3.6, 0.16, 1.7),
    new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.7,
        map: woodTexture("#735430", "#3d2914", 1024, 256, 3) }),
);
shelf.position.y = METRICS.baseBottomY - 0.08;
globeRoot.add(shelf);

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

// Snowflakes drifting inside the glass.
const FLAKES = 320;
const flakePositions = new Float32Array(FLAKES * 3);
const flakeSpeeds = new Float32Array(FLAKES);
function respawnFlake(i, anywhere) {
    for (;;) {
        const x = (Math.random() * 2 - 1) * 0.9, z = (Math.random() * 2 - 1) * 0.9;
        const top = Math.sqrt(Math.max(0, 0.9 * 0.9 - x * x - z * z));
        if (top <= 0) continue;
        const y = anywhere ? METRICS.groundY + Math.random() * (top - METRICS.groundY) : top;
        flakePositions.set([x, y, z], i * 3);
        flakeSpeeds[i] = 0.03 + Math.random() * 0.07;
        return;
    }
}
for (let i = 0; i < FLAKES; i++) respawnFlake(i, true);
const flakeGeometry = new THREE.BufferGeometry();
flakeGeometry.setAttribute("position", new THREE.BufferAttribute(flakePositions, 3));
const flakes = new THREE.Points(flakeGeometry, new THREE.PointsMaterial({
    color: 0xffffff, size: 0.018, transparent: true, opacity: 0.9, depthWrite: false,
}));
flakes.renderOrder = 11;
globeRoot.add(flakes);

function stepSnow(dt, t) {
    for (let i = 0; i < FLAKES; i++) {
        const k = i * 3;
        flakePositions[k + 1] -= flakeSpeeds[i] * dt;
        flakePositions[k] += Math.sin(t * 0.7 + i) * 0.002 * dt * 10;
        if (flakePositions[k + 1] < METRICS.groundY + 0.01) respawnFlake(i, false);
    }
    flakeGeometry.attributes.position.needsUpdate = true;
}

// MARK: - The real place (Google Photorealistic 3D Tiles)

// Keeps only the part of each tile inside the diorama circle and under the dome.
function clipToGlobe(material) {
    if (material.userData.snowglobeClip) return;
    material.userData.snowglobeClip = true;
    material.onBeforeCompile = (shader) => {
        shader.vertexShader = shader.vertexShader
            .replace("#include <common>", "#include <common>\nvarying vec3 vGlobePos;")
            .replace("#include <project_vertex>",
                "#include <project_vertex>\nvGlobePos = (modelMatrix * vec4(transformed, 1.0)).xyz;");
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
    const samples = [[0, 0]];
    for (let i = 0; i < 8; i++) {
        const a = (i / 8) * Math.PI * 2;
        samples.push([Math.cos(a) * 0.45, Math.sin(a) * 0.45]);
    }
    let lowest = Infinity;
    for (const [x, z] of samples) {
        raycaster.set(new THREE.Vector3(x, 500, z), new THREE.Vector3(0, -1, 0));
        const hit = raycaster.intersectObject(tiles.group, true)[0];
        if (hit) lowest = Math.min(lowest, hit.point.y);
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
        if (fitted) showStatus("");
        else showStatus("Building your miniature…");
    });
    tiles.addEventListener("load-error", ({ tile, error }) => {
        console.warn("Snowglobe: tile failed to load", error);
        if (!tile || !loadedAny) {
            showStatus("Couldn't load this place from Google. The web key may be missing the Map Tiles API or this site's address.");
        }
    });
    showStatus("Finding Google's 3D tiles…");
}

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
renderer.setAnimationLoop(() => {
    const dt = Math.min(clock.getDelta(), 0.1);
    stepSnow(dt, clock.elapsedTime);
    controls.update();
    camera.updateMatrixWorld();
    tiles?.update();
    renderer.render(scene, camera);
});
