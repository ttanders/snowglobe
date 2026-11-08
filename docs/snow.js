// Gentle 2D snowfall behind the page (same idea as the app's FallingSnowView).
(() => {
    const canvas = document.getElementById("snow");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    // Same flakes every frame; only time moves them.
    let seed = 42;
    const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    const flakes = Array.from({ length: 70 }, () => ({
        x: random(), y: random(),
        speed: 10 + random() * 26,
        radius: 0.7 + random() * 1.8,
        phase: random() * Math.PI * 2,
    }));

    function resize() {
        const scale = window.devicePixelRatio || 1;
        canvas.width = innerWidth * scale;
        canvas.height = innerHeight * scale;
        ctx.setTransform(scale, 0, 0, scale, 0, 0);
    }

    function draw(timeMs) {
        const t = reduceMotion ? 0 : timeMs / 1000;
        ctx.clearRect(0, 0, innerWidth, innerHeight);
        const travel = innerHeight + 10;
        for (const f of flakes) {
            const y = ((f.y * travel + t * f.speed) % travel) - 5;
            const x = f.x * innerWidth + Math.sin(t * 0.5 + f.phase) * 14;
            ctx.beginPath();
            ctx.arc(x, y, f.radius, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(255, 255, 255, ${0.18 + f.radius * 0.12})`;
            ctx.fill();
        }
        if (!reduceMotion) requestAnimationFrame(draw);
    }

    addEventListener("resize", resize);
    resize();
    requestAnimationFrame(draw);
})();
