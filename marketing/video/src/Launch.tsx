import React from 'react';
import {AbsoluteFill, Html5Audio, Sequence, staticFile, useCurrentFrame} from 'remotion';
import onsets from '../public/audio/sfx/onsets.json';
import {FPS, W, WE, narrationClips, prog, sec, speechSpans, window01, easeInOut} from './timing';
import {Hook, Problem, extTicks, problemSfxTimes} from './scenes/Opening';
import {GestureDemo, GestureTiming, Logo, gestureHoverTicks} from './scenes/Gesture';
import {EndCard, Montage, Privacy, Tools, montageHoverTimes, montageTimes, ringStart, toolTimes, tools, toolsBloom} from './scenes/Features';

export const heroGesture: GestureTiming = {
  start: 19.7,
  grab: 20.95,
  dragEnd: 23.45,
  keyShow: W(3, 'Shift') - 0.05,
  keyDown: 23.72,
  bloom: W(3, 'blooms') - 0.12,
  hovers: [{slice: 2, at: 24.8}, {slice: 1, at: 25.3}, {slice: 0, at: 25.85}],
  drop: W(4, 'Drop'),
  done: W(4, 'Drop') + 0.95,
  land: W(4, 'lands'),
  end: 30.6,
};

/** Shows children only inside [a, b] seconds (keeps renders cheap). */
const When: React.FC<{t: number; a: number; b: number; children: React.ReactNode}> = ({t, a, b, children}) =>
  t >= a && t < b ? <>{children}</> : null;

