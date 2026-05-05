import React from 'react';
import { View, StyleSheet, ViewProps, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { colors, spacing } from '@/lib/theme';

interface Props extends ViewProps {
  scroll?: boolean;
  padded?: boolean;
}

export function Screen({ children, style, scroll, padded = true, ...rest }: Props) {
  const inner = (
    <View style={[padded && styles.padded, style]} {...rest}>
      {children}
    </View>
  );
  return (
    <SafeAreaView style={styles.safe} edges={['top', 'bottom']}>
      {scroll ? (
        <ScrollView
          contentContainerStyle={styles.scrollContent}
          keyboardShouldPersistTaps="handled"
        >
          {inner}
        </ScrollView>
      ) : (
        inner
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: colors.bg },
  padded: { paddingHorizontal: spacing.lg, paddingTop: spacing.md },
  scrollContent: { flexGrow: 1 },
});
