import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {C} from '../theme';
import {inter} from '../fonts';

/** An original citrus wallpaper: soft blurred bands of tangerine and plum that drift slowly. */
export const Wallpaper: React.FC<{t: number; variant?: 'dusk' | 'dawn'}> = ({t, variant = 'dusk'}) => {
  const d = Math.sin(t * 0.25) * 40;
  const e = Math.cos(t * 0.18) * 50;
  const base = variant === 'dusk' ? ['#1B0F1F', '#2E1428', '#4A1E2A'] : ['#2A1A2E', '#5A2A3A', '#8A3E36'];
  return (
    <AbsoluteFill>
      <svg viewBox="0 0 1920 1080" width="100%" height="100%" preserveAspectRatio="xMidYMid slice">
        <defs>
          <linearGradient id="wpBase" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor={base[0]} />
            <stop offset="0.55" stopColor={base[1]} />
            <stop offset="1" stopColor={base[2]} />
          </linearGradient>
          <linearGradient id="band1" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#FF5E3A" stopOpacity="0" />
            <stop offset="0.35" stopColor="#FF7A3C" stopOpacity="0.95" />
            <stop offset="0.75" stopColor="#FFB067" stopOpacity="0.9" />
            <stop offset="1" stopColor="#FFD3A8" stopOpacity="0.2" />
          </linearGradient>
          <linearGradient id="band2" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#B23A5B" stopOpacity="0.1" />
            <stop offset="0.5" stopColor="#D9485A" stopOpacity="0.85" />
            <stop offset="1" stopColor="#FF8A4C" stopOpacity="0.6" />
          </linearGradient>
          <linearGradient id="band3" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#6A2E7A" stopOpacity="0.7" />
            <stop offset="1" stopColor="#3A1A4A" stopOpacity="0.2" />
          </linearGradient>
          <filter id="wpBlur" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="38" /></filter>
          <filter id="wpBlurS" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14" /></filter>
          <filter id="wpGrain">
            <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="9" />
            <feColorMatrix values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0.05 0" />
          </filter>
        </defs>
        <rect width="1920" height="1080" fill="url(#wpBase)" />
        <g filter="url(#wpBlur)">
          <path d={`M-200 ${760 + d} C 300 ${560 + e}, 760 ${900 - d}, 1240 ${640 + e} S 1900 ${420 - d}, 2200 ${560 + e} L 2200 1300 L -200 1300 Z`} fill="url(#band3)" />
          <path d={`M-200 ${640 - e} C 360 ${420 + d}, 820 ${760 + e}, 1300 ${520 - d} S 1980 ${300 + e}, 2200 ${380 - d} L 2200 ${560 + d} C 1800 ${560 - e}, 1400 ${820 + d}, 900 ${860 - e} S 100 ${780 + d}, -200 ${900} Z`} fill="url(#band1)" />
          <path d={`M-200 ${880 + e} C 400 ${700 - d}, 900 ${980 + e}, 1400 ${780 - d} S 2000 ${640 + e}, 2200 ${700} L 2200 1300 L -200 1300 Z`} fill="url(#band2)" />
        </g>
        <g filter="url(#wpBlurS)" opacity="0.55">
          <path d={`M-100 ${600 - e * 0.6} C 420 ${430 + d * 0.6}, 860 ${720 + e * 0.6}, 1320 ${500 - d * 0.6} S 1960 ${330 + e * 0.6}, 2100 ${380}`} stroke="#FFE2C4" strokeWidth="3" fill="none" />
        </g>
        <rect width="1920" height="1080" filter="url(#wpGrain)" />
      </svg>
    </AbsoluteFill>
  );
};

/** The orange slice glyph used for Clementine's menu bar item. */
export const SliceGlyph: React.FC<{size: number; color?: string}> = ({size, color = C.tangerine}) => (
  <svg width={size} height={size} viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="10" fill="none" stroke={color} strokeWidth="2.2" />
    {Array.from({length: 8}).map((_, i) => {
      const a = (i * Math.PI) / 4;
      return <line key={i} x1="12" y1="12" x2={12 + Math.cos(a) * 8.2} y2={12 + Math.sin(a) * 8.2} stroke={color} strokeWidth="1.6" strokeLinecap="round" />;
    })}
  </svg>
);

