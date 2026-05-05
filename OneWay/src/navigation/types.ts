import type { NavigatorScreenParams } from '@react-navigation/native';

export type AuthStackParamList = {
  Onboarding: undefined;
  SignIn: undefined;
};

export type DomainsStackParamList = {
  MyDomains: undefined;
  RegisterDomain: { initialSlug?: string } | undefined;
  DomainDetail: { slug: string };
  EditSite: { slug: string };
};

export type BrowserStackParamList = {
  BrowserHome: undefined;
  Site: { url: string };
  Directory: undefined;
};

export type MainTabsParamList = {
  Browser: NavigatorScreenParams<BrowserStackParamList>;
  Domains: NavigatorScreenParams<DomainsStackParamList>;
  Settings: undefined;
};

export type RootStackParamList = {
  Auth: NavigatorScreenParams<AuthStackParamList>;
  Main: NavigatorScreenParams<MainTabsParamList>;
};
