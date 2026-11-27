// Portlane Pen preview. Draws a directional cue over the editable track.
// The schematic path follows the connection initiator, independent of traffic.
precision mediump float;

/** @resolution */
uniform vec2 resolution;

/** @time */
uniform float elapsed;

/**
 * @label Preview phase
 * @default -1
 */
uniform float frozenPhase;

/**
 * @label Pulse tint
 * @color
 * @default #CDC5FF
 */
uniform vec3 tint;

/**
 * @label Direction
 * @default 1
 */
uniform float direction;

/**
 * @label Lane
 * @default 0
 */
uniform float lane;

/**
 * @label Alternate branch
 * @default -1
 */
uniform float branch;

float trackHeight(float x) {
    return 0.5 - lane * smoothstep(0.48, 0.84, x);
}

void main() {
    vec2 uv = gl_FragCoord.xy / resolution;
    float clock = frozenPhase < 0.0 ? elapsed / 2.75 : frozenPhase;
    float phase = fract(clock);
    float active = branch < 0.0 || mod(floor(clock), 2.0) == branch ? 1.0 : 0.0;
    float progress = mix(phase, 1.0 - phase, step(direction, -0.5));
    float head = mix(0.045, 0.955, progress);
    vec2 delta = (uv - vec2(head, trackHeight(head))) * resolution;
    float core = 1.0 - smoothstep(1.95, 3.15, length(delta));
    float halo = (1.0 - smoothstep(1.0, 9.0, length(delta))) * 0.34;
    float trailDistance = (head - uv.x) * direction * resolution.x;
    float trackDistance = abs(uv.y - trackHeight(uv.x)) * resolution.y;
    float trail = step(0.0, trailDistance) * exp(-max(0.0, trailDistance) / 15.0)
        * (1.0 - smoothstep(0.35, 1.5, trackDistance)) * 0.58;
    float edge = smoothstep(0.0, 0.12, phase) * (1.0 - smoothstep(0.88, 1.0, phase));
    float alpha = min(1.0, core + max(halo, trail)) * edge * active;
    gl_FragColor = vec4(tint * alpha, alpha);
}