export const MenuBar: React.FC<{highlightClementine?: number}> = ({highlightClementine = 0}) => (
  <div
    style={{
      position: 'absolute', left: 0, top: 0, right: 0, height: 34,
      background: 'rgba(20,12,14,0.38)', backdropFilter: 'blur(30px)',
      display: 'flex', alignItems: 'center', padding: '0 22px', fontFamily: inter, fontSize: 15,
      color: 'rgba(255,255,255,0.92)', gap: 24, letterSpacing: 0.1,
    }}
  >
    <span style={{fontWeight: 700}}>Finder</span>
    {['File', 'Edit', 'View', 'Go', 'Window', 'Help'].map((m) => (
      <span key={m} style={{fontWeight: 500, opacity: 0.92}}>{m}</span>
    ))}
    <div style={{flex: 1}} />
    <div style={{
      position: 'relative', padding: '3px 8px', borderRadius: 6,
      background: `rgba(255,154,60,${0.28 * highlightClementine})`,
      boxShadow: highlightClementine > 0 ? `0 0 ${24 * highlightClementine}px rgba(255,122,47,${0.6 * highlightClementine})` : undefined,
      display: 'flex',
    }}>
      <SliceGlyph size={18} color="#FFFFFF" />
    </div>
    <svg width="20" height="16" viewBox="0 0 20 16"><path d="M10 14.5 l2.6-3.1a4 4 0 0 0-5.2 0z M10 4.2a10.5 10.5 0 0 1 7.4 3l1.6-1.9A13 13 0 0 0 10 1.6 13 13 0 0 0 1 5.3l1.6 1.9a10.5 10.5 0 0 1 7.4-3z M10 7.9a6.6 6.6 0 0 1 4.6 1.9l1.6-1.9A9 9 0 0 0 10 5.4a9 9 0 0 0-6.2 2.5l1.6 1.9A6.6 6.6 0 0 1 10 7.9z" fill="white" /></svg>
    <svg width="30" height="15" viewBox="0 0 30 15"><rect x="0.75" y="0.75" width="25" height="13.5" rx="4" fill="none" stroke="white" strokeOpacity="0.6" strokeWidth="1.5" /><rect x="3" y="3" width="17" height="9" rx="2" fill="white" /><rect x="27" y="5" width="2" height="5" rx="1" fill="white" fillOpacity="0.6" /></svg>
    <span style={{fontWeight: 500}}>Thu Oct 22&nbsp;&nbsp;9:41</span>
  </div>
);

export type FileKind = 'image' | 'video' | 'audio' | 'doc' | 'pdf' | 'zip';
const kindColor: Record<FileKind, string> = {
  image: '#3B82F6', video: '#8B5CF6', audio: '#EC4899', doc: '#2563EB', pdf: '#E5484D', zip: '#A16207',
};

/** A document-style file icon with a coloured extension band (generic, not Apple's artwork). */
export const FileGlyph: React.FC<{kind: FileKind; ext: string; size?: number; thumb?: string}> = ({kind, ext, size = 84, thumb}) => {
  const w = size * 0.78, h = size;
  return (
    <div style={{width: w, height: h, position: 'relative', filter: 'drop-shadow(0 6px 10px rgba(0,0,0,0.35))'}}>
      <svg width={w} height={h} viewBox="0 0 78 100" style={{position: 'absolute', inset: 0}}>
        <path d="M6 2 h46 l24 24 v68 a4 4 0 0 1-4 4 H6 a4 4 0 0 1-4-4 V6 a4 4 0 0 1 4-4z" fill="#FBFAF8" />
        <path d="M52 2 v20 a4 4 0 0 0 4 4 h20z" fill="#DCD8D2" />
        {kind === 'audio' && (
          <g fill={kindColor.audio} opacity="0.85">
            {[10, 18, 26, 34, 42, 50, 58, 66].map((x, i) => {
              const hh = [10, 22, 14, 28, 18, 24, 12, 16][i];
              return <rect key={x} x={x} y={50 - hh / 2} width="4" height={hh} rx="2" />;
            })}
          </g>
        )}
        {kind === 'doc' && (
          <g fill="#C9C4BD">{[34, 42, 50, 58].map((y) => <rect key={y} x="12" y={y} width={y === 58 ? 34 : 54} height="4" rx="2" />)}</g>
        )}
        {kind === 'pdf' && (
          <g><rect x="12" y="30" width="54" height="16" rx="3" fill="#F3B3B4" />{[52, 60].map((y) => <rect key={y} x="12" y={y} width="54" height="4" rx="2" fill="#C9C4BD" />)}</g>
        )}
        {kind === 'zip' && (
          <g fill="#8C7A64">{[8, 16, 24, 32, 40, 48].map((y, i) => <rect key={y} x={i % 2 ? 36 : 30} y={y} width="8" height="6" rx="1" />)}<rect x="28" y="56" width="18" height="14" rx="3" /></g>
        )}
        {kind === 'video' && <path d="M30 34 L54 48 L30 62 Z" fill={kindColor.video} opacity="0.85" />}
        <rect x="2" y="74" width="74" height="20" fill={kindColor[kind]} />
        <text x="39" y="89" textAnchor="middle" fontFamily={inter} fontWeight="700" fontSize="13" fill="white" letterSpacing="0.5">{ext}</text>
      </svg>
      {thumb && <Img src={thumb} style={{position: 'absolute', left: 4, top: 4, width: w - 8, height: h * 0.68, objectFit: 'cover', borderRadius: 3}} />}
    </div>
  );
};

