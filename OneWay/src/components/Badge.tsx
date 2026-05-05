import React from 'react';
import { View, Text, StyleSheet, ViewStyle } from 'react-native';
import { colors, radii, typography } from '@/lib/theme';

interface Props {
  label: string;
  tone?: 'accent' | 'muted' | 'success' | 'danger';
  style?: ViewStyle;
}

export function Badge({ label, tone = 'accent', style }: Props) {
  return (
    <View style={[styles.base, styles[tone], style]}>
      <Text style={[styles.label, styles[`${tone}Label` as const]]}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  base: {
    alignSelf: 'flex-start',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: radii.pill,
    borderWidth: 1,
  },
  label: { ...typography.caption, fontWeight: '700' },

  accent: { backgroundColor: 'rgba(124,58,237,0.15)', borderColor: colors.borderStrong },
  accentLabel: { color: colors.accent },

  muted: { backgroundColor: colors.surface, borderColor: colors.border },
  mutedLabel: { color: colors.textMuted },

  success: { backgroundColor: 'rgba(74,222,128,0.12)', borderColor: 'rgba(74,222,128,0.35)' },
  successLabel: { color: colors.success },

  danger: { backgroundColor: 'rgba(248,113,113,0.12)', borderColor: 'rgba(248,113,113,0.35)' },
  dangerLabel: { color: colors.danger },
});
