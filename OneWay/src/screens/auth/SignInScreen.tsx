import React, { useState } from 'react';
import { View, Text, StyleSheet, Alert } from 'react-native';
import { Screen } from '@/components/Screen';
import { Input } from '@/components/Input';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { useAuth } from '@/hooks/useAuth';
import { colors, spacing, typography } from '@/lib/theme';

export function SignInScreen() {
  const { signInWithEmail } = useAuth();
  const [email, setEmail] = useState('');
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  async function send() {
    if (!email.includes('@')) {
      Alert.alert('Invalid email', 'Use a real email address.');
      return;
    }
    setLoading(true);
    const { error } = await signInWithEmail(email);
    setLoading(false);
    if (error) {
      Alert.alert("Couldn't send link", error.message);
      return;
    }
    setSent(true);
  }

  return (
    <Screen scroll>
      <View style={styles.header}>
        <Badge label="Sign in" />
        <Text style={styles.h1}>Welcome to OneWay</Text>
        <Text style={styles.body}>
          We'll send a magic link to your email. No passwords, no tracking pixels.
        </Text>
      </View>
      <Input
        label="Email"
        placeholder="you@example.com"
        keyboardType="email-address"
        value={email}
        onChangeText={setEmail}
        editable={!sent}
      />
      {sent ? (
        <Text style={styles.sent}>
          ✓ Link sent. Check your inbox and tap the link to come back here.
        </Text>
      ) : (
        <Button label="Send magic link" onPress={send} loading={loading} />
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { marginVertical: spacing.xl },
  h1: { ...typography.h1, color: colors.text, marginTop: spacing.md, marginBottom: spacing.sm },
  body: { ...typography.body, color: colors.textMuted, lineHeight: 22 },
  sent: { ...typography.body, color: colors.success, marginTop: spacing.md },
});
