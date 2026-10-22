// Colours mirror Sources/Clementine/Support/Theme.swift so the film and the app read as one piece.
export const C = {
  tangerine: '#FF9A3C',
  blood: '#FF5E3A',
  peach: '#FFD3A8',
  leaf: '#34C77B',
  leafLight: '#5BE09B',
  cherry: '#E5484D',
  surfaceDark: 'rgba(43,36,32,0.82)',
  surfaceLight: 'rgba(255,251,246,0.86)',
  secondaryDark: 'rgba(217,203,190,0.85)',
  secondaryLight: '#6B5646',
  glow: 'rgba(255,122,47,0.45)',
  ink: '#16110E',
  cream: '#FFF8F0',
};
export const accent = `linear-gradient(135deg, ${C.tangerine}, ${C.blood})`;
// Theme.spring (response 0.34, damping 0.74) expressed as a Remotion spring config.
export const appSpring = {mass: 1, stiffness: 340, damping: 27};
export const snappy = {mass: 1, stiffness: 800, damping: 46};
export const soft = {mass: 1, stiffness: 120, damping: 22};
