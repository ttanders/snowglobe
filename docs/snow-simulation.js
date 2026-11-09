// The snow inside a globe, for the web viewer: a port of the app's SnowSimulation.swift (same
// tuning), so the snow behaves the same in the browser. ~1,500 flakes in a slow, syrupy liquid.
//
// Everything is in globe units (glass radius 1) and seen from the glass. When the glass is jerked
// one way, the snow lags the other way; when it's spun, the liquid lags behind and keeps swirling
// after the glass stops, like tea in a cup. The liquid's flow is slosh + swirl + turbulence (an
// "ABC flow"), all fading within seconds. Flakes ride the flow, sink while fluttering, bounce off
// the glass and come to rest on the ground and rooftops (`surface`), until stirred up again.
// Down is wherever `gravity` points.

const GROUND_Y = -0.40;
const SNOW_GROUND_TOP_Y = GROUND_Y + 0.01;

export const Tuning = {
    sizeRange: [0.009, 0.02],
    glitterShare: 0.18,
    sinkSpeedRange: [0.075, 0.13],
    gripRange: [3.5, 7],
    liftSpeedRange: [0.16, 0.85],
    flutter: 0.45,
    restHeight: 0.55,
    restingSpread: 0.84,

    turbulenceFade: 2.2,
    swirlFade: 2.6,
    sloshFade: 0.35,
    maxTurbulence: 1.1,
    maxSwirl: 9,
    maxSlosh: 2,
    eddyScale: 2.6,
    smallEddyScale: 6.1,
    smallEddyShare: 0.45,
    wanderTime: 0.5,
    wanderSpeed: 0.8,
    turbulenceLift: 0.5,
    lag: 0.45,
    swirlLag: 0.9,
    joltTurbulence: 0.11,
    swirlLift: 0.35,
    flickReach: 0.8,

    containment: 0.955,
    wallStep: 0.02,
    repose: 0.8,
    gravityRecheck: 0.9986,
    maxStep: 1 / 20,
};

// Small vector helpers on [x, y, z] arrays (kept allocation-light for 1,500 flakes a frame).
const v = (x = 0, y = 0, z = 0) => [x, y, z];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const scale = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const length = (a) => Math.hypot(a[0], a[1], a[2]);
const normalize = (a) => { const l = length(a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);
const lerp = (a, b, t) => a + (b - a) * t;
const smoothstep = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); };
function limited(a, maxLength) {
    const l = length(a);
    return l > maxLength ? scale(a, maxLength / l) : a;
}

/// Where snow rests: the topmost surface over a grid covering x, z ∈ [-extent, extent]
/// (row = z from -extent, column = x from -extent), nearest-cell lookup like the app's SnowHeightField.
export class SnowHeightField {
    constructor(resolution, extent, heights) {
        this.resolution = resolution;
        this.extent = extent;
        this.heights = heights;
    }

    static flat(resolution = 8, extent = 0.912, y = SNOW_GROUND_TOP_Y) {
        return new SnowHeightField(resolution, extent, new Float32Array(resolution * resolution).fill(y));
    }

    surfaceY(x, z) {
        const { resolution: n, extent: e } = this;
        if (Math.abs(x) > e || Math.abs(z) > e) return SNOW_GROUND_TOP_Y;
        const col = Math.min(n - 1, Math.max(0, Math.floor((x + e) / (2 * e) * n)));
        const row = Math.min(n - 1, Math.max(0, Math.floor((z + e) / (2 * e) * n)));
        return this.heights[row * n + col];
    }
}

export class SnowSimulation {
    constructor(flakeCount, surface = SnowHeightField.flat(), seed = Math.floor(Math.random() * 2 ** 31)) {
        this.surface = surface;
        this.isAsleep = false;
        this.time = 0;
        this.gravity = v(0, -1, 0);
        this.across1 = v(0, 0, 1);
        this.across2 = v(1, 0, 0);
        this.checkedGravity = v(0, -1, 0);
        this.turbulence = 0;
        this.swirl = 0;
        this.slosh = v();
        this.kick = v();
        this.flowClock = 0;
        this.flowPhases = v(1.3, 4.1, 2.7);
        this.smallFlowPhases = v(0.4, 2.2, 5.0);
        this.seed = seed % 2147483647 || 1;
        this.flakes = [];
        for (let i = 0; i < flakeCount; i++) this.flakes.push(this.makeFlake());
        this.settle();
    }