export const Launch: React.FC<{audio?: boolean}> = ({audio = true}) => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  // Whip from the desktop into the montage.
  const whip = prog(t, 30.15, 30.6, easeInOut);
  return (
    <AbsoluteFill style={{background: '#000'}}>
      <When t={t} a={0} b={6.15}><Hook t={t} frame={frame} /></When>
      <When t={t} a={5.85} b={16.6}><Problem t={t} frame={frame} /></When>
      <When t={t} a={19.6} b={30.6}>
        <AbsoluteFill style={{opacity: Math.min(prog(t, 19.6, 20.1), 1 - whip), transform: `translateX(${-whip * 500}px)`, filter: `blur(${whip * 18}px)`}}>
          <GestureDemo t={t} frame={frame} g={heroGesture} />
        </AbsoluteFill>
      </When>
      <When t={t} a={16.3} b={20.2}><Logo t={t} frame={frame} meet={W(2, 'Meet')} name={W(2, 'Clementine')} /></When>
      <When t={t} a={30.3} b={38.25}><Montage t={t} frame={frame} /></When>
      <When t={t} a={37.95} b={50.4}><Tools t={t} frame={frame} /></When>
      <When t={t} a={50.2} b={55.9}><Privacy t={t} frame={frame} /></When>
      <When t={t} a={55.5} b={65.1}><EndCard t={t} frame={frame} /></When>
      {audio && <Soundtrack />}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
type SfxName = keyof typeof onsets | 'bleep';
type Cue = {name: SfxName; at: number; vol: number; align?: 'onset' | 'peak'};

/** All sound effects, placed so the effect's transient (or peak) lands on the cue time. */
export const cues = (): Cue[] => {
  const p = problemSfxTimes();
  const list: Cue[] = [
    {name: 'drone', at: 0.0, vol: 0.2},
    ...extTicks().map((at) => ({name: 'tick' as const, at, vol: 0.35})),
    {name: 'whoosh', at: 5.85, vol: 0.4, align: 'peak'},
    {name: 'swipe', at: 6.05, vol: 0.35},
    {name: 'pop', at: p.fileIn + 0.12, vol: 0.3},
    {name: 'notify', at: p.wait, vol: 0.22},
    ...p.downloads.map((at) => ({name: 'tick' as const, at, vol: 0.4})),
    ...p.appPops.map((at) => ({name: 'pop' as const, at, vol: 0.16})),
    {name: 'riser', at: W(2, 'Clementine') + 0.05, vol: 0.28, align: 'peak'},
    {name: 'impact', at: W(2, 'Clementine'), vol: 0.22, align: 'peak'},
    {name: 'whoosh', at: 19.75, vol: 0.35, align: 'peak'},
    {name: 'tick', at: heroGesture.grab, vol: 0.35},
    {name: 'key', at: heroGesture.keyDown, vol: 0.6, align: 'peak'},
    {name: 'bloom', at: heroGesture.bloom, vol: 0.65},
    ...gestureHoverTicks(heroGesture).map((at) => ({name: 'tick' as const, at, vol: 0.45})),
    {name: 'pop', at: heroGesture.drop, vol: 0.55},
    {name: 'chime', at: heroGesture.done, vol: 0.4},
    {name: 'pop', at: heroGesture.land, vol: 0.5},
    {name: 'whoosh', at: 30.35, vol: 0.45, align: 'peak'},
    ...montageTimes().map((at) => ({name: 'swipe' as const, at: at - 0.1, vol: 0.32})),
    ...montageHoverTimes().slice(0, 6).map((at) => ({name: 'tick' as const, at, vol: 0.35})),
    {name: 'bloom', at: ringStart(), vol: 0.45},
    {name: 'whoosh', at: 37.95, vol: 0.35, align: 'peak'},
    {name: 'key', at: W(6, 'Option'), vol: 0.6, align: 'peak'},
    {name: 'bloom', at: toolsBloom(), vol: 0.6},
    ...toolTimes().map((at) => ({name: 'swipe' as const, at: at - 0.1, vol: 0.28})),
    ...toolTimes().map((at) => ({name: 'tick' as const, at: at - 0.05, vol: 0.32})),
    {name: 'bleep', at: WE(6, 'word') + 0.04, vol: 0.32},
    {name: 'whoosh', at: 50.0, vol: 0.35, align: 'peak'},
    {name: 'swipe', at: W(7, 'Nothing'), vol: 0.25},
    {name: 'impact', at: W(8, 'Clementine'), vol: 0.22, align: 'peak'},
    {name: 'key', at: W(8, 'Shift'), vol: 0.5, align: 'peak'},
    {name: 'chime', at: WE(8, 'drag') + 0.35, vol: 0.35},
  ];
  return list;
};

const offsetOf = (c: Cue) => {
  if (c.name === 'bleep') return 0;
  const o = onsets[c.name as keyof typeof onsets];
  return c.align === 'peak' ? o.peak : o.onset;
};

/** Music gain: ducks under the narration, with a low-passed version for the quiet privacy beat. */
const speechLevel = (t: number) => Math.max(0, ...speechSpans.map(([a, b]) => window01(t, a - 0.18, b + 0.3, 0.18, 0.4)));
export const MUSIC_UP = 0.36;
export const MUSIC_DUCKED = 0.11;
const lpMix = (t: number) => window01(t, 50.0, 55.9, 0.6, 0.5);
const musicGain = (t: number) => MUSIC_UP + (MUSIC_DUCKED - MUSIC_UP) * speechLevel(t);

export const Soundtrack: React.FC = () => (
  <>
    {narrationClips.map((c, i) => (
      <Sequence key={`n${i}`} from={sec(c.start)} durationInFrames={sec(c.to - c.from) + 1} layout="none">
        <Html5Audio src={staticFile('audio/narration-take1.mp3')} trimBefore={sec(c.from)} durationInFrames={sec(c.to - c.from)}
          volume={(f) => Math.min(1, f / 3, (sec(c.to - c.from) - f) / 4)} />
      </Sequence>
    ))}
    <Html5Audio src={staticFile('audio/music-take1.mp3')} volume={(f) => musicGain(f / FPS) * (1 - lpMix(f / FPS))} />
    <Html5Audio src={staticFile('audio/music-take1-lp.mp3')} volume={(f) => musicGain(f / FPS) * lpMix(f / FPS) * 1.5} />
    {cues().map((c, i) => {
      const start = Math.max(0, c.at - offsetOf(c));
      return (
        <Sequence key={`s${i}`} from={sec(start)} durationInFrames={sec(3)} layout="none">
          <Html5Audio src={staticFile(`audio/sfx/${c.name}.mp3`)} volume={c.vol} />
        </Sequence>
      );
    })}
  </>
);
