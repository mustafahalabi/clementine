import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile} from 'remotion';
import {C} from '../theme';
import {inter, tight} from '../fonts';
import {W, WE, clamp, easeInOut, prog, springAt, window01} from '../timing';
import {Kinetic} from '../components/Pieces';

// ---------------------------------------------------------------------------------------------------------------
// 1. Hook: "You have the file. You just need it… as something else."
const EXTS = ['heic', 'jpg', 'png', 'webp', 'pdf', 'gif', 'avif', 'jpg'];
export const extTicks = () => EXTS.slice(1).map((_, i) => W(0, 'as') + 0.05 + i * 0.13);

export const Hook: React.FC<{t: number; frame: number}> = ({t, frame}) => {
  const enter = springAt(frame, 0.35, {stiffness: 90, damping: 18});
  const leave = prog(t, 5.55, 6.1, easeInOut);
  const float = Math.sin(t * 1.4) * 6;
  const ticks = extTicks();
  let ext = EXTS[0];
  ticks.forEach((tk, i) => { if (t >= tk) ext = EXTS[i + 1]; });
  const flip = ticks.reduce((acc, tk) => acc + Math.max(0, 1 - Math.abs(t - tk) / 0.07), 0);
  const glow = interpolate(t, [0, 2, 5], [0.0, 0.35, 0.6], clamp);
  return (
    <AbsoluteFill style={{background: '#0B0706', opacity: 1 - leave}}>
      <AbsoluteFill style={{background: `radial-gradient(ellipse 50% 45% at 50% 42%, rgba(255,120,50,${glow * 0.55}), rgba(255,90,40,0) 70%)`}} />
      <div style={{position: 'absolute', left: 960, top: 380 + float, transform: `translate(-50%, -50%) scale(${(0.82 + 0.18 * enter) * (1 - leave * 0.15)})`,
        opacity: enter, filter: `blur(${(1 - enter) * 12 + leave * 10}px)`}}>
        <div style={{width: 420, height: 280, borderRadius: 16, overflow: 'hidden', border: '6px solid #FDFBF8', boxSizing: 'border-box',
          boxShadow: '0 40px 80px rgba(0,0,0,0.6), 0 0 120px rgba(255,120,50,0.25)'}}>
          <Img src={staticFile('photo.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
        </div>
        <div style={{marginTop: 26, display: 'flex', justifyContent: 'center', fontFamily: inter, fontSize: 30, fontWeight: 600, color: 'white'}}>
          <span>Sunset.</span>
          <span style={{display: 'inline-block', minWidth: 70, color: t >= ticks[0] ? C.tangerine : 'white',
            transform: `translateY(${-flip * 6}px)`, filter: `blur(${flip * 2}px)`}}>{ext}</span>
        </div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 720}}>
        <Kinetic t={t} at={W(0, 'You')} times={[W(0, 'You'), W(0, 'have'), W(0, 'the'), W(0, 'file')]} text="You have the file."
          size={78} weight={600} out={2.5} color="rgba(255,255,255,0.95)" />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 720}}>
        <Kinetic t={t} at={W(0, 'You', 1)} text="You just need it as something else." size={78} weight={600}
          times={[W(0, 'You', 1), W(0, 'just'), W(0, 'need'), W(0, 'it'), W(0, 'as'), W(0, 'something'), W(0, 'else')]}
          gradientWords={[5, 6]} color="rgba(255,255,255,0.95)" />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------------------------
// 2. Problem: converter websites, uploads, waiting, decoy download buttons, and one more app per format.
const Gray = 'rgba(255,255,255,0.55)';

const BrowserChrome: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div style={{width: 1180, height: 720, borderRadius: 18, overflow: 'hidden', background: '#ECEDEF', boxShadow: '0 50px 100px rgba(0,0,0,0.6)',
    fontFamily: inter, position: 'relative'}}>
    <div style={{height: 56, background: '#D9DBDF', display: 'flex', alignItems: 'center', padding: '0 20px', gap: 10}}>
      {['#C9CBD0', '#C9CBD0', '#C9CBD0'].map((c, i) => <div key={i} style={{width: 14, height: 14, borderRadius: 7, background: c}} />)}
      <div style={{marginLeft: 120, flex: 1, height: 34, borderRadius: 10, background: '#F4F5F7', display: 'flex', alignItems: 'center', gap: 10,
        padding: '0 16px', color: '#6B6F76', fontSize: 16}}>
        <svg width="16" height="16" viewBox="0 0 16 16"><path d="M8 1 L15 14 H1 Z" fill="#E5484D" /><rect x="7.2" y="5.5" width="1.6" height="4.5" fill="white" /><rect x="7.2" y="11" width="1.6" height="1.6" fill="white" /></svg>
        <span style={{color: '#E5484D', fontWeight: 600}}>Not Secure</span>
        <span>free-convert-anything.web/heic-to-jpg</span>
      </div>
      <div style={{width: 120}} />
    </div>
    {children}
  </div>
);

