import React, { useCallback, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  Pressable,
  ActivityIndicator,
  RefreshControl,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { listMyDomains } from '@/api/domains';
import type { Domain } from '@/types/database';
import { colors, radii, spacing, typography } from '@/lib/theme';
import type { DomainsStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<DomainsStackParamList, 'MyDomains'>;

export function MyDomainsScreen({ navigation }: Props) {
  const [domains, setDomains] = useState<Domain[] | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setError(null);
      const rows = await listMyDomains();
      setDomains(rows);
    } catch (e: any) {
      setError(e.message ?? String(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load])
  );

  if (!domains && !error) {
    return (
      <Screen>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }

  return (
    <Screen padded={false}>
      <FlatList
        data={domains ?? []}
        keyExtractor={(d) => d.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={async () => {
              setRefreshing(true);
              await load();
              setRefreshing(false);
            }}
            tintColor={colors.accent}
          />
        }
        ListHeaderComponent={
          <View style={styles.header}>
            <Text style={styles.h1}>Your domains</Text>
            <Text style={styles.body}>
              Each one is yours for a year — renew anytime before it expires.
            </Text>
            <Button
              label="Register a domain"
              onPress={() => navigation.navigate('RegisterDomain')}
              style={{ marginTop: spacing.lg }}
            />
            {error ? <Text style={styles.error}>{error}</Text> : null}
          </View>
        }
        ListEmptyComponent={
          !error ? (
            <Text style={styles.empty}>No domains yet. Register your first one above.</Text>
          ) : null
        }
        renderItem={({ item }) => (
          <Pressable
            style={styles.card}
            onPress={() => navigation.navigate('DomainDetail', { slug: item.slug })}
          >
            <View style={styles.cardRow}>
              <Text style={styles.slug}>{item.slug}.oneway.app</Text>
              <Badge
                label={item.status}
                tone={
                  item.status === 'active'
                    ? 'success'
                    : item.status === 'pending'
                    ? 'muted'
                    : 'danger'
                }
              />
            </View>
            <Text style={styles.expiry}>
              Expires {new Date(item.expires_at).toLocaleDateString()}
            </Text>
          </Pressable>
        )}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl },
  header: { marginBottom: spacing.md },
  h1: { ...typography.h1, color: colors.text },
  body: { ...typography.body, color: colors.textMuted, marginTop: spacing.xs },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radii.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
  },
  cardRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  slug: { ...typography.h2, color: colors.accent },
  expiry: { ...typography.caption, color: colors.textMuted, marginTop: spacing.xs },
  empty: { ...typography.body, color: colors.textMuted, textAlign: 'center' },
  error: { ...typography.body, color: colors.danger, marginTop: spacing.md },
});