    // MARK: Setting the scene

    /// Lays every flake down on the ground and roofs, and stills the liquid.
    settle() {
        for (const f of this.flakes) {
            const radius = Math.sqrt(this.unit()) * Tuning.restingSpread;
            const angle = this.range(0, 2 * Math.PI);
            const x = Math.cos(angle) * radius, z = Math.sin(angle) * radius;
            f.position = v(x, this.restingY(x, z, f.size), z);
            f.velocity = v();
            f.isResting = true;
        }
        this.turbulence = 0;
        this.swirl = 0;
        this.slosh = v();
        this.kick = v();
        this.isAsleep = true;
        this.dropUnsupportedSnow();
    }

    /// Scatters every flake through the liquid, swirling gently: a globe just picked up.
    scatter() {
        this.wake();
        for (const f of this.flakes) {
            f.position = this.randomPointInLiquid(f.size);
            f.velocity = scale(this.randomDirection(), this.range(0, 0.1));
            f.isResting = false;
        }
        this.turbulence = Math.max(this.turbulence, 0.22);
        this.swirl += this.randomSign() * 0.5;
    }

    /// New ground and roofs: resting snow moves onto them, and flakes inside a building pop onto its roof.
    setSurface(field) {
        this.surface = field;
        for (const f of this.flakes) {
            if (this.isTouchingGlass(f)) continue;
            const floor = this.restingY(f.position[0], f.position[2], f.size);
            if (f.isResting || f.position[1] < floor) {
                f.position[1] = floor;
                f.velocity = v();
                f.isResting = true;
            }
        }
        this.dropUnsupportedSnow();
    }

    /// Which way is down for the snow (globe axes; any length).
    setGravity(direction) {
        const l = length(direction);
        if (l < 1e-4) return;
        const down = scale(direction, 1 / l);
        if (dot(down, this.gravity) >= 0.999999) return;
        this.gravity = down;
        const helper = Math.abs(down[1]) < 0.9 ? v(0, 1, 0) : v(1, 0, 0);
        this.across1 = normalize(cross(helper, down));
        this.across2 = cross(down, this.across1);
        if (dot(down, this.checkedGravity) < Tuning.gravityRecheck) {
            this.checkedGravity = down;
            this.dropUnsupportedSnow();
        }
    }

    // MARK: Stirring

    /// The glass moved: `velocityChange` (globe units/s, globe axes) and `spinChange` around its vertical axis (rad/s).
    jolt(velocityChange, spinChange) {
        const speed = length(velocityChange);
        if (speed <= 1e-5 && Math.abs(spinChange) <= 1e-5) return;
        this.wake();
        this.kick = sub(this.kick, scale(velocityChange, Tuning.lag));
        this.slosh = limited(sub(this.slosh, scale(velocityChange, Tuning.lag)), Tuning.maxSlosh);
        this.swirl = clamp(this.swirl - spinChange * Tuning.swirlLag, -Tuning.maxSwirl, Tuning.maxSwirl);
        this.turbulence = Math.min(Tuning.maxTurbulence, this.turbulence + speed * Tuning.joltTurbulence);
    }

    /// A shake by hand: settled snow is thrown up, the liquid churns and swirls a little.
    shake(strength = 1) {
        this.wake();
        this.turbulence = Math.min(Tuning.maxTurbulence, this.turbulence + 0.95 * strength);
        this.swirl = clamp(this.swirl + this.randomSign() * 1.2 * strength, -Tuning.maxSwirl, Tuning.maxSwirl);
        for (const f of this.flakes) {
            if (!f.isResting || this.unit() >= strength) continue;
            const angle = this.range(0, 2 * Math.PI);
            const sideways = this.range(0.2, 0.9) * strength;
            f.isResting = false;
            f.velocity = sub(
                add(scale(this.across1, Math.cos(angle) * sideways), scale(this.across2, Math.sin(angle) * sideways)),
                scale(this.gravity, this.range(0.6, 1.8) * strength));
            f.wander = scale(this.randomDirection(), Tuning.wanderSpeed);
        }
    }

