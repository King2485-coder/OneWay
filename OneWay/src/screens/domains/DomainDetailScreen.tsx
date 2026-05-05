import React, { useCallback, useState } from 'react';
import { View, Text, StyleSheet, ActivityIndicator } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { supabase } from '@/lib/supabase';
import { colors, radii, spacing, typography } from '@/lib/theme';
import type { Domain, Site } from '@/types/database';
import type { DomainsStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<DomainsStackParamList, 'DomainDetail'>;

export function DomainDetailScreen({ route, navigation }: Props) {
  const { slug } = route.params;
  const [domain, setDomain] = useState<Domain | null>(null);
  const [site, setSite] = useState<Site | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    const [{ data: d, error: dErr }, { data: s }] = await Promise.all([
      supabase.from('ow_domains').select('*').eq('slug', slug).maybeSingle(),
      supabase.from('ow_sites').select('*').eq('domain_slug', slug).maybeSingle(),
    ]);
    if (dErr) {
      setError(dErr.message);
      return;
    }
    setDomain(d as Domain | null);
    setSite(s as Site | null);
  }, [slug]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load])
  );

  if (error) {
    return (
      <Screen>
        <Text style={styles.error}>{error}</Text>
      </Screen>
    );
  }

  if (!domain) {
    return (
      <Screen>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }

  return (
    <Screen scroll>
      <View style={styles.heroCard}>
        <Text style={styles.slug}>{domain.slug}.oneway.app</Text>
        <View style={styles.row}>
          <Badge
            label={domain.status}
            tone={domain.status === 'active' ? 'success' : 'danger'}
          />
          <Text style={styles.expiry}>
            Renews {new Date(domain.expires_at).toLocaleDateString()}
          </Text>
        </View>
      </View>

      <Text style={styles.h2}>Site</Text>
      {site ? (
        <View style={styles.siteCard}>
          <Text style={styles.siteTitle}>{site.title}</Text>
          {site.description ? <Text style={styles.siteDesc}>{site.description}</Text> : null}
          <View style={styles.row}>
            <Badge label={site.mode} tone="accent" />
            <Badge
              label={site.published ? 'Published' : 'Draft'}
              tone={site.published ? 'success' : 'muted'}
            />
          </View>
        </View>
      ) : (
        <Text style={styles.body}>No site yet — start with a no-code, code, or AI build.</Text>
      )}

      <View style={{ height: spacing.lg }} />

      <Button
        label={site ? 'Edit site' : 'Create site'}
        onPress={() => navigation.navigate('EditSite', { slug })}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  heroCard: {
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    marginVertical: spacing.lg,
    gap: spacing.sm,
  },
  slug: { ...typography.display, color: colors.accent, fontSize: 24 },
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  expiry: { ...typography.caption, color: colors.textMuted },
  h2: { ...typography.h2, color: colors.text, marginBottom: spacing.sm },
  siteCard: {
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  siteTitle: { ...typography.h2, color: colors.text },
  siteDesc: { ...typography.body, color: colors.textMuted },
  body: { ...typography.body, color: colors.textMuted },
  error: { ...typography.body, color: colors.danger },
});
