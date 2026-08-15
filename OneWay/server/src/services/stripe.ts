interface StripeModule {
  new (secretKey: string, config?: { apiVersion?: string }): {
    accounts: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string): Promise<Record<string, any>>;
    };
    accountLinks: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    loginLinks?: {
      create(account: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    billingPortal?: {
      sessions: {
        create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      };
    };
    customers: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string): Promise<Record<string, any>>;
    };
    checkout: {
      sessions: {
        create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<{
          id: string;
          url: string | null;
        }>;
        retrieve(id: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      };
    };
    prices: {
      retrieve(id: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    paymentIntents: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string): Promise<Record<string, any>>;
      cancel(id: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    refunds: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    transfers?: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    setupIntents: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    subscriptions: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      update(id: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    subscriptionSchedules: {
      create(input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      retrieve(id: string, input?: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
      update(id: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<Record<string, any>>;
    };
    webhooks: {
      constructEvent(payload: string | Buffer, signature: string, secret: string): Record<string, any>;
    };
  };
}

let stripeCtor: StripeModule | null | undefined;

function loadStripe(): StripeModule | null {
  if (stripeCtor !== undefined) return stripeCtor;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    stripeCtor = require("stripe") as StripeModule;
  } catch {
    stripeCtor = null;
  }
  return stripeCtor;
}

export function createStripeClient(): InstanceType<StripeModule> | null {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  const Stripe = loadStripe();
  if (!secretKey || !Stripe) return null;
  return new Stripe(secretKey);
}

export function stripeConfigured(): boolean {
  return Boolean(process.env.STRIPE_SECRET_KEY?.trim());
}
