import React from 'react';
import { Text } from 'react-native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { colors } from '@/lib/theme';
import { BrowserHomeScreen } from '@/screens/browser/BrowserHomeScreen';
import { SiteScreen } from '@/screens/browser/SiteScreen';
import { DirectoryScreen } from '@/screens/browser/DirectoryScreen';
import { MyDomainsScreen } from '@/screens/domains/MyDomainsScreen';
import { RegisterDomainScreen } from '@/screens/domains/RegisterDomainScreen';
import { DomainDetailScreen } from '@/screens/domains/DomainDetailScreen';
import { EditSiteScreen } from '@/screens/sites/EditSiteScreen';
import { SettingsScreen } from '@/screens/settings/SettingsScreen';
import type {
  BrowserStackParamList,
  DomainsStackParamList,
  MainTabsParamList,
} from './types';

const Tabs = createBottomTabNavigator<MainTabsParamList>();
const BrowserStack = createNativeStackNavigator<BrowserStackParamList>();
const DomainsStack = createNativeStackNavigator<DomainsStackParamList>();

function BrowserNavigator() {
  return (
    <BrowserStack.Navigator
      screenOptions={{
        headerStyle: { backgroundColor: colors.bg },
        headerTitleStyle: { color: colors.text },
        headerTintColor: colors.accent,
      }}
    >
      <BrowserStack.Screen
        name="BrowserHome"
        component={BrowserHomeScreen}
        options={{ title: 'Browser' }}
      />
      <BrowserStack.Screen name="Site" component={SiteScreen} options={{ title: '' }} />
      <BrowserStack.Screen
        name="Directory"
        component={DirectoryScreen}
        options={{ title: 'Directory' }}
      />
    </BrowserStack.Navigator>
  );
}

function DomainsNavigator() {
  return (
    <DomainsStack.Navigator
      screenOptions={{
        headerStyle: { backgroundColor: colors.bg },
        headerTitleStyle: { color: colors.text },
        headerTintColor: colors.accent,
      }}
    >
      <DomainsStack.Screen
        name="MyDomains"
        component={MyDomainsScreen}
        options={{ title: 'My Domains' }}
      />
      <DomainsStack.Screen
        name="RegisterDomain"
        component={RegisterDomainScreen}
        options={{ title: 'Register' }}
      />
      <DomainsStack.Screen
        name="DomainDetail"
        component={DomainDetailScreen}
        options={({ route }) => ({ title: `${route.params.slug}.oneway.app` })}
      />
      <DomainsStack.Screen
        name="EditSite"
        component={EditSiteScreen}
        options={{ title: 'Edit Site' }}
      />
    </DomainsStack.Navigator>
  );
}

function TabIcon({ label, focused }: { label: string; focused: boolean }) {
  return (
    <Text style={{ fontSize: 18, color: focused ? colors.accent : colors.textDim }}>{label}</Text>
  );
}

export function MainTabs() {
  return (
    <Tabs.Navigator
      screenOptions={{
        headerShown: false,
        tabBarStyle: { backgroundColor: colors.bg, borderTopColor: colors.border },
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.textDim,
      }}
    >
      <Tabs.Screen
        name="Browser"
        component={BrowserNavigator}
        options={{
          tabBarIcon: ({ focused }) => <TabIcon label="🛸" focused={focused} />,
        }}
      />
      <Tabs.Screen
        name="Domains"
        component={DomainsNavigator}
        options={{
          tabBarIcon: ({ focused }) => <TabIcon label="🪪" focused={focused} />,
        }}
      />
      <Tabs.Screen
        name="Settings"
        component={SettingsScreen}
        options={{
          tabBarIcon: ({ focused }) => <TabIcon label="⚙︎" focused={focused} />,
        }}
      />
    </Tabs.Navigator>
  );
}
