import React, { useState } from 'react';
import { View, Text, StyleSheet, Pressable } from 'react-native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Input } from '@/components/Input';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { colors, radii, spacing, typography } from '@/lib/theme';
import type { BrowserStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<BrowserStackParamList, 'BrowserHome'>;

export function BrowserHomeScreen({ navigation }: Props) {
  const [query, setQuery] = useState('');

  function go() {
    const q = query.trim().toLowerCase();
    if (!q) return;
    const url = q.includes('.') ? `https://${q}` : `https://${q}.oneway.app`;
    navigation.navigate('Site', { url });
  }

  return (
    <Screen scroll>
      <View style={styles.hero}>
        <Text style={styles.logo}>🛸</Text>
        <Badge label="OneWay Browser" />
        <Text style={styles.h1}>Visit a OneWay site</Text>
        <Text style={styles.body}>
          Anything ending in <Text style={styles.code}>.oneway.app</Text> opens here. No trackers,
          no JS soup, just a single page.
        </Text>
      </View>

      <Input
        placeholder="name.oneway.app"
        value={query}
        onChangeText={setQuery}
        onSubmitEditing={go}
        autoCapitalize="none"
      />
      <Button label="Open" onPress={go} />

      <Pressable
        style={styles.directoryCard}
        onPress={() => navigation.navigate('Directory')}
      >
        <Text style={styles.directoryTitle}>Browse the directory →</Text>
        <Text style={styles.directorySub}>See every active site on OneWay.</Text>
      </Pressable>
    </Screen>
  );
}

const styles = StyleSheet.create({
  hero: { alignItems: 'center', marginTop: spacing.xl, marginBottom: spacing.xl },
  logo: { fontSize: 56, marginBottom: spacing.md },
  h1: {
    ...typography.h1,
    color: colors.text,
    marginTop: spacing.md,
    marginBottom: spacing.sm,
    textAlign: 'center',
  },
  body: {
    ...typography.body,
    color: colors.textMuted,
    textAlign: 'center',
    maxWidth: 320,
    lineHeight: 22,
  },
  code: { color: colors.accent, fontFamily: 'Menlo' },
  directoryCard: {
    marginTop: spacing.xl,
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
  },
  directoryTitle: { ...typography.h2, color: colors.accent, marginBottom: 4 },
  directorySub: { ...typography.body, color: colors.textMuted },
});
