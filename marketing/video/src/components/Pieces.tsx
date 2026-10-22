import React from 'react';
import {Img, staticFile} from 'remotion';
import {C, accent} from '../theme';
import {inter, tight} from '../fonts';
import {FPS, clamp} from '../timing';
import {interpolate, spring} from 'remotion';

// ---------------------------------------------------------------------------------------------------------------
// The wheel, from real renders (`--render-wheel`, 3x, transparent). Canvas sizes are in points.
export type WheelSet =
  | 'photo-convert' | 'photo-tools' | 'video-convert' | 'video-tools' | 'audio-convert' | 'audio-tools'
  | 'doc-convert' | 'pdf-convert' | 'pdf-tools' | 'pdf2-tools' | 'zip-convert';
const canvas: Record<WheelSet, number> = {
  'photo-convert': 404, 'photo-tools': 464, 'video-convert': 404, 'video-tools': 444, 'audio-convert': 384, 'audio-tools': 444,
  'doc-convert': 384, 'pdf-convert': 384, 'pdf-tools': 384, 'pdf2-tools': 384, 'zip-convert': 384,
};
export const wheelCanvas = (set: WheelSet) => canvas[set];
export const wheelSlices: Record<WheelSet, number> = {
  'photo-convert': 9, 'photo-tools': 12, 'video-convert': 9, 'video-tools': 11, 'audio-convert': 6, 'audio-tools': 11,
  'doc-convert': 3, 'pdf-convert': 4, 'pdf-tools': 6, 'pdf2-tools': 7, 'zip-convert': 3,
};
/** Point (relative to the wheel centre, in points) over slice i. Slice 0 is at the top, then clockwise. */
export const slicePoint = (set: WheelSet, i: number, radiusFrac = 0.29) => {
  const n = wheelSlices[set];
  const a = (i / n) * Math.PI * 2;
  const r = wheelCanvas(set) * radiusFrac;
  return {x: Math.sin(a) * r, y: -Math.cos(a) * r};
};

/**
 * The wheel centred on (cx, cy). `appear` 0→1 is the bloom (scale, spin and focus, like the app's open animation);
 * `leave` 0→1 is the drop (a quick shrink and fade). `pt` is pixels per point.
 */
export const Wheel: React.FC<{
  set: WheelSet; hover: number | null; cx: number; cy: number; pt?: number; appear: number; leave?: number; glow?: boolean;
}> = ({set, hover, cx, cy, pt = 1, appear, leave = 0, glow = true}) => {
  const size = wheelCanvas(set) * pt;
  const a = Math.max(0, appear);
  const scale = (0.5 + 0.5 * a) * (1 - 0.12 * leave);
  const opacity = Math.min(1, a * 1.6) * (1 - leave);
  if (opacity <= 0.001) return null;
  return (
    <div style={{position: 'absolute', left: cx - size / 2, top: cy - size / 2, width: size, height: size, pointerEvents: 'none'}}>
      {glow && (
        <div style={{position: 'absolute', inset: -size * 0.25, borderRadius: '50%', opacity: opacity * 0.9,
          background: 'radial-gradient(circle, rgba(255,140,60,0.38) 0%, rgba(255,110,50,0.14) 38%, rgba(255,90,40,0) 62%)',
          transform: `scale(${0.6 + 0.5 * a})`}} />
      )}
      <Img
        src={staticFile(`app/wheels/${set}/${hover === null ? 'none' : hover}.png`)}
        style={{width: size, height: size, transform: `scale(${scale}) rotate(${(1 - Math.min(a, 1)) * -28}deg)`, opacity,
          filter: `blur(${Math.max(0, 1 - a) * 10 + leave * 6}px) drop-shadow(0 30px 60px rgba(0,0,0,0.45))`}}
      />
    </div>
  );
};

// ---------------------------------------------------------------------------------------------------------------
/** Kinetic type: words rise out of a soft blur, one after another (or at given times). */
export const Kinetic: React.FC<{
  text: string; t: number; at: number; times?: number[]; stagger?: number; size?: number; weight?: number; color?: string;
  font?: string; align?: 'left' | 'center' | 'right'; out?: number; tracking?: number; lineHeight?: number;
  gradientWords?: number[]; style?: React.CSSProperties; maxWidth?: number;
}> = ({text, t, at, times, stagger = 0.07, size = 96, weight = 700, color = 'white', font = tight, align = 'center', out,
  tracking = -0.03, lineHeight = 1.05, gradientWords = [], style, maxWidth}) => {
  const words = text.split(' ');
  const outP = out === undefined ? 0 : interpolate(t, [out, out + 0.4], [0, 1], clamp);
  return (
    <div style={{fontFamily: font, fontSize: size, fontWeight: weight, color, textAlign: align, letterSpacing: `${tracking}em`,
      lineHeight, maxWidth, ...style}}>
      {words.map((w, i) => {
        const start = times ? times[i] ?? times[times.length - 1] : at + i * stagger;
        const s = spring({frame: Math.round((t - start) * FPS), fps: FPS, config: {mass: 1, stiffness: 170, damping: 20}});
        const grad = gradientWords.includes(i);
        return (
          <span key={i} style={{display: 'inline-block', whiteSpace: 'pre', opacity: Math.min(1, s * 1.4) * (1 - outP),
            transform: `translateY(${(1 - s) * size * 0.45 - outP * size * 0.2}px)`, filter: `blur(${(1 - s) * size * 0.12 + outP * 10}px)`,
            ...(grad ? {background: `linear-gradient(120deg, ${C.peach}, ${C.tangerine} 45%, ${C.blood})`, WebkitBackgroundClip: 'text',
              backgroundClip: 'text', color: 'transparent'} : {})}}>
            {w}{i < words.length - 1 ? ' ' : ''}
          </span>
        );
      })}
    </div>
  );
};

