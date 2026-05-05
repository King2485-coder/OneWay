interface StripeModule {
  new (secretKey: string, config?: { apiVersion?: string }): {
    checkout: {
      sessions: {
        create(input: Record<string, unknown>): Promise<{
          id: string;
          url: string | null;
        }>;
      };
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
