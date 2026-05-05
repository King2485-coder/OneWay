// Theme tokens kept in sync with the serve-site edge function CSS so the
// native shell and rendered *.oneway.app sites feel like one product.
export const colors = {
  bg: '#06030f',
  surface: '#0f0820',
  surfaceMuted: 'rgba(124,58,237,0.08)',
  border: 'rgba(124,58,237,0.18)',
  borderStrong: 'rgba(124,58,237,0.35)',

  text: '#f0ebff',
  textMuted: '#9d8fc4',
  textDim: '#6b5d8c',

  accent: '#a855f7',
  accentDeep: '#7c3aed',
  accentBright: '#9333ea',

  danger: '#f87171',
  success: '#4ade80',
  warning: '#fbbf24',
} as const;

export const radii = {
  sm: 8,
  md: 12,
  lg: 16,
  pill: 100,
} as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const typography = {
  display: { fontSize: 32, fontWeight: '900' as const },
  h1: { fontSize: 24, fontWeight: '800' as const },
  h2: { fontSize: 18, fontWeight: '700' as const },
  body: { fontSize: 15, fontWeight: '400' as const },
  caption: { fontSize: 12, fontWeight: '500' as const },
} as const;

export const accentGradient = ['#6d28d9', '#9333ea'] as const;