    /// A finger flicking the glass at `point` (on the glass): nearby snow bursts away from the finger.
    flick(point, strength = 1) {
        this.wake();
        const inward = scale(normalize(point), -1);
        this.turbulence = Math.min(Tuning.maxTurbulence, this.turbulence + 0.35 * strength);
        this.slosh = limited(add(this.slosh, scale(inward, 0.25 * strength)), Tuning.maxSlosh);
        const reach = Tuning.flickReach;
        for (const f of this.flakes) {
            const offset = sub(f.position, point);
            const distance = length(offset);
            if (distance >= reach) continue;
            const falloff = 1 - distance / reach;
            const away = distance > 1e-4 ? scale(offset, 1 / distance) : inward;
            let push = scale(normalize(add(away, scale(inward, 0.5))), 2.4 * strength * falloff * falloff);
            if (f.isResting) {
                const up = scale(this.gravity, -1);
                const along = dot(push, up);
                push = add(push, scale(up, Math.abs(along) - along + (0.5 + this.range(0, 0.6)) * strength * falloff));
                f.isResting = false;
                f.velocity = push;
                f.wander = scale(this.randomDirection(), Tuning.wanderSpeed);
            } else {
                f.velocity = add(f.velocity, push);
            }
        }
    }

    /// A knock on the wooden base: the whole globe jumps a little and some snow hops up.
    knock(strength = 1) {
        this.wake();
        this.turbulence = Math.min(Tuning.maxTurbulence, this.turbulence + 0.28 * strength);
        this.slosh = limited(sub(this.slosh, scale(this.gravity, 0.35 * strength)), Tuning.maxSlosh);
    }

    // MARK: Stepping

    step(deltaTime) {
        const dt = Math.min(Math.max(deltaTime, 0), Tuning.maxStep);
        if (dt <= 0 || this.isAsleep) return;
        this.time += dt;

        this.turbulence *= Math.exp(-dt / Tuning.turbulenceFade);
        this.swirl *= Math.exp(-dt / Tuning.swirlFade);
        this.slosh = scale(this.slosh, Math.exp(-dt / Tuning.sloshFade));
        this.flowClock += dt * (0.35 + 1.3 * this.turbulence);
        const c = this.flowClock;
        this.flowPhases = v(1.3 + 0.9 * c, 4.1 - 0.7 * c, 2.7 + 0.8 * c);
        this.smallFlowPhases = v(0.4 - 1.7 * c, 2.2 + 1.5 * c, 5.0 + 1.9 * c);

        const kick = this.kick;
        this.kick = v();
        const kickSpeed = length(kick);
        const stirring = this.turbulence > 0.003 || Math.abs(this.swirl) > 0.01
            || dot(this.slosh, this.slosh) > 1e-5 || kickSpeed > 0;
        let anyDrifting = false;
        const wanderKeep = Math.exp(-dt / Tuning.wanderTime);
        const wanderNudge = Tuning.wanderSpeed * Math.sqrt(1 - wanderKeep * wanderKeep);

        for (const f of this.flakes) {
            if (f.isResting) {
                if (!stirring) continue;
                const agitation = this.liftingFlow(f.position) + kickSpeed + this.turbulence * Tuning.turbulenceLift;
                if (agitation <= f.liftSpeed) continue;
                f.isResting = false;
                f.velocity = add(this.flow(f.position), kick);
                f.velocity = sub(f.velocity, scale(this.gravity,
                    (0.2 + 0.3 * Math.min(agitation, 1.5)) * this.range(0.5, 1)));
            } else {
                f.velocity = add(f.velocity, kick);
            }
            if (this.turbulence > 0.01) {
                f.wander = add(scale(f.wander, wanderKeep), scale(this.randomDirection(), wanderNudge));
            }
            this.advance(f, dt);
            if (!f.isResting) anyDrifting = true;
        }

        if (!anyDrifting && !stirring) {
            this.isAsleep = true;
            this.turbulence = 0;
            this.swirl = 0;
            this.slosh = v();
        }
    }

