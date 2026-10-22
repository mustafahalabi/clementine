import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import words from './data/words.json';
import timeline from './data/timeline.json';
import {C} from './theme';
import {inter, tight} from './fonts';
import {FPS, prog, easeInOut} from './timing';
import {GestureDemo, GestureTiming} from './scenes/Gesture';
import {Launch} from './Launch';

// ---------------------------------------------------------------------------------------------------------------
// README teaser: one silent, seamless loop of the gesture.
export const TEASER_SECONDS = 10;
const teaserGesture: GestureTiming = {
  start: 0, grab: 0.9, dragEnd: 2.7, keyShow: 0.35, keyDown: 2.75, bloom: 2.9,
  hovers: [{slice: 2, at: 3.65}, {slice: 1, at: 4.1}, {slice: 0, at: 4.6}],
  drop: 5.3, done: 6.15, land: 6.45, end: TEASER_SECONDS, zoomOut: 8.1,
};

export const Teaser: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  // Cross-fade back into the opening frame so the loop has no seam.
  const back = prog(t, TEASER_SECONDS - 0.9, TEASER_SECONDS - 0.05, easeInOut);
  return (
    <AbsoluteFill>
      <GestureDemo t={t} frame={frame} g={teaserGesture} />
      {back > 0 && <AbsoluteFill style={{opacity: back}}><GestureDemo t={0} frame={0} g={teaserGesture} /></AbsoluteFill>}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
// Vertical 9:16 social cut: the film in the middle over a blurred copy, brand on top, live captions below.
type Wd = {w: string; s: number; e: number; p: number};
const offsets = words.paragraphs.map((p, i) => timeline.paragraphStarts[i] - p.s);
const timed = (words.words as Wd[]).map((w) => ({...w, s: w.s + offsets[w.p], e: w.e + offsets[w.p]}));
/** Caption lines: sentences, split further so a line never holds more than ~5 words. */
const lines = (() => {
  const out: (typeof timed)[] = [];
  let cur: typeof timed = [];
  timed.forEach((w, i) => {
    cur.push(w);
    const next = timed[i + 1];
    const end = /[.!?]$/.test(w.w) || /\.\.\.$/.test(w.w) || !next || next.p !== w.p || cur.length >= 5;
    if (end) { out.push(cur); cur = []; }
  });
  return out;
})();

const Captions: React.FC<{t: number}> = ({t}) => {
  const line = lines.find((l, i) => t >= l[0].s - 0.1 && t < (lines[i + 1]?.[0].s ?? l[l.length - 1].e + 0.8) - 0.1 && t < l[l.length - 1].e + 0.8);
  if (!line) return null;
  return (
    <div style={{fontFamily: tight, fontWeight: 700, fontSize: 64, lineHeight: 1.15, textAlign: 'center', letterSpacing: '-0.02em', padding: '0 70px'}}>
      {line.map((w, i) => (
        <span key={i} style={{color: t >= w.s ? 'white' : 'rgba(255,255,255,0.35)', textShadow: '0 4px 20px rgba(0,0,0,0.5)'}}>
          {w.w.replace('...', '…')}{i < line.length - 1 ? ' ' : ''}
        </span>
      ))}
    </div>
  );
};

export const Social: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const filmH = 1080 * (1080 / 1920);
  return (
    <AbsoluteFill style={{background: '#0A0605'}}>
      {/* Blurred copy fills the frame */}
      <AbsoluteFill style={{transform: 'scale(3.6)', filter: 'blur(28px) brightness(0.45) saturate(1.2)'}}>
        <div style={{position: 'absolute', left: 0, top: (1920 - filmH) / 2, width: 1080, height: filmH, overflow: 'hidden'}}>
          <div style={{width: 1920, height: 1080, transform: `scale(${1080 / 1920})`, transformOrigin: '0 0'}}><Launch audio={false} /></div>
        </div>
      </AbsoluteFill>
      <div style={{position: 'absolute', left: 0, top: 170, right: 0, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 22}}>
        <Img src={staticFile('icon.png')} style={{width: 92, height: 92}} />
        <div style={{fontFamily: tight, fontWeight: 700, fontSize: 64, color: 'white', letterSpacing: '-0.03em'}}>Clementine</div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 285, textAlign: 'center', fontFamily: inter, fontWeight: 500, fontSize: 34, color: C.peach}}>
        Hold ⇧ while you drag. Free for macOS.
      </div>
      <div style={{position: 'absolute', left: 0, top: 560, width: 1080, height: filmH, overflow: 'hidden', borderRadius: 28,
        boxShadow: '0 40px 90px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)'}}>
        <div style={{width: 1920, height: 1080, transform: `scale(${1080 / 1920})`, transformOrigin: '0 0'}}><Launch /></div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 1300}}><Captions t={t} /></div>
      <div style={{position: 'absolute', left: 0, right: 0, bottom: 150, textAlign: 'center', fontFamily: inter, fontWeight: 600, fontSize: 32,
        color: 'rgba(255,240,228,0.8)'}}>github.com/mustafahalabi/clementine</div>
    </AbsoluteFill>
  );
};

// Text layer of the social cut on a transparent background. render-cuts.sh composites it over the finished film
// with ffmpeg: rendering <Launch> twice (sharp + blurred) in one composition stalls Remotion's renderer.
export const SocialOverlay: React.FC = () => {
  const t = useCurrentFrame() / useVideoConfig().fps; // rendered at 30 fps, not the film's FPS
  const filmH = 1080 * (1080 / 1920);
  return (
    <AbsoluteFill>
      <div style={{position: 'absolute', left: 0, top: 170, right: 0, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 22}}>
        <Img src={staticFile('icon.png')} style={{width: 92, height: 92}} />
        <div style={{fontFamily: tight, fontWeight: 700, fontSize: 64, color: 'white', letterSpacing: '-0.03em'}}>Clementine</div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 285, textAlign: 'center', fontFamily: inter, fontWeight: 500, fontSize: 34, color: C.peach}}>
        Hold ⇧ while you drag. Free for macOS.
      </div>
      <div style={{position: 'absolute', left: 0, top: 560, width: 1080, height: filmH, boxShadow: '0 0 0 1px rgba(255,255,255,0.08)'}} />
      <div style={{position: 'absolute', left: 0, right: 0, top: 1300}}><Captions t={t} /></div>
      <div style={{position: 'absolute', left: 0, right: 0, bottom: 150, textAlign: 'center', fontFamily: inter, fontWeight: 600, fontSize: 32,
        color: 'rgba(255,240,228,0.8)'}}>github.com/mustafahalabi/clementine</div>
    </AbsoluteFill>
  );
};