const Ad: React.FC<{w: number; h: number; text: string; color: string; style?: React.CSSProperties}> = ({w, h, text, color, style}) => (
  <div style={{width: w, height: h, borderRadius: 8, background: color, color: 'white', fontWeight: 800, fontSize: 22, display: 'grid',
    placeItems: 'center', textAlign: 'center', letterSpacing: 0.5, ...style}}>{text}</div>
);

export const Problem: React.FC<{t: number; frame: number}> = ({t, frame}) => {
  const enter = springAt(frame, 5.95, {stiffness: 120, damping: 20});
  const toDock = prog(t, W(1, 'Or') - 0.1, W(1, 'install') + 0.2, easeInOut);
  const out = prog(t, 15.6, 16.55, easeInOut);
  const fileIn = springAt(frame, W(1, 'website') - 0.1, {stiffness: 140, damping: 16});
  const uploading = prog(t, W(1, 'Upload'), W(1, 'Upload') + 0.3);
  const upP = interpolate(t, [W(1, 'Upload'), W(1, 'Wait'), W(1, 'Download')], [0, 0.34, 0.36], clamp);
  const waitP = prog(t, W(1, 'Wait') - 0.05, W(1, 'Wait') + 0.25);
  const dl = [0, 1, 2].map((i) => springAt(frame, W(1, 'Download') + i * 0.12, {stiffness: 260, damping: 16}));
  const spin = t * 360;
  const captions: [string, number][] = [['Upload.', W(1, 'Upload')], ['Wait.', W(1, 'Wait')], ['Download.', W(1, 'Download')]];
  const apps = ['HEIC to JPG', 'Video2GIF', 'PDF Tools+', 'Audio Convert', 'Unzipper', 'WebP Viewer', 'Doc Converter', 'Compressor X', 'MKV Player'];
  const glyphs = ['JPG', 'GIF', 'PDF', 'MP3', 'ZIP', 'WEBP', 'DOC', 'MB', 'MKV'];
  const appTimes = apps.map((_, i) => W(1, 'install') + 0.05 + i * 0.25);
  return (
    <AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 30%, #23262D, #0E0F12 75%)', opacity: 1 - out,
      filter: `saturate(${1 - out}) blur(${out * 8}px)`}}>
      {/* Pain captions, left column */}
      <div style={{position: 'absolute', left: 110, top: 300, opacity: 1 - toDock}}>
        {captions.map(([c, at], i) => (
          <div key={c} style={{height: 118}}>
            <Kinetic t={t} at={at} text={c} size={96} weight={700} align="left"
              color={i === captions.findLastIndex(([, a]) => t >= a) ? 'white' : 'rgba(255,255,255,0.32)'} />
          </div>
        ))}
      </div>
      {/* The converter site */}
      <div style={{position: 'absolute', left: 1240, top: 560 - toDock * 120,
        transform: `translate(-50%, -50%) translateY(${(1 - enter) * 500}px) scale(${0.82 - toDock * 0.22})`, opacity: enter * (1 - toDock * 0.85),
        filter: `blur(${toDock * 6}px)`}}>
        <BrowserChrome>
          <div style={{display: 'flex', padding: 30, gap: 26, height: 664, boxSizing: 'border-box'}}>
            <div style={{flex: 1}}>
              <div style={{fontSize: 40, fontWeight: 800, color: '#3A3D44'}}>Free Online File Converter</div>
              <div style={{fontSize: 18, color: '#7A7E86', marginTop: 6}}>Convert HEIC to JPG online, 100% free*</div>
              <div style={{marginTop: 24, height: 300, borderRadius: 16, border: '3px dashed #B9BCC3', background: '#F7F8FA', position: 'relative',
                display: 'grid', placeItems: 'center', color: '#8A8E96', fontSize: 22, fontWeight: 600, overflow: 'hidden'}}>
                <div style={{opacity: 1 - fileIn}}>Drop your file here · max 25 MB</div>
                <div style={{position: 'absolute', left: '50%', top: '50%', transform: `translate(-50%, -50%) translateY(${(1 - fileIn) * -260}px) scale(${0.6 + 0.4 * fileIn})`,
                  opacity: fileIn * (1 - waitP * 0.4), display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16}}>
                  <div style={{width: 150, height: 100, borderRadius: 6, overflow: 'hidden', border: '4px solid white', boxShadow: '0 8px 20px rgba(0,0,0,0.2)',
                    filter: 'grayscale(0.6)'}}><Img src={staticFile('photo-thumb.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} /></div>
                  <div style={{opacity: uploading, width: 460, textAlign: 'center'}}>
                    <div style={{fontSize: 18, color: '#5B5F67', fontWeight: 600}}>
                      {t < W(1, 'Wait') ? 'Uploading Sunset.heic to our servers…' : 'You are #47 in the queue'}
                    </div>
                    <div style={{height: 12, borderRadius: 6, background: '#DDE0E5', marginTop: 12, overflow: 'hidden'}}>
                      <div style={{width: `${upP * 100}%`, height: '100%', background: 'repeating-linear-gradient(45deg,#8C9099,#8C9099 10px,#9DA1AA 10px,#9DA1AA 20px)'}} />
                    </div>
                  </div>
                </div>
                <div style={{position: 'absolute', right: 22, top: 22, width: 40, height: 40, borderRadius: 20, border: '5px solid #C6C9CF',
                  borderTopColor: '#7A7E86', transform: `rotate(${spin}deg)`, opacity: waitP}} />
              </div>
              <div style={{display: 'flex', gap: 16, marginTop: 24, alignItems: 'center'}}>
                <div style={{transform: `scale(${dl[0]})`}}><Ad w={260} h={70} text="⬇ DOWNLOAD" color="#2FA84F" /></div>
                <div style={{transform: `scale(${dl[1]})`}}><Ad w={250} h={70} text="START NOW ▶" color="#E08A1E" /></div>
                <div style={{transform: `scale(${dl[2]})`, color: '#3B6FD8', fontSize: 15, textDecoration: 'underline', fontWeight: 500}}>download sunset.jpg</div>
              </div>
            </div>
            <div style={{width: 250, display: 'flex', flexDirection: 'column', gap: 16}}>
              <Ad w={250} h={250} text={'CLEAN YOUR\nMAC NOW!!'} color="#C0392B" style={{whiteSpace: 'pre', fontSize: 26}} />
              <Ad w={250} h={180} text="You are visitor #1,000,000!" color="#6C5CE7" />
              <Ad w={250} h={120} text="Speed up your PC by 300%" color="#7F8C8D" style={{fontSize: 17, fontWeight: 700, padding: 16}} />
            </div>
          </div>
          <div style={{position: 'absolute', left: 0, right: 0, bottom: 0, height: 78, background: 'rgba(40,42,48,0.95)', color: '#E6E7EA',
            display: 'flex', alignItems: 'center', padding: '0 30px', gap: 20, fontSize: 17}}>
            <span style={{flex: 1}}>We value your privacy. We and our 847 partners store and access data on your device.</span>
            <div style={{padding: '10px 22px', borderRadius: 8, background: '#3B6FD8', fontWeight: 700}}>Accept all</div>
          </div>
        </BrowserChrome>
      </div>
      {/* One more app, for one more format */}
      <div style={{position: 'absolute', left: 0, right: 0, top: 300, opacity: toDock}}>
        <Kinetic t={t} at={W(1, 'Or')} text="One more app." size={96} weight={700}
          times={[W(1, 'one'), W(1, 'more'), W(1, 'app')]} />
        <Kinetic t={t} at={W(1, 'for')} text="For one more format." size={96} weight={700} color="rgba(255,255,255,0.45)"
          times={[W(1, 'for'), W(1, 'one', 1), W(1, 'more', 1), W(1, 'format')]} />
      </div>
      <div style={{position: 'absolute', left: '50%', top: 790, transform: `translateX(-50%) translateY(${(1 - toDock) * 200}px)`, opacity: toDock,
        display: 'flex', gap: 18, padding: '18px 22px', borderRadius: 34, background: 'rgba(255,255,255,0.10)', border: '1px solid rgba(255,255,255,0.14)',
        backdropFilter: 'blur(20px)'}}>
        {apps.map((a, i) => {
          const s = springAt(frame, appTimes[i], {stiffness: 300, damping: 15});
          return (
            <div key={a} style={{width: 104, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, opacity: Math.min(1, s * 2)}}>
              <div style={{width: 96, height: 96, borderRadius: 22, transform: `scale(${s}) translateY(${(1 - s) * 40}px)`,
                background: `linear-gradient(160deg, hsl(${210 + i * 9}, 8%, ${62 - (i % 3) * 7}%), hsl(${215 + i * 9}, 10%, ${38 - (i % 3) * 5}%))`,
                display: 'grid', placeItems: 'center', color: 'rgba(255,255,255,0.9)', fontFamily: tight, fontWeight: 800, fontSize: 24,
                boxShadow: '0 10px 20px rgba(0,0,0,0.4)'}}>{glyphs[i]}</div>
              <div style={{fontFamily: inter, fontSize: 14, color: Gray, whiteSpace: 'nowrap', opacity: s}}>{a}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

export const problemSfxTimes = () => ({
  appPops: ['HEIC', 1, 2, 3, 4, 5, 6, 7, 8].map((_, i) => W(1, 'install') + 0.05 + i * 0.25),
  downloads: [0, 1, 2].map((i) => W(1, 'Download') + i * 0.12),
  fileIn: W(1, 'website') - 0.1,
  wait: W(1, 'Wait'),
  endOfLine: WE(1, 'format'),
});
