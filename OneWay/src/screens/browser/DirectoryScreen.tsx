import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, FlatList, Pressable, ActivityIndicator } from 'react-native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { supabase } from '@/lib/supabase';
import { colors, radii, spacing, typography } from '@/lib/theme';
import type { BrowserStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<BrowserStackParamList, 'Directory'>;

interface DirectoryItem {
  slug: string;
  description: string | null;
  title: string | null;
}

export function DirectoryScreen({ navigation }: Props) {
  const [items, setItems] = useState<DirectoryItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    (async () => {
      const { data, error } = await supabase
        .from('ow_domains')
        .select('slug, ow_sites(title, description)')
        .eq('status', 'active')
        .not('site_id', 'is', null)
        .limit(100);
      if (!mounted) return;
      if (error) {
        setError(error.message);
        return;
      }
      setItems(
        (data ?? []).map((d: any) => ({
          slug: d.slug,
          title: d.ow_sites?.title ?? null,
          description: d.ow_sites?.description ?? null,
        }))
      );
    })();
    return () => {
      mounted = false;
    };
  }, []);

  if (error) {
    return (
      <Screen>
        <Text style={styles.error}>Couldn't load the directory: {error}</Text>
      </Screen>
    );
  }

  if (!items) {
    return (
      <Screen>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }

  return (
    <Screen padded={false}>
      <FlatList
        data={items}
        keyExtractor={(it) => it.slug}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <Text style={styles.empty}>No sites yet — be the first to publish one.</Text>
        }
        renderItem={({ item }) => (
          <Pressable
            style={styles.card}
            onPress={() =>
              navigation.navigate('Site', { url: `https://${item.slug}.oneway.app` })
            }
          >
            <Text style={styles.slug}>{item.slug}.oneway.app</Text>
            {item.title ? <Text style={styles.title}>{item.title}</Text> : null}
            {item.description ? <Text style={styles.desc}>{item.description}</Text> : null}
          </Pressable>
        )}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { padding: spacing.lg, gap: spacing.md },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
  },
  slug: { ...typography.h2, color: colors.accent },
  title: { ...typography.body, color: colors.text, marginTop: 4 },
  desc: { ...typography.caption, color: colors.textMuted, marginTop: 4 },
  empty: { ...typography.body, color: colors.textMuted, textAlign: 'center', padding: spacing.xl },
  error: { ...typography.body, color: colors.danger },
});