    /// Moves one drifting flake through the liquid and handles the glass, the ground and walls.
    advance(f, dt) {
        const liquid = this.flow(f.position);
        const angle = f.phase + this.time * f.flutterRate;
        const flutter = scale(add(scale(this.across1, Math.cos(angle)), scale(this.across2, Math.sin(angle))),
            f.sinkSpeed * Tuning.flutter);
        let target = add(add(liquid, scale(this.gravity, f.sinkSpeed)), flutter);
        target = add(target, scale(f.wander, Math.min(this.turbulence, 1)));
        f.velocity = add(f.velocity, scale(sub(target, f.velocity), 1 - Math.exp(-f.grip * dt)));

        const old = f.position.slice();
        f.position = add(f.position, scale(f.velocity, dt));
        f.tumble += f.tumbleRate * dt * (1 + 2.5 * Math.min(1, length(f.velocity)));
        const calm = () => this.liftingFlow(f.position) < f.liftSpeed;

        // The glass: slide along it, bouncing back a little; snow settles on its low side when calm.
        let settlesOnGlass = false;
        const reach = Tuning.containment - f.size;
        const distanceSquared = dot(f.position, f.position);
        if (distanceSquared > reach * reach) {
            const normal = scale(f.position, 1 / Math.sqrt(distanceSquared));
            f.position = scale(normal, reach);
            const outward = dot(f.velocity, normal);
            if (outward > 0) f.velocity = sub(f.velocity, scale(normal, outward * 1.3));
            const stopsAt = Tuning.repose + (1 - Tuning.repose) * 0.85 * f.slide;
            settlesOnGlass = dot(normal, this.gravity) >= stopsAt && calm();
        }

        // The ground, roofs and walls.
        let floor = this.restingY(f.position[0], f.position[2], f.size);
        if (f.position[1] < floor) {
            const oldFloor = this.restingY(old[0], old[2], f.size);
            if (floor > oldFloor + Tuning.wallStep && old[1] >= oldFloor - 0.001) {
                // Drifted sideways into a wall: stay on this side of it…
                const intoX = f.position[0] - old[0], intoZ = f.position[2] - old[2];
                f.position[0] = old[0];
                f.position[2] = old[2];
                f.velocity[0] *= -0.3;
                f.velocity[2] *= -0.3;
                floor = oldFloor;
                // …and, tipped so far that the wall is the low side, pile up against it.
                if (-this.gravity[1] < Tuning.repose && intoX * this.gravity[0] + intoZ * this.gravity[2] > 0 && calm()) {
                    f.position[1] = Math.max(f.position[1], floor);
                    f.isResting = true;
                    f.velocity = v();
                    return;
                }
            }
            if (f.position[1] < floor) {
                f.position[1] = floor;
                if (-this.gravity[1] >= Tuning.repose) {
                    if (calm()) {
                        f.isResting = true;
                        f.velocity = v();
                        return;
                    }
                    f.velocity[1] = Math.abs(f.velocity[1]) * 0.3;
                } else {
                    f.velocity[1] = Math.max(f.velocity[1], 0);
                }
            }
        }
        if (settlesOnGlass) {
            f.isResting = true;
            f.velocity = v();
        }
    }

    // MARK: The liquid

    flow(p) {
        let u = add(add(this.slosh, scale(v(p[2], 0, -p[0]), this.swirl)), this.turbulentFlow(p));
        const r = length(p);
        if (r > 0.72) {
            const normal = scale(p, 1 / r);
            const outward = dot(u, normal);
            if (outward > 0) u = sub(u, scale(normal, outward * smoothstep(0.72, 0.93, r)));
        }
        return u;
    }

    liftingFlow(p) {
        return length(add(this.slosh, this.turbulentFlow(p)))
            + Tuning.swirlLift * Math.abs(this.swirl) * Math.hypot(p[0], p[2]);
    }

    turbulentFlow(p) {
        if (this.turbulence <= 0.0005) return v();
        const nearGlass = smoothstep(0.75, 0.95, length(p));
        const big = abcFlow(add(scale(p, Tuning.eddyScale), this.flowPhases));
        const small = abcFlow(add(scale(p, Tuning.smallEddyScale), this.smallFlowPhases));
        return scale(add(big, scale(small, Tuning.smallEddyShare)), this.turbulence / 1.5 * (1 - nearGlass));
    }

    // MARK: Helpers

    restingY(x, z, size) {
        return this.surface.surfaceY(x, z) + size * Tuning.restHeight;
    }

    dropUnsupportedSnow() {
        for (const f of this.flakes) {
            if (f.isResting && !this.isSupported(f)) {
                f.isResting = false;
                f.velocity = v();
                this.wake();
            }
        }
    }

    isSupported(f) {
        const p = f.position;
        if (this.isTouchingGlass(f) && dot(scale(p, 1 / length(p)), this.gravity) >= Tuning.repose) return true;
        if (p[1] <= this.restingY(p[0], p[2], f.size) + 0.005 && -this.gravity[1] >= Tuning.repose) return true;
        const dx = this.gravity[0], dz = this.gravity[2];
        const run = Math.hypot(dx, dz);
        if (run <= 1e-3) return false;
        const step = 2 * this.surface.extent / Math.max(this.surface.resolution, 1);
        return this.restingY(p[0] + dx / run * step, p[2] + dz / run * step, f.size) > p[1] + 0.005;
    }

