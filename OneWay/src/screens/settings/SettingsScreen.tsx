import React from 'react';
import { View, Text, StyleSheet, Pressable, Alert } from 'react-native';
import { Screen } from '@/components/Screen';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { useAuth } from '@/hooks/useAuth';
import { colors, radii, spacing, typography } from '@/lib/theme';

export function SettingsScreen() {
  const { user, signOut } = useAuth();

  function confirmSignOut() {
    Alert.alert('Sign out?', 'You can come back any time.', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Sign out', style: 'destructive', onPress: () => signOut() },
    ]);
  }

  return (
    <Screen scroll>
      <View style={styles.header}>
        <Badge label="Settings" />
        <Text style={styles.h1}>Account</Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.label}>Signed in as</Text>
        <Text style={styles.value}>{user?.email ?? '—'}</Text>
      </View>

      <Pressable style={styles.row}>
        <Text style={styles.rowLabel}>Privacy policy</Text>
        <Text style={styles.rowChev}>›</Text>
      </Pressable>
      <Pressable style={styles.row}>
        <Text style={styles.rowLabel}>Terms of service</Text>
        <Text style={styles.rowChev}>›</Text>
      </Pressable>
      <Pressable style={styles.row}>
        <Text style={styles.rowLabel}>Send feedback</Text>
        <Text style={styles.rowChev}>›</Text>
      </Pressable>

      <View style={{ height: spacing.xl }} />
      <Button label="Sign out" variant="danger" onPress={confirmSignOut} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { marginVertical: spacing.lg, gap: spacing.sm },
  h1: { ...typography.h1, color: colors.text },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    marginBottom: spacing.md,
  },
  label: { ...typography.caption, color: colors.textDim },
  value: { ...typography.body, color: colors.text, marginTop: 4 },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: spacing.md,
    borderBottomWidth: 1,
    borderBottomColor: colors.border,
  },
  rowLabel: { ...typography.body, color: colors.text },
  rowChev: { ...typography.h2, color: colors.textDim },
});
