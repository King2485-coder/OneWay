import * as Linking from 'expo-linking';
import type { LinkingOptions } from '@react-navigation/native';
import type { RootStackParamList } from './types';

// Deep links:
//   oneway://register?slug=foo            → RegisterDomain with prefilled slug
//   oneway://site/foo                     → BrowserHome → Site for foo.oneway.app
//   https://*.oneway.app                  → handled via universal links
export const linking: LinkingOptions<RootStackParamList> = {
  prefixes: [Linking.createURL('/'), 'oneway://', 'https://oneway.app'],
  config: {
    screens: {
      Auth: {
        screens: {
          Onboarding: 'onboarding',
          SignIn: 'signin',
        },
      },
      Main: {
        screens: {
          Browser: {
            screens: {
              BrowserHome: 'browser',
              Site: 'site/:url',
              Directory: 'directory',
            },
          },
          Domains: {
            screens: {
              MyDomains: 'domains',
              RegisterDomain: 'register',
              DomainDetail: 'domain/:slug',
              EditSite: 'site-edit/:slug',
            },
          },
          Settings: 'settings',
        },
      },
    },
  },
};