    isTouchingGlass(f) {
        return length(f.position) >= Tuning.containment - f.size - 0.003;
    }

    wake() { this.isAsleep = false; }

    makeFlake() {
        const isGlitter = this.unit() < Tuning.glitterShare;
        const pick = this.unit();
        const heft = pick * pick;
        const size = lerp(Tuning.sizeRange[0], Tuning.sizeRange[1], heft) * (isGlitter ? 0.75 : 1);
        const sink = lerp(Tuning.sinkSpeedRange[0], Tuning.sinkSpeedRange[1], 0.35 * heft + 0.65 * this.unit())
            * (isGlitter ? 0.85 : 1);
        return {
            position: v(), velocity: v(), size, sinkSpeed: sink,
            grip: lerp(Tuning.gripRange[1], Tuning.gripRange[0], heft),
            liftSpeed: this.range(Tuning.liftSpeedRange[0], Tuning.liftSpeedRange[1]),
            phase: this.range(0, 2 * Math.PI),
            flutterRate: this.range(0.7, 1.8) * this.randomSign(),
            tumble: this.range(0, 2 * Math.PI),
            tumbleRate: this.range(1.5, 4.5) * (isGlitter ? 1.8 : 1) * this.randomSign(),
            isGlitter, slide: this.unit(), isResting: false, wander: v(),
        };
    }

    randomPointInLiquid(margin) {
        const reach = Tuning.containment - margin;
        for (let i = 0; i < 40; i++) {
            const p = scale(v(this.range(-1, 1), this.range(-1, 1), this.range(-1, 1)), reach);
            if (dot(p, p) < reach * reach && p[1] > this.restingY(p[0], p[2], margin) + 0.03) return p;
        }
        return v(0, 0.3, 0);
    }

    randomDirection() {
        const z = this.range(-1, 1);
        const angle = this.range(0, 2 * Math.PI);
        const r = Math.sqrt(Math.max(0, 1 - z * z));
        return v(r * Math.cos(angle), r * Math.sin(angle), z);
    }

    randomSign() { return this.unit() < 0.5 ? -1 : 1; }
    range(lo, hi) { return lo + (hi - lo) * this.unit(); }
    unit() {
        this.seed = (this.seed * 16807) % 2147483647;
        return (this.seed - 1) / 2147483646;
    }
}

/// One ABC (Arnold–Beltrami–Childress) flow with A = 1, B = 0.8, C = 0.6: chaotic, swirly and
/// volume-preserving, so it mixes the snow without bunching it up.
function abcFlow(q) {
    const sz = Math.sin(q[2]), cz = Math.cos(q[2]), sy = Math.sin(q[1]), cy = Math.cos(q[1]);
    const sx = Math.sin(q[0]), cx = Math.cos(q[0]);
    return [sz + 0.6 * cy, 0.8 * sx + cz, 0.6 * sy + 0.8 * cx];
}

/// The hop-and-rattle the Shake button plays (the app's GlobeRattle): offset (x sideways to the
/// viewer, y up) and roll around the viewing axis, over one second.
export const GlobeRattle = {
    duration: 1.0,
    pose(t) {
        const hop = 0.1, swing = 0.08, rattleStart = 0.12, rattleLength = 0.7, cycles = 3.5, landingStart = 0.78;
        if (!(t > 0 && t < this.duration)) return { x: 0, y: 0, roll: 0 };
        let y;
        if (t < 0.15) {
            const s = t / 0.15;
            y = hop * (1 - (1 - s) * (1 - s));
        } else if (t < landingStart) {
            y = hop + 0.012 * Math.sin((t - 0.15) * 2 * Math.PI * 2 * cycles / rattleLength);
        } else {
            const s = (t - landingStart) / (this.duration - landingStart);
            y = hop * (1 - s * s);
        }
        let x = 0;
        const s = (t - rattleStart) / rattleLength;
        if (s > 0 && s < 1) x = swing * Math.sin(s * 2 * Math.PI * cycles) * Math.sin(s * Math.PI);
        return { x, y, roll: -x * 1.2 };
    },
};
