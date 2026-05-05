import React from 'react';
import { StyleSheet, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { NativeStackScreenProps } from '@react-navigation/native-stack';
import { colors } from '@/lib/theme';
import type { BrowserStackParamList } from '@/navigation/types';

type Props = NativeStackScreenProps<BrowserStackParamList, 'Site'>;

export function SiteScreen({ route }: Props) {
  const { url } = route.params;
  return (
    <View style={styles.wrap}>
      <WebView
        source={{ uri: url }}
        style={styles.webview}
        originWhitelist={['https://*.oneway.app', 'https://oneway.app']}
        javaScriptEnabled
        domStorageEnabled={false}
        thirdPartyCookiesEnabled={false}
        sharedCookiesEnabled={false}
        cacheEnabled
      />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: colors.bg },
  webview: { flex: 1, backgroundColor: colors.bg },
});