/** A desktop file: photo thumbnail or document glyph, plus Finder-style label. */
export const DesktopIcon: React.FC<{
  name: string; kind: FileKind; ext: string; x: number; y: number; selected?: boolean; photo?: boolean; scale?: number;
  opacity?: number; glow?: number;
}> = ({name, kind, ext, x, y, selected, photo, scale = 1, opacity = 1, glow = 0}) => (
  <div style={{position: 'absolute', left: x, top: y, width: 140, marginLeft: -70, display: 'flex', flexDirection: 'column',
    alignItems: 'center', transform: `scale(${scale})`, transformOrigin: '50% 40%', opacity}}>
    <div style={{height: 96, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', borderRadius: 10,
      padding: 4, background: selected ? 'rgba(255,255,255,0.16)' : 'transparent',
      boxShadow: glow > 0 ? `0 0 ${40 * glow}px ${10 * glow}px rgba(255,154,60,${0.55 * glow})` : undefined}}>
      {photo ? (
        <div style={{width: 112, height: 75, borderRadius: 4, overflow: 'hidden', border: '3px solid #FDFBF8',
          boxShadow: '0 8px 16px rgba(0,0,0,0.4)', boxSizing: 'border-box'}}>
          <Img src={staticFile('photo-thumb.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
        </div>
      ) : (
        <FileGlyph kind={kind} ext={ext} size={88} />
      )}
    </div>
    <div style={{marginTop: 6, padding: '2px 8px', borderRadius: 5, background: selected ? '#2F6BE0' : 'transparent',
      fontFamily: inter, fontWeight: 500, fontSize: 15, color: 'white', textShadow: selected ? 'none' : '0 1px 3px rgba(0,0,0,0.7)',
      whiteSpace: 'nowrap'}}>{name}</div>
  </div>
);

/** macOS-style arrow pointer. (x, y) is the hotspot. */
export const Cursor: React.FC<{x: number; y: number; scale?: number; pressed?: number; opacity?: number}> = ({x, y, scale = 1, pressed = 0, opacity = 1}) => (
  <div style={{position: 'absolute', left: x, top: y, transform: `scale(${scale * (1 - pressed * 0.1)})`, transformOrigin: '0 0', opacity,
    filter: 'drop-shadow(0 3px 4px rgba(0,0,0,0.45))', zIndex: 50}}>
    <svg width="30" height="44" viewBox="0 0 30 44" style={{marginLeft: -3, marginTop: -2}}>
      <path d="M3 2 L3 34 L10.5 26.8 L15.6 39.2 L21 37 L15.9 24.9 L26 24.9 Z" fill="black" stroke="white" strokeWidth="2.4" strokeLinejoin="round" />
    </svg>
  </div>
);

/** A keyboard key that can be pressed. */
export const KeyCap: React.FC<{symbol: string; label: string; pressed: number; width?: number; scale?: number}> = ({symbol, label, pressed, width = 150, scale = 1}) => (
  <div style={{transform: `scale(${scale}) translateY(${pressed * 5}px)`, width, height: 108, borderRadius: 20, position: 'relative',
    background: `linear-gradient(180deg, #FFFDFB, #EDE6DF)`,
    boxShadow: `0 ${10 - pressed * 7}px 0 #B9AEA4, 0 ${22 - pressed * 14}px ${34 - pressed * 14}px rgba(0,0,0,0.45), 0 0 ${pressed * 50}px rgba(255,140,60,${pressed * 0.8})`,
    border: `2px solid rgba(255,154,60,${pressed})`, fontFamily: inter, color: '#2A211C', boxSizing: 'border-box'}}>
    <div style={{position: 'absolute', left: 18, top: 10, fontSize: 40, fontWeight: 500}}>{symbol}</div>
    <div style={{position: 'absolute', right: 18, bottom: 14, fontSize: 20, fontWeight: 500, letterSpacing: 0.5}}>{label}</div>
  </div>
);
