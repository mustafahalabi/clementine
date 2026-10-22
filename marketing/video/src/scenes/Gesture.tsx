import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile} from 'remotion';
import {C} from '../theme';
import {inter, tight} from '../fonts';
import {FPS, clamp, easeInOut, ease, prog, springAt} from '../timing';
import {Cursor, DesktopIcon, KeyCap, MenuBar, Wallpaper} from '../components/Desktop';
import {Kinetic, ProgressCard, Wheel, slicePoint, wheelSlices} from '../components/Pieces';

/** Beats of the drag → bloom → hover → drop → result demo, in absolute seconds. */
export type GestureTiming = {
  start: number; grab: number; dragEnd: number; keyShow: number; keyDown: number; bloom: number;
  hovers: {slice: number; at: number}[]; drop: number; done: number; land: number; end: number;
  /** Optional: pull back to the wide shot (for loops). */
  zoomOut?: number;
};

const SET = 'photo-convert' as const;
const ORIGINAL = {x: 1600, y: 150};
const RESULT = {x: 1440, y: 150};
const WHEEL = {x: 960, y: 600};
const thumbCenter = (p: {x: number; y: number}) => ({x: p.x, y: p.y + 58});

type Pt = {t: number; x: number; y: number};
const lerpPath = (pts: Pt[], t: number) => {
  if (t <= pts[0].t) return pts[0];
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1];
    if (t <= b.t) {
      const k = easeInOut((t - a.t) / (b.t - a.t));
      return {t, x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k};
    }
  }
  return pts[pts.length - 1];
};

const cursorAt = (g: GestureTiming, t: number) => {
  const grab = thumbCenter(ORIGINAL);
  // The drag travels on a gentle curve from the file to where the wheel will open.
  if (t > g.grab + 0.12 && t < g.dragEnd) {
    const k = easeInOut((t - g.grab - 0.12) / (g.dragEnd - g.grab - 0.12));
    const c = {x: 1380, y: 560};
    return {x: (1 - k) ** 2 * grab.x + 2 * (1 - k) * k * c.x + k ** 2 * WHEEL.x, y: (1 - k) ** 2 * grab.y + 2 * (1 - k) * k * c.y + k ** 2 * WHEEL.y};
  }
  const pts: Pt[] = [
    {t: g.start, x: 1180, y: 820},
    {t: g.grab - 0.05, ...grab},
    {t: g.grab + 0.12, ...grab},
    {t: g.dragEnd, ...WHEEL},
  ];
  let last = g.dragEnd;
  for (const h of g.hovers) {
    const p = slicePoint(SET, h.slice, 0.31);
    const start = Math.max(last, h.at - 0.28);
    pts.push({...pts[pts.length - 1], t: start}, {t: h.at, x: WHEEL.x + p.x, y: WHEEL.y + p.y});
    last = h.at;
  }
  return lerpPath(pts, t);
};

/** Which slice the pointer is over (or null over the hub), from its position, like WheelModel's hit-testing. */
const hoverAt = (g: GestureTiming, t: number): number | null => {
  if (t < g.bloom) return null;
  const c = cursorAt(g, t);
  const dx = c.x - WHEEL.x, dy = c.y - WHEEL.y;
  if (Math.hypot(dx, dy) < 62) return null;
  const n = wheelSlices[SET];
  const ang = (Math.atan2(dx, -dy) * 180) / Math.PI;
  return ((Math.round(ang / (360 / n)) % n) + n) % n;
};

/** Times where the hovered slice changes (for the tick sound). */
export const gestureHoverTicks = (g: GestureTiming) => {
  const out: number[] = [];
  let prev: number | null = null;
  for (let f = Math.round(g.bloom * FPS); f < Math.round(g.drop * FPS); f++) {
    const h = hoverAt(g, f / FPS);
    if (h !== null && h !== prev) out.push(f / FPS);
    prev = h;
  }
  return out;
};

