import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, Alert, ActivityIndicator } from 'react-native';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { Screen } from '@/components/Screen';
import { Input } from '@/components/Input';
import { Button } from '@/components/Button';
import { Badge } from '@/components/Badge';
import { getSiteForSlug, publishSite, upsertSite } from '@/api/sites';
import { colors, radii, spacing, typography } from '@/lib/theme';
import type { Site, SiteMode } from '@/types/database';
import type { DomainsStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<DomainsStackParamList, 'EditSite'>;

const MODES: { mode: SiteMode; label: string; hint: string }[] = [
  { mode: 'nocode', label: 'No-code', hint: 'Stack blocks, no syntax.' },
  { mode: 'code', label: 'Code', hint: 'Hand-write HTML/CSS/JS.' },
  { mode: 'ai', label: 'AI', hint: 'Describe it; Claude builds it.' },
];

export function EditSiteScreen({ route }: Props) {
  const { slug } = route.params;
  const [site, setSite] = useState<Site | null>(null);
  const [title, setTitle] = useState('My OneWay Site');
  const [description, setDescription] = useState('');
  const [mode, setMode] = useState<SiteMode>('nocode');
  const [html, setHtml] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [publishing, setPublishing] = useState(false);

  useEffect(() => {
    let mounted = true;
    (async () => {
      try {
        const s = await getSiteForSlug(slug);
        if (!mounted) return;
        if (s) {
          setSite(s);
          setTitle(s.title);
          setDescription(s.description);
          setMode(s.mode);
          setHtml(s.html_content);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    })();
    return () => {
      mounted = false;
    };
  }, [slug]);

  async function save(opts: { thenPublish?: boolean } = {}) {
    setSaving(true);
    try {
      const next = await upsertSite({
        domain_slug: slug,
        title,
        description,
        mode,
        html_content: html,
        blocks: site?.blocks ?? [],
      });
      setSite(next);
      if (opts.thenPublish) {
        setPublishing(true);
        await publishSite(next);
        Alert.alert('Published', `${slug}.oneway.app is live.`);
      }
    } catch (e: any) {
      Alert.alert("Couldn't save", e.message ?? String(e));
    } finally {
      setSaving(false);
      setPublishing(false);
    }
  }

  if (loading) {
    return (
      <Screen>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }

  return (
    <Screen scroll>
      <Text style={styles.h1}>{slug}.oneway.app</Text>

      <View style={styles.modeRow}>
        {MODES.map((m) => (
          <View key={m.mode} style={[styles.modePill, mode === m.mode && styles.modePillActive]}>
            <Text
              onPress={() => setMode(m.mode)}
              style={[styles.modeLabel, mode === m.mode && styles.modeLabelActive]}
            >
              {m.label}
            </Text>
          </View>
        ))}
      </View>
      <Text style={styles.modeHint}>{MODES.find((m) => m.mode === mode)?.hint}</Text>

      <Input label="Title" value={title} onChangeText={setTitle} />
      <Input
        label="Description"
        value={description}
        onChangeText={setDescription}
        multiline
        numberOfLines={2}
      />

      {mode === 'code' || mode === 'ai' ? (
        <Input
          label={mode === 'ai' ? 'Generated HTML (or describe and tap Generate)' : 'HTML'}
          value={html}
          onChangeText={setHtml}
          multiline
          numberOfLines={10}
          style={{ minHeight: 180, textAlignVertical: 'top', fontFamily: 'Menlo' }}
        />
      ) : (
        <View style={styles.placeholder}>
          <Badge label="Coming soon" tone="muted" />
          <Text style={styles.placeholderText}>
            The drag-and-drop block editor lives here. For now, switch to Code mode to publish.
          </Text>
        </View>
      )}

      <View style={{ height: spacing.lg }} />
      <Button label="Save draft" variant="ghost" onPress={() => save()} loading={saving} />
      <View style={{ height: spacing.sm }} />
      <Button
        label={publishing ? 'Publishing…' : 'Save & publish'}
        onPress={() => save({ thenPublish: true })}
        loading={saving || publishing}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  h1: { ...typography.h1, color: colors.accent, marginVertical: spacing.md },
  modeRow: { flexDirection: 'row', gap: spacing.sm, marginBottom: spacing.xs },
  modePill: {
    paddingHorizontal: spacing.md,
    paddingVertical: 6,
    borderRadius: 100,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  modePillActive: { borderColor: colors.accent, backgroundColor: 'rgba(124,58,237,0.15)' },
  modeLabel: { color: colors.textMuted, fontWeight: '600' },
  modeLabelActive: { color: colors.accent },
  modeHint: { ...typography.caption, color: colors.textDim, marginBottom: spacing.lg },
  placeholder: {
    backgroundColor: colors.surface,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: radii.md,
    padding: spacing.lg,
    gap: spacing.sm,
    marginBottom: spacing.md,
  },
  placeholderText: { ...typography.body, color: colors.textMuted },
});
