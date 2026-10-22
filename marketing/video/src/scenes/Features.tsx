import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile} from 'remotion';
import {C} from '../theme';
import {inter, tight} from '../fonts';
import {W, WE, clamp, easeInOut, prog, springAt} from '../timing';
import {Wallpaper, KeyCap, SliceGlyph} from '../components/Desktop';
import {AppWindow, Chip, Kinetic, ProgressCard, Wheel, WheelSet} from '../components/Pieces';

const DimWallpaper: React.FC<{t: number; dim?: number}> = ({t, dim = 0.5}) => (
  <AbsoluteFill>
    <AbsoluteFill style={{filter: 'blur(50px)', transform: 'scale(1.15)'}}><Wallpaper t={t} /></AbsoluteFill>
    <AbsoluteFill style={{background: `rgba(10,6,5,${dim})`}} />
    <AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 50%, rgba(0,0,0,0) 40%, rgba(0,0,0,0.55) 100%)'}} />
  </AbsoluteFill>
);

// ---------------------------------------------------------------------------------------------------------------
// 5. Montage by file type.
export const montage: {word: string; title: string; formats: string; set: WheelSet; hover: number; from: string; to: string}[] = [
  {word: 'Photos', title: 'Photos', formats: 'JPG · PNG · HEIC · WebP · AVIF · TIFF · GIF · PDF · Text', set: 'photo-convert', hover: 2, from: 'Sunset.heic', to: 'Sunset.webp'},
  {word: 'Video', title: 'Video', formats: 'MP4 · MOV · MKV · WebM · AVI · GIF · MP3', set: 'video-convert', hover: 5, from: 'Trip.mov', to: 'Trip.gif'},
  {word: 'Audio', title: 'Audio', formats: 'MP3 · M4A · WAV · FLAC · OGG · Opus · AIFF', set: 'audio-convert', hover: 0, from: 'Interview.m4a', to: 'Interview.mp3'},
  {word: 'Documents', title: 'Documents', formats: 'DOCX · RTF · TXT · Markdown · HTML → PDF', set: 'doc-convert', hover: 0, from: 'Notes.docx', to: 'Notes.pdf'},
  {word: 'PDFs', title: 'PDFs', formats: 'Text · DOCX · PNG and JPG pages', set: 'pdf-convert', hover: 2, from: 'Report.pdf', to: 'Report pages.png'},
  {word: 'Archives', title: 'Archives', formats: 'Extract ZIP · RAR · 7Z · TAR, or pack to ZIP', set: 'zip-convert', hover: 0, from: 'Photos.zip', to: 'Photos/'},
];
export const montageTimes = () => montage.map((m) => W(5, m.word));
export const montageHoverTimes = () => montageTimes().map((t) => t + 0.32);
export const ringStart = () => W(5, 'One') - 0.15;