// ---------------------------------------------------------------------------------------------------------------
/** Clementine's progress card, rebuilt from ProgressWindow's look (Theme surface, accent → success). */
export const ProgressCard: React.FC<{title: string; file: string; progress: number; done: number; width?: number}> = ({title, file, progress, done, width = 440}) => (
  <div style={{width, borderRadius: 24, padding: '22px 24px', boxSizing: 'border-box', display: 'flex', gap: 18, alignItems: 'center',
    background: done > 0.5 ? 'linear-gradient(160deg, rgba(36,52,42,0.94), rgba(30,33,30,0.94))' : 'linear-gradient(160deg, rgba(58,44,36,0.95), rgba(38,32,29,0.95))',
    border: '1px solid rgba(255,255,255,0.10)', boxShadow: '0 30px 60px rgba(0,0,0,0.45)', fontFamily: inter}}>
    <div style={{width: 52, height: 52, borderRadius: 26, flexShrink: 0, display: 'grid', placeItems: 'center',
      background: done > 0.5 ? `linear-gradient(135deg, ${C.leafLight}, ${C.leaf})` : accent,
      boxShadow: done > 0.5 ? '0 0 24px rgba(52,199,123,0.6)' : `0 0 24px ${C.glow}`}}>
      {done > 0.5 ? (
        <svg width="26" height="26" viewBox="0 0 26 26"><path d="M5 13.5 L11 19 L21 7" stroke="white" strokeWidth="3.4" fill="none" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="30" strokeDashoffset={30 * (1 - Math.min(1, (done - 0.5) * 2))} /></svg>
      ) : (
        <svg width="26" height="26" viewBox="0 0 26 26"><rect x="3" y="5" width="20" height="16" rx="3" stroke="white" strokeWidth="2.2" fill="none" /><circle cx="9" cy="10.5" r="2" fill="white" /><path d="M4 19 L10 14 L14 17 L18 13 L23 18" stroke="white" strokeWidth="2.2" fill="none" strokeLinejoin="round" /></svg>
      )}
    </div>
    <div style={{flex: 1, minWidth: 0}}>
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'baseline'}}>
        <div style={{color: 'white', fontWeight: 700, fontSize: 19}}>{title}</div>
        <div style={{color: C.leafLight, fontWeight: 700, fontSize: 16, opacity: done}}>Done</div>
      </div>
      <div style={{color: C.secondaryDark, fontSize: 15, marginTop: 3}}>{file}</div>
      <div style={{height: 7, borderRadius: 4, background: 'rgba(255,255,255,0.10)', marginTop: 12, overflow: 'hidden'}}>
        <div style={{height: '100%', width: `${progress * 100}%`, borderRadius: 4,
          background: done > 0.5 ? `linear-gradient(90deg, ${C.leafLight}, ${C.leaf})` : `linear-gradient(90deg, ${C.tangerine}, ${C.blood})`}} />
      </div>
    </div>
  </div>
);

/** A real app window render, with a macOS-like shadow. `w` is the display width in px. */
export const AppWindow: React.FC<{name: string; w: number; style?: React.CSSProperties; light?: boolean}> = ({name, w, style, light}) => (
  <Img src={staticFile(`app/ui/${name}-${light ? 'light' : 'dark'}.png`)}
    style={{width: w, borderRadius: w * 0.018, boxShadow: '0 40px 90px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08)', display: 'block', ...style}} />
);

/** Small rounded label. */
export const Chip: React.FC<{children: React.ReactNode; style?: React.CSSProperties; strong?: boolean}> = ({children, style, strong}) => (
  <div style={{display: 'inline-flex', alignItems: 'center', gap: 10, padding: '10px 20px', borderRadius: 999, fontFamily: inter,
    fontWeight: 600, fontSize: 22, color: strong ? 'white' : 'rgba(255,240,228,0.92)',
    background: strong ? accent : 'rgba(255,255,255,0.08)', border: '1px solid rgba(255,255,255,0.12)',
    boxShadow: strong ? `0 10px 30px ${C.glow}` : undefined, ...style}}>{children}</div>
);
