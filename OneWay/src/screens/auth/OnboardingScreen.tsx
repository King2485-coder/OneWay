import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { colors, spacing, typography } from '@/lib/theme';
import type { AuthStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<AuthStackParamList, 'Onboarding'>;

export function OnboardingScreen({ navigation }: Props) {
  return (
    <Screen>
      <View style={styles.center}>
        <Text style={styles.logo}>✈️</Text>
        <Badge label="OneWay" />
        <Text style={styles.h1}>The private web,{'\n'}yours to own.</Text>
        <Text style={styles.body}>
          Claim a name. Build a private site. Share it on your terms — no trackers, no platforms,
          no middlemen.
        </Text>
      </View>
      <View>
        <Button label="Get started" onPress={() => navigation.navigate('SignIn')} />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  logo: { fontSize: 64, marginBottom: spacing.lg },
  h1: {
    ...typography.display,
    color: colors.text,
    textAlign: 'center',
    marginTop: spacing.lg,
    marginBottom: spacing.md,
  },
  body: {
    ...typography.body,
    color: colors.textMuted,
    textAlign: 'center',
    maxWidth: 320,
    lineHeight: 22,
  },
});