export const Montage: React.FC<{t: number; frame: number}> = ({t, frame}) => {
  const times = montageTimes();
  const ring = ringStart();
  const enter = prog(t, 30.3, 30.7);
  const exit = prog(t, 37.7, 38.2, easeInOut);
  const idx = times.reduce((acc, tm, i) => (t >= tm - 0.12 ? i : acc), 0);
  const ringP = prog(t, ring - 0.2, ring + 0.2);
  return (
    <AbsoluteFill style={{opacity: enter * (1 - exit)}}>
      <DimWallpaper t={t} dim={0.55} />
      {montage.map((m, i) => {
        const at = times[i];
        const next = i < montage.length - 1 ? times[i + 1] - 0.12 : ring;
        if (t < at - 0.2 || t > next + 0.35) return null;
        const s = springAt(frame, at - 0.12, {stiffness: 220, damping: 18});
        const o = prog(t, next, next + 0.22);
        const hoverOn = t >= montageHoverTimes()[i];
        return (
          <AbsoluteFill key={m.word} style={{opacity: 1 - o}}>
            <div style={{position: 'absolute', left: 150, top: 380, transform: `translateX(${(1 - s) * -60 - o * 60}px)`, opacity: Math.min(1, s * 1.4)}}>
              <div style={{fontFamily: tight, fontWeight: 700, fontSize: 150, color: 'white', letterSpacing: '-0.04em', lineHeight: 1}}>{m.title}</div>
              <div style={{fontFamily: inter, fontWeight: 500, fontSize: 30, color: C.peach, marginTop: 26, maxWidth: 940, lineHeight: 1.4}}>{m.formats}</div>
              <div style={{marginTop: 40, opacity: hoverOn ? 1 : 0.0, transform: `translateY(${hoverOn ? 0 : 10}px)`}}>
                <Chip>{m.from}<span style={{color: C.tangerine}}>→</span>{m.to}</Chip>
              </div>
            </div>
            <Wheel set={m.set} hover={hoverOn ? m.hover : null} cx={1380} cy={540} pt={1.75} appear={s} leave={o} />
          </AbsoluteFill>
        );
      })}
      {/* One gesture, for all of it: every wheel at once, orbiting. */}
      {t > ring - 0.3 && (
        <AbsoluteFill style={{opacity: ringP}}>
          {montage.map((m, i) => {
            const s = springAt(frame, ring + i * 0.06, {stiffness: 200, damping: 18});
            const a = (i / montage.length) * Math.PI * 2 + (t - ring) * 0.25 - Math.PI / 2;
            const r = 400 * (0.7 + 0.3 * s);
            return <Wheel key={m.word} set={m.set} hover={m.hover} cx={960 + Math.cos(a) * r * 1.25} cy={540 + Math.sin(a) * r * 0.82} pt={0.62} appear={s} glow={false} />;
          })}
          <div style={{position: 'absolute', left: 0, right: 0, top: 450}}>
            <Kinetic t={t} at={W(5, 'One')} text="One gesture." size={110} times={[W(5, 'One'), W(5, 'gesture')]} />
            <Kinetic t={t} at={W(5, 'for')} text="For all of it." size={110} color={C.peach} times={[W(5, 'for'), W(5, 'all'), W(5, 'of'), W(5, 'it')]} />
          </div>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
// 6. Tools wheel and editors.
type Tool = {word: string; occ?: number; caption: string; set: WheelSet; hover: number; ui: string | 'compress'; w: number; h: number};
export const tools: Tool[] = [
  {word: 'Compress', caption: 'Compress', set: 'photo-tools', hover: 0, ui: 'compress', w: 880, h: 414},
  {word: 'Crop', caption: 'Crop', set: 'photo-tools', hover: 3, ui: 'editor-crop', w: 2000, h: 1440},
  {word: 'Redact', caption: 'Redact', set: 'photo-tools', hover: 6, ui: 'editor-redact', w: 2000, h: 1440},
  {word: 'Annotate', caption: 'Annotate', set: 'photo-tools', hover: 7, ui: 'editor-annotate', w: 2000, h: 1440},
  {word: 'Trim', caption: 'Trim', set: 'video-tools', hover: 2, ui: 'trim-video', w: 1280, h: 1320},
  {word: 'Bleep', caption: 'Bleep', set: 'audio-tools', hover: 8, ui: 'bleep', w: 1280, h: 1032},
  {word: 'Rearrange', caption: 'Pages', set: 'pdf-tools', hover: 1, ui: 'pages', w: 1560, h: 1344},
  {word: 'Merge', caption: 'Merge', set: 'pdf2-tools', hover: 4, ui: 'merge', w: 1560, h: 1264},
];
export const toolTimes = () => tools.map((x) => W(6, x.word));
export const toolsBloom = () => W(6, 'fills') - 0.08;

const EditorView: React.FC<{tool: Tool; t: number}> = ({tool, t}) => {
  if (tool.ui === 'compress') {
    const p = interpolate(t, [W(6, 'Compress') + 0.1, W(6, 'Compress') + 0.75], [0, 1], clamp);
    return (
      <div style={{display: 'flex', flexDirection: 'column', gap: 30, alignItems: 'center'}}>
        <AppWindow name="parameters" w={780} />
        <div style={{transform: 'scale(1.5)', transformOrigin: '50% 0'}}>
          <ProgressCard title="Compress" file="Sunset.heic" progress={p} done={prog(t, W(6, 'Compress') + 0.75, W(6, 'Compress') + 0.9)} />
        </div>
      </div>
    );
  }
  const k = Math.min(1060 / (tool.w / 2), 900 / (tool.h / 2));
  return <AppWindow name={tool.ui} w={(tool.w / 2) * k} />;
};

export const Tools: React.FC<{t: number; frame: number}> = ({t, frame}) => {
  const times = toolTimes();
  const enter = prog(t, 37.95, 38.3);
  const exit = prog(t, 49.75, 50.35, easeInOut);
  const keysIn = springAt(frame, 38.0, {stiffness: 170, damping: 18});
  const optDown = prog(t, W(6, 'Option') - 0.05, W(6, 'Option') + 0.02);
  const keysAway = prog(t, toolsBloom() - 0.3, toolsBloom() + 0.25, easeInOut);
  const bloom = springAt(frame, toolsBloom(), {stiffness: 190, damping: 16});
  const toSide = prog(t, times[0] - 0.55, times[0] + 0.05, easeInOut);
  const idx = times.reduce((acc, tm, i) => (t >= tm - 0.1 ? i : acc), -1);
  const cur = tools[Math.max(0, idx)];
  const setStart = (() => {
    let s = toolsBloom();
    for (let i = 1; i <= Math.max(0, idx); i++) if (tools[i].set !== tools[i - 1].set) s = times[i] - 0.1;
    return s;
  })();
  const reBloom = setStart === toolsBloom() ? bloom : springAt(frame, setStart, {stiffness: 260, damping: 18});
  const hover = idx >= 0 ? cur.hover : null;
  const wx = 960 + (520 - 960) * toSide, wy = 520 + (470 - 520) * toSide, pt = 1.6 + (1.3 - 1.6) * toSide;
  return (
    <AbsoluteFill style={{opacity: enter * (1 - exit), transform: `scale(${1 - exit * 0.05})`}}>
      <DimWallpaper t={t} dim={0.58} />
      {/* ⌥⇧ */}
      <div style={{position: 'absolute', left: '50%', top: 540, display: 'flex', gap: 34, alignItems: 'center',
        transform: `translate(-50%, -50%) translateY(${(1 - keysIn) * 120 + keysAway * 380}px) scale(${1.15 - keysAway * 0.45})`,
        opacity: Math.min(1, keysIn * 1.5) * (1 - keysAway)}}>
        <KeyCap symbol="⌥" label="option" pressed={optDown} width={190} />
        <div style={{fontFamily: tight, fontWeight: 600, fontSize: 70, color: 'rgba(255,255,255,0.7)'}}>+</div>
        <KeyCap symbol="⇧" label="shift" pressed={1} width={220} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 690, opacity: 1 - keysAway}}>
        <Kinetic t={t} at={W(6, 'Add')} text="Add Option for tools." size={60} weight={600} times={[W(6, 'Add'), W(6, 'Option'), W(6, 'wheel'), W(6, 'tools')]} color="rgba(255,255,255,0.92)" />
      </div>
      {t >= toolsBloom() && <Wheel set={cur.set} hover={hover} cx={wx} cy={wy} pt={pt} appear={reBloom} />}
      {/* Tool word under the wheel */}
      <div style={{position: 'absolute', left: 520 - 400, width: 800, top: 870, opacity: toSide}}>
        {tools.map((tool, i) => (
          i === idx ? <Kinetic key={tool.word} t={t} at={times[i]} text={tool.caption + '.'} size={84} weight={700} /> : null
        ))}
      </div>
      {/* Editors */}
      {tools.map((tool, i) => {
        const at = times[i];
        const next = i < tools.length - 1 ? times[i + 1] - 0.1 : 99;
        if (t < at - 0.2 || t > next + 0.45) return null;
        const s = springAt(frame, at - 0.1, {stiffness: 170, damping: 20});
        const o = prog(t, next, next + 0.35, easeInOut);
        return (
          <div key={tool.word} style={{position: 'absolute', left: 1330, top: 540, perspective: 1600,
            transform: `translate(-50%, -50%) translateX(${(1 - s) * 340 - o * 260}px) scale(${(0.9 + 0.1 * s) * (1 - o * 0.1)})`,
            opacity: Math.min(1, s * 1.5) * (1 - o), filter: `blur(${o * 8}px)`}}>
            <div style={{transform: `rotateY(${(1 - s) * -22 + o * 14}deg)`}}><EditorView tool={tool} t={t} /></div>
          </div>
        );
      })}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
// 7. Privacy.
export const Privacy: React.FC<{t: number; frame: number}> = ({t, frame}) => {
  const enter = prog(t, 50.25, 50.75);
  const exit = prog(t, 55.35, 55.85, easeInOut);
  const mac = springAt(frame, 50.3, {stiffness: 120, damping: 20});
  const cut = prog(t, W(7, 'Nothing') - 0.05, W(7, 'Nothing') + 0.35);
  const line1Out = W(7, 'Nothing') - 0.35;
  const dash = (t * 40) % 24;
  return (
    <AbsoluteFill style={{background: '#090605', opacity: enter * (1 - exit)}}>
      <AbsoluteFill style={{background: 'radial-gradient(ellipse 45% 40% at 50% 33%, rgba(255,120,50,0.20), rgba(0,0,0,0) 70%)'}} />
      <div style={{position: 'absolute', left: 960, top: 350, transform: `translate(-50%, -50%) scale(${0.9 + 0.1 * mac})`, opacity: mac}}>
        <svg width="1100" height="440" viewBox="-550 -220 1100 440" style={{overflow: 'visible'}}>
          {/* The Mac */}
          <rect x="-230" y="-150" width="460" height="290" rx="22" fill="rgba(255,255,255,0.03)" stroke="rgba(255,220,190,0.55)" strokeWidth="3" />
          <path d="M-60 140 L-75 190 H75 L60 140" fill="none" stroke="rgba(255,220,190,0.55)" strokeWidth="3" strokeLinejoin="round" />
          <line x1="-110" y1="190" x2="110" y2="190" stroke="rgba(255,220,190,0.55)" strokeWidth="3" strokeLinecap="round" />
          {/* The cloud, and the line to it that never carries anything */}
          <g transform="translate(420,-120)" opacity={1 - cut * 0.65}>
            <path d="M-70 30 a42 42 0 0 1 8-82 a58 58 0 0 1 108-6 a40 40 0 0 1 22 88 Z" fill="none" stroke="rgba(255,255,255,0.6)" strokeWidth="3" strokeLinejoin="round" />
          </g>
          <path d="M240 -40 C 300 -80, 330 -100, 350 -110" fill="none" stroke="rgba(255,255,255,0.45)" strokeWidth="3" strokeDasharray="10 14" strokeDashoffset={-dash} opacity={1 - cut} />
          <g transform="translate(298,-78)" opacity={cut} style={{transform: `translate(298px,-78px) scale(${0.5 + 0.5 * cut})`}}>
            <circle r="26" fill={C.cherry} />
            <path d="M-9 -9 L9 9 M9 -9 L-9 9" stroke="white" strokeWidth="4" strokeLinecap="round" />
          </g>
        </svg>
        <Img src={staticFile('icon.png')} style={{position: 'absolute', left: 550 - 80, top: 220 - 100, width: 160, height: 160,
          filter: 'drop-shadow(0 10px 30px rgba(255,120,50,0.5))'}} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 650}}>
        <Kinetic t={t} at={W(7, 'And')} text="All of it happens on your Mac." size={88} out={line1Out}
          times={[W(7, 'all'), W(7, 'of'), W(7, 'it'), W(7, 'happens'), W(7, 'on'), W(7, 'your'), W(7, 'Mac')]} gradientWords={[6]} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 650}}>
        <Kinetic t={t} at={W(7, 'Nothing')} text="Nothing is uploaded. Ever." size={88}
          times={[W(7, 'Nothing'), W(7, 'is'), W(7, 'uploaded'), W(7, 'Ever')]} gradientWords={[3]} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 830, display: 'flex', justifyContent: 'center', gap: 18}}>
        {['No account', 'No uploads', 'Works offline', 'ffmpeg built in'].map((c, i) => {
          const s = springAt(frame, W(7, 'Mac') + 0.2 + i * 0.09, {stiffness: 200, damping: 18});
          return <div key={c} style={{opacity: s, transform: `translateY(${(1 - s) * 30}px)`}}><Chip>{c}</Chip></div>;
        })}
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
// 8. End card.
export const EndCard: React.FC<{t: number; frame: number; compact?: boolean}> = ({t, frame}) => {
  const name = W(8, 'Clementine');
  const enter = prog(t, 55.55, 55.95);
  const icon = springAt(frame, name - 0.25, {stiffness: 110, damping: 14});
  const glow = interpolate(t, [name - 0.1, name + 0.3, name + 3], [0, 1, 0.5], clamp);
  const fadeOut = prog(t, 63.9, 64.95, easeInOut);
  const letters = 'Clementine'.split('');
  const hintIn = springAt(frame, W(8, 'Just') - 0.1, {stiffness: 170, damping: 18});
  const shiftDown = prog(t, W(8, 'Shift') - 0.05, W(8, 'Shift') + 0.03);
  const dragK = prog(t, W(8, 'and') - 0.05, WE(8, 'drag') + 0.2, easeInOut);
  const cta = springAt(frame, WE(8, 'drag') + 0.35, {stiffness: 160, damping: 18});
  return (
    <AbsoluteFill style={{background: '#000', opacity: enter * (1 - fadeOut)}}>
      <AbsoluteFill style={{filter: 'blur(30px)', transform: 'scale(1.1)', opacity: 0.55}}><Wallpaper t={t} variant="dawn" /></AbsoluteFill>
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 40%, rgba(10,6,5,0.25), rgba(10,6,5,0.85) 75%)'}} />
      <AbsoluteFill style={{background: `radial-gradient(ellipse 35% 32% at 50% 27%, rgba(255,130,60,${0.35 * glow}), rgba(0,0,0,0) 70%)`}} />
      <div style={{position: 'absolute', left: 960, top: 255, transform: `translate(-50%, -50%) scale(${0.5 + 0.5 * icon}) rotate(${(1 - icon) * -30}deg)`,
        opacity: Math.min(1, icon * 2), filter: `drop-shadow(0 26px 50px rgba(255,110,40,${0.3 + 0.3 * glow}))`}}>
        <Img src={staticFile('icon.png')} style={{width: 250, height: 250}} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 390, textAlign: 'center', fontFamily: tight, fontWeight: 700, fontSize: 140,
        letterSpacing: '-0.035em', color: 'white'}}>
        {letters.map((l, i) => {
          const s = springAt(frame, name + i * 0.03, {stiffness: 170, damping: 18});
          return <span key={i} style={{display: 'inline-block', opacity: Math.min(1, s * 1.5), transform: `translateY(${(1 - s) * 60}px)`, filter: `blur(${(1 - s) * 10}px)`}}>{l}</span>;
        })}
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 575}}>
        <Kinetic t={t} at={W(8, 'Free')} text="Free, for your Mac." size={54} weight={600} font={inter} color={C.peach} tracking={-0.015}
          times={[W(8, 'Free'), W(8, 'for'), W(8, 'your'), W(8, 'Mac')]} />
      </div>
      {/* Hold ⇧ and drag */}
      <div style={{position: 'absolute', left: '50%', top: 700, display: 'flex', alignItems: 'center', gap: 26,
        transform: `translateX(-50%) translateY(${(1 - hintIn) * 40}px)`, opacity: hintIn, fontFamily: inter, fontSize: 34, fontWeight: 600, color: 'white'}}>
        <span style={{color: 'rgba(255,255,255,0.75)'}}>Hold</span>
        <KeyCap symbol="⇧" label="shift" pressed={shiftDown} width={150} scale={0.62} />
        <span style={{color: 'rgba(255,255,255,0.75)', marginLeft: -20}}>and drag</span>
        <div style={{position: 'relative', width: 150, height: 70, marginLeft: -14}}>
          <div style={{position: 'absolute', left: 10 + dragK * 70, top: 6, width: 66, height: 44, borderRadius: 3, overflow: 'hidden', border: '2px solid white',
            opacity: 0.9, boxShadow: '0 6px 14px rgba(0,0,0,0.4)'}}>
            <Img src={staticFile('photo-thumb.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </div>
          <div style={{position: 'absolute', left: 40 + dragK * 70, top: 26}}>
            <svg width="22" height="32" viewBox="0 0 30 44"><path d="M3 2 L3 34 L10.5 26.8 L15.6 39.2 L21 37 L15.9 24.9 L26 24.9 Z" fill="black" stroke="white" strokeWidth="2.4" strokeLinejoin="round" /></svg>
          </div>
        </div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 850, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 22,
        opacity: cta, transform: `translateY(${(1 - cta) * 30}px)`}}>
        <Chip strong style={{fontSize: 30, padding: '16px 34px'}}>
          <SliceGlyph size={26} color="white" /> Download free
        </Chip>
        <div style={{fontFamily: inter, fontSize: 28, fontWeight: 500, color: 'rgba(255,240,228,0.85)', letterSpacing: 0.2}}>
          github.com/mustafahalabi/clementine
        </div>
      </div>
    </AbsoluteFill>
  );
};
