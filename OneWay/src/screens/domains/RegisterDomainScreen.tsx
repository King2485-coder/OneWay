import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, Alert } from 'react-native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Input } from '@/components/Input';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { isSlugAvailable, registerDomain, validateSlug } from '@/api/domains';
import { colors, spacing, typography } from '@/lib/theme';
import type { DomainsStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<DomainsStackParamList, 'RegisterDomain'>;

type Status = 'idle' | 'checking' | 'available' | 'taken' | 'invalid';

export function RegisterDomainScreen({ route, navigation }: Props) {
  const [slug, setSlug] = useState(route.params?.initialSlug ?? '');
  const [status, setStatus] = useState<Status>('idle');
  const [reason, setReason] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Debounced availability check
  useEffect(() => {
    const v = validateSlug(slug);
    if (!v.ok) {
      setStatus(slug ? 'invalid' : 'idle');
      setReason(slug ? v.reason : null);
      return;
    }
    setStatus('checking');
    setReason(null);
    const t = setTimeout(async () => {
      try {
        const ok = await isSlugAvailable(v.slug);
        setStatus(ok ? 'available' : 'taken');
      } catch {
        setStatus('idle');
      }
    }, 350);
    return () => clearTimeout(t);
  }, [slug]);

  async function submit() {
    const v = validateSlug(slug);
    if (!v.ok) return;
    setSubmitting(true);
    try {
      // TODO: kick off Apple IAP / Stripe before inserting in production.
      const domain = await registerDomain({
        slug: v.slug,
        payment_method: 'apple_iap',
      });
      navigation.replace('DomainDetail', { slug: domain.slug });
    } catch (e: any) {
      Alert.alert('Could not register', e.message ?? String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Screen scroll>
      <Text style={styles.h1}>Pick your domain</Text>
      <Text style={styles.body}>
        Letters, numbers, and dashes — 2–32 characters. $3.99/year, renews on your terms.
      </Text>

      <Input
        label="Name"
        placeholder="mira"
        value={slug}
        onChangeText={(t) => setSlug(t.toLowerCase())}
        autoCapitalize="none"
        error={status === 'invalid' ? reason ?? undefined : undefined}
      />

      <View style={styles.preview}>
        <Text style={styles.previewLabel}>Preview</Text>
        <Text style={styles.previewDomain}>
          {(slug || 'name').trim() || 'name'}.oneway.app
        </Text>
        {status === 'checking' && <Badge label="Checking…" tone="muted" />}
        {status === 'available' && <Badge label="Available" tone="success" />}
        {status === 'taken' && <Badge label="Taken" tone="danger" />}
      </View>

      <Button
        label="Register for $3.99/year"
        onPress={submit}
        loading={submitting}
        disabled={status !== 'available'}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  h1: { ...typography.h1, color: colors.text, marginTop: spacing.md, marginBottom: spacing.xs },
  body: { ...typography.body, color: colors.textMuted, marginBottom: spacing.lg, lineHeight: 22 },
  preview: {
    backgroundColor: colors.surface,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: 12,
    padding: spacing.lg,
    marginBottom: spacing.lg,
    gap: spacing.sm,
  },
  previewLabel: { ...typography.caption, color: colors.textDim },
  previewDomain: { ...typography.h2, color: colors.accent },
});
