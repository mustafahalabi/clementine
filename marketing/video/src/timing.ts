import {Easing, interpolate, spring} from 'remotion';
import words from './data/words.json';
import timeline from './data/timeline.json';
import beats from './data/beats.json';

// Everything in the film is timed in seconds on the narration timeline and converted to frames here.
export const FPS = 60;
export const DURATION = timeline.duration;
export const sec = (s: number) => Math.round(s * FPS);

type Word = {w: string; s: number; e: number; p: number};
const ws = words.words as Word[];
const paras = words.paragraphs as {i: number; s: number; e: number; text: string}[];
const offsets = paras.map((p, i) => timeline.paragraphStarts[i] - p.s);
const clean = (s: string) => s.toLowerCase().replace(/[^a-z0-9']/g, '');

const find = (p: number, word: string, occ: number) => {
  let n = 0;
  for (const w of ws) {
    if (w.p === p && clean(w.w) === clean(word)) {
      if (n === occ) return w;
      n++;
    }
  }
  throw new Error(`No word "${word}" #${occ} in paragraph ${p}`);
};
/** Absolute start time (s) of a narration word. */
export const W = (p: number, word: string, occ = 0) => find(p, word, occ).s + offsets[p];
/** Absolute end time (s) of a narration word. */
export const WE = (p: number, word: string, occ = 0) => find(p, word, occ).e + offsets[p];

/** Where each narration paragraph sits on the timeline and which slice of the take it plays. */
export const narrationClips = paras.map((p, i) => {
  const prevEnd = i > 0 ? paras[i - 1].e : 0;
  const nextStart = i < paras.length - 1 ? paras[i + 1].s : p.e + 1;
  const lead = Math.min(0.12, (p.s - prevEnd) / 2);
  const tail = Math.min(0.35, (nextStart - p.e) / 2);
  return {start: timeline.paragraphStarts[i] - lead, from: p.s - lead, to: p.e + tail};
});

/** Seconds during which the narrator is speaking (for ducking). */
export const speechSpans = paras.map((p, i) => [timeline.paragraphStarts[i], timeline.paragraphStarts[i] + (p.e - p.s)]);

export const musicSections = timeline.musicSections;
export const beatTimes = beats.beats as number[];

// Motion helpers, all in seconds of the current frame.
export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
export const ease = Easing.bezier(0.22, 1, 0.36, 1); // easeOutQuint-ish, Apple-like settle
export const easeInOut = Easing.bezier(0.65, 0, 0.35, 1);

/** 0→1 over [a, b] seconds with an ease. */
export const prog = (t: number, a: number, b: number, e = ease) => interpolate(t, [a, b], [0, 1], {...clamp, easing: e});

/** A spring that starts at time `at` (s). */
export const springAt = (frame: number, at: number, config: Partial<{mass: number; stiffness: number; damping: number}> = {}) =>
  spring({frame: frame - sec(at), fps: FPS, config: {mass: 1, stiffness: 200, damping: 22, ...config}});

/** Fades in over `fin` after a and out over `fout` before b. */
export const window01 = (t: number, a: number, b: number, fin = 0.35, fout = 0.35) =>
  Math.min(prog(t, a, a + fin), 1 - prog(t, b - fout, b, easeInOut));