export const GestureDemo: React.FC<{t: number; frame: number; g: GestureTiming; showKey?: boolean}> = ({t, frame, g, showKey = true}) => {
  const c = cursorAt(g, t);
  const hover = hoverAt(g, t);
  const bloom = springAt(frame, g.bloom, {stiffness: 210, damping: 17});
  const leave = prog(t, g.drop, g.drop + 0.28);
  const dragging = t > g.grab && t < g.drop;
  const pressed = dragging ? 1 : t > g.grab - 0.05 && t < g.grab + 0.1 ? prog(t, g.grab - 0.05, g.grab) : 0;
  const land = springAt(frame, g.land, {stiffness: 260, damping: 14});
  const landGlow = interpolate(t, [g.land, g.land + 0.3, g.land + 2.2], [0, 1, 0.25], clamp);

  // Camera: wide → push into the wheel → pan to the files.
  const cam = (() => {
    const k1 = prog(t, g.dragEnd - 0.6, g.bloom + 0.6, easeInOut);
    const k2 = prog(t, g.drop + 0.05, g.drop + 0.95, easeInOut);
    const a = {x: 960, y: 540, s: 1};
    const b = {x: WHEEL.x, y: WHEEL.y + 22, s: 1.85};
    const d = {x: (ORIGINAL.x + RESULT.x) / 2, y: 230, s: 1.7};
    const m = {x: a.x + (b.x - a.x) * k1, y: a.y + (b.y - a.y) * k1, s: a.s + (b.s - a.s) * k1};
    const c0 = {x: m.x + (d.x - m.x) * k2, y: m.y + (d.y - m.y) * k2, s: m.s + (d.s - m.s) * k2};
    const k3 = g.zoomOut === undefined ? 0 : prog(t, g.zoomOut, g.zoomOut + 1.0, easeInOut);
    const c = {x: c0.x + (a.x - c0.x) * k3, y: c0.y + (a.y - c0.y) * k3, s: c0.s + (a.s - c0.s) * k3};
    // Keep the frame inside the desktop.
    const hw = 960 / c.s, hh = 540 / c.s;
    return {x: Math.min(1920 - hw, Math.max(hw, c.x)), y: Math.min(1080 - hh, Math.max(hh, c.y)), s: c.s};
  })();
  const drift = Math.sin(t * 0.5) * 3;

  const keyIn = springAt(frame, g.keyShow, {stiffness: 160, damping: 18});
  const keyPressed = interpolate(t, [g.keyDown - 0.06, g.keyDown, g.drop + 0.1, g.drop + 0.2], [0, 1, 1, 0], clamp);
  const keyOut = prog(t, g.drop + 0.05, g.drop + 0.4);
  const cardIn = springAt(frame, g.drop + 0.12, {stiffness: 200, damping: 20});
  const cardOut = prog(t, g.land + 1.0, g.land + 1.4);
  const progress = interpolate(t, [g.drop + 0.2, g.done], [0, 1], {...clamp, easing: ease});
  const done = prog(t, g.done, g.done + 0.25);

  return (
    <AbsoluteFill style={{overflow: 'hidden', background: '#000'}}>
      <AbsoluteFill style={{transformOrigin: '0 0', transform: `translate(${960 - cam.x * cam.s}px, ${540 - cam.y * cam.s + drift}px) scale(${cam.s})`}}>
        <Wallpaper t={t} />
        <MenuBar />
        {[
          {name: 'Notes.docx', kind: 'doc', ext: 'DOCX', y: 150},
          {name: 'Trip.mov', kind: 'video', ext: 'MOV', y: 300},
          {name: 'Interview.m4a', kind: 'audio', ext: 'M4A', y: 450},
          {name: 'Report.pdf', kind: 'pdf', ext: 'PDF', y: 600},
          {name: 'Photos.zip', kind: 'zip', ext: 'ZIP', y: 750},
        ].map((f) => <DesktopIcon key={f.name} name={f.name} kind={f.kind as never} ext={f.ext} x={1760} y={f.y} />)}
        <DesktopIcon name="Sunset.heic" kind="image" ext="HEIC" photo x={ORIGINAL.x} y={ORIGINAL.y} selected={t > g.grab - 0.05 && t < g.done} />
        <DesktopIcon name="Sunset.jpg" kind="image" ext="JPG" photo x={RESULT.x} y={RESULT.y} scale={land} opacity={Math.min(1, land * 2)} glow={landGlow}
          selected={t > g.land + 0.25} />
        <Wheel set={SET} hover={hover} cx={WHEEL.x} cy={WHEEL.y} appear={t >= g.bloom ? bloom : 0} leave={leave} />
        {/* The drag image under the pointer */}
        {dragging && (
          <div style={{position: 'absolute', left: c.x - 56 + bloom * 40, top: c.y - 38 + bloom * 40, width: 112, height: 75, borderRadius: 4, overflow: 'hidden',
            border: '3px solid rgba(253,251,248,0.9)', opacity: 0.7 - 0.45 * Math.min(1, bloom), transform: `scale(${1 - 0.35 * Math.min(1, bloom)})`, boxSizing: 'border-box', boxShadow: '0 12px 24px rgba(0,0,0,0.4)'}}>
            <Img src={staticFile('photo-thumb.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </div>
        )}
        <Cursor x={c.x} y={c.y} pressed={pressed} scale={1 / Math.max(1, cam.s * 0.8)} opacity={1 - prog(t, g.drop + 0.3, g.drop + 0.7)} />
      </AbsoluteFill>
      {/* Screen-space overlays */}
      {showKey && (
        <div style={{position: 'absolute', left: '50%', bottom: 70, display: 'flex', alignItems: 'center', gap: 28,
          transform: `translateX(-50%) translateY(${(1 - keyIn) * 160 + keyOut * 160}px)`, opacity: keyIn * (1 - keyOut)}}>
          <KeyCap symbol="⇧" label="shift" pressed={keyPressed} width={190} scale={0.82} />
          <div style={{fontFamily: inter, fontSize: 34, fontWeight: 600, color: 'white', textShadow: '0 2px 12px rgba(0,0,0,0.5)'}}>
            hold while you drag
          </div>
        </div>
      )}
      <div style={{position: 'absolute', left: 70, bottom: 70, transform: `translateY(${(1 - cardIn) * 140 + cardOut * 140}px)`,
        opacity: Math.min(1, cardIn * 1.5) * (1 - cardOut)}}>
        <ProgressCard title="Convert to JPG" file="Sunset.heic" progress={progress} done={done} />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
/** "Meet Clementine." Icon and wordmark. */
export const Logo: React.FC<{t: number; frame: number; meet: number; name: number}> = ({t, frame, meet, name}) => {
  const icon = springAt(frame, meet - 0.1, {stiffness: 120, damping: 13});
  const burst = interpolate(t, [name - 0.05, name + 0.25, name + 1.6], [0, 1, 0.35], clamp);
  const exit = prog(t, 19.45, 20.15, easeInOut);
  const bgIn = prog(t, meet - 0.6, meet + 0.4);
  const letters = 'Clementine'.split('');
  return (
    <AbsoluteFill style={{background: '#0A0605', opacity: 1 - prog(t, 19.85, 20.2)}}>
      <AbsoluteFill style={{opacity: bgIn, background: `radial-gradient(ellipse 60% 55% at 50% 45%, rgba(255,120,50,${0.18 + 0.32 * burst}), rgba(120,30,40,${0.15 * burst}) 45%, rgba(0,0,0,0) 75%)`}} />
      {/* Slice rays, a nod to the wheel */}
      <AbsoluteFill style={{opacity: burst * 0.5 * (1 - exit), transform: `rotate(${t * 6}deg) scale(${1 + exit})`}}>
        <svg viewBox="-960 -960 1920 1920" width="1920" height="1920" style={{position: 'absolute', left: 0, top: -420}}>
          {Array.from({length: 12}).map((_, i) => {
            const a1 = (i / 12) * Math.PI * 2, a2 = a1 + Math.PI / 30;
            return <path key={i} d={`M0 0 L${Math.sin(a1) * 1400} ${-Math.cos(a1) * 1400} L${Math.sin(a2) * 1400} ${-Math.cos(a2) * 1400} Z`} fill="rgba(255,170,100,0.10)" />;
          })}
        </svg>
      </AbsoluteFill>
      <div style={{position: 'absolute', left: 960, top: 410, transform: `translate(-50%, -50%) scale(${(0.4 + 0.6 * icon) * (1 + exit * 2.6)}) rotate(${(1 - icon) * -40}deg)`,
        opacity: Math.min(1, icon * 2) * (1 - exit), filter: `blur(${exit * 14}px) drop-shadow(0 30px 60px rgba(255,110,40,${0.25 + 0.35 * burst}))`}}>
        <Img src={staticFile('icon.png')} style={{width: 300, height: 300}} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 590, textAlign: 'center', fontFamily: tight, fontWeight: 700, fontSize: 132,
        letterSpacing: '-0.035em', color: 'white', opacity: 1 - exit, transform: `scale(${1 + exit * 0.3})`, filter: `blur(${exit * 10}px)`}}>
        {letters.map((l, i) => {
          const s = springAt(frame, name + i * 0.035, {stiffness: 160, damping: 17});
          return <span key={i} style={{display: 'inline-block', opacity: Math.min(1, s * 1.5), transform: `translateY(${(1 - s) * 70}px)`, filter: `blur(${(1 - s) * 12}px)`}}>{l}</span>;
        })}
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 780, opacity: 1 - exit}}>
        <Kinetic t={t} at={name + 0.75} text="The format wheel for your Mac." size={44} weight={500} font={inter} color={C.peach} stagger={0.05} tracking={-0.01} />
      </div>
    </AbsoluteFill>
  );
};
