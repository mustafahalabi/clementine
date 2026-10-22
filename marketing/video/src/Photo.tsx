import React from 'react';
import {AbsoluteFill} from 'remotion';

// A golden-hour landscape drawn in SVG: the demo "Sunset.heic" that gets dragged around in the film.
export const Photo: React.FC = () => (
  <AbsoluteFill>
    <svg viewBox="0 0 2400 1600" width="100%" height="100%">
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#2B3A78" />
          <stop offset="0.35" stopColor="#7B5EA7" />
          <stop offset="0.62" stopColor="#F28C6B" />
          <stop offset="0.8" stopColor="#FFC27A" />
        </linearGradient>
        <radialGradient id="sun" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#FFF6DA" />
          <stop offset="0.45" stopColor="#FFE2A0" />
          <stop offset="1" stopColor="#FFB86B" stopOpacity="0" />
        </radialGradient>
        <radialGradient id="haze" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#FFD9A0" stopOpacity="0.85" />
          <stop offset="1" stopColor="#FF9A5C" stopOpacity="0" />
        </radialGradient>
        <linearGradient id="sea" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#E89A78" />
          <stop offset="1" stopColor="#3A3466" />
        </linearGradient>
        <linearGradient id="h1" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#8E5A86" /><stop offset="1" stopColor="#5B3B6E" />
        </linearGradient>
        <linearGradient id="h2" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#5C3A64" /><stop offset="1" stopColor="#35244A" />
        </linearGradient>
        <linearGradient id="h3" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#33213F" /><stop offset="1" stopColor="#1A1222" />
        </linearGradient>
        <filter id="blur8"><feGaussianBlur stdDeviation="8" /></filter>
        <filter id="blur40"><feGaussianBlur stdDeviation="40" /></filter>
        <filter id="grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="4" />
          <feColorMatrix values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0.06 0" />
        </filter>
      </defs>
      <rect width="2400" height="1600" fill="url(#sky)" />
      <ellipse cx="1500" cy="980" rx="900" ry="420" fill="url(#haze)" filter="url(#blur40)" />
      <circle cx="1500" cy="930" r="250" fill="url(#sun)" />
      <circle cx="1500" cy="930" r="120" fill="#FFF3D6" filter="url(#blur8)" />
      {/* clouds */}
      <g fill="#FFD7B5" opacity="0.5" filter="url(#blur8)">
        <ellipse cx="520" cy="520" rx="380" ry="34" />
        <ellipse cx="760" cy="590" rx="300" ry="22" />
        <ellipse cx="1900" cy="640" rx="420" ry="28" />
        <ellipse cx="1750" cy="700" rx="260" ry="16" />
      </g>
      <path d="M0 1010 C 300 900, 520 880, 820 960 S 1300 1050, 1500 1040 L 1500 1100 L 0 1100 Z" fill="url(#h1)" opacity="0.9" />
      <path d="M1200 1060 C 1500 980, 1800 900, 2100 930 S 2400 980, 2400 980 L 2400 1100 L 1200 1100 Z" fill="url(#h1)" opacity="0.8" />
      <rect y="1040" width="2400" height="560" fill="url(#sea)" />
      {/* sun glitter on the water */}
      <g fill="#FFE7B8" filter="url(#blur8)">
        {Array.from({length: 26}).map((_, i) => (
          <rect key={i} x={1500 - (140 - i * 3) + ((i * 53) % 37) - 18} y={1060 + i * 18} width={(280 - i * 7)} height={5} opacity={0.9 - i * 0.03} rx={3} />
        ))}
      </g>
      <path d="M0 1180 C 260 1080, 560 1060, 820 1140 S 1240 1260, 1520 1230 S 2100 1120, 2400 1180 L 2400 1600 L 0 1600 Z" fill="url(#h2)" />
      <path d="M0 1390 C 340 1280, 700 1300, 1000 1400 S 1700 1540, 2400 1380 L 2400 1600 L 0 1600 Z" fill="url(#h3)" />
      <rect width="2400" height="1600" filter="url(#grain)" />
    </svg>
  </AbsoluteFill>
);
