export type WalletPaymentStatus = "not_started" | "pending" | "authorized" | "paid" | "failed" | "refunded";

export type WalletProviderName = "mock" | "real_placeholder" | "unavailable";

export interface WalletServiceStatus {
  available: boolean;
  provider: WalletProviderName;
  enabled: boolean;
  mockMode: boolean;
  message: string;
  testModeWarning?: string;
}

export interface WalletCheckoutInput {
  orderId: string;
  amountCents: number;
  buyerWalletUserId?: string | null;
  sellerWalletUserId?: string | null;
}

export interface WalletPaymentResult {
  walletPaymentId: string;
  walletPaymentStatus: WalletPaymentStatus;
  provider: WalletProviderName;
  testModeWarning?: string;
}

export interface OneWayWalletPaymentService {
  getStatus(): Promise<WalletServiceStatus>;
  createCheckout(input: WalletCheckoutInput): Promise<WalletPaymentResult>;
  authorizePayment(orderId: string, amountCents: number): Promise<WalletPaymentResult>;
  capturePayment(orderId: string): Promise<WalletPaymentResult>;
  refundPayment(orderId: string): Promise<WalletPaymentResult>;
}

export class WalletPaymentError extends Error {
  constructor(
    public readonly code: "payment_setup_unavailable" | "wallet_payment_failed" | "invalid_wallet_payment",
    message: string,
    public readonly statusCode = 503,
  ) {
    super(message);
    this.name = "WalletPaymentError";
  }
}

const TEST_MODE_WARNING = "OneWay Wallet is in test mode. Do not use for real money movement.";

class MockOneWayWalletPaymentService implements OneWayWalletPaymentService {
  async getStatus(): Promise<WalletServiceStatus> {
    return {
      available: true,
      provider: "mock",
      enabled: false,
      mockMode: true,
      message: "OneWay Wallet test checkout is available.",
      testModeWarning: TEST_MODE_WARNING,
    };
  }

  async createCheckout(input: WalletCheckoutInput): Promise<WalletPaymentResult> {
    this.validateAmount(input.amountCents);
    if (process.env.ONEWAY_BANK_MOCK_FAIL === "true") {
      throw new WalletPaymentError("wallet_payment_failed", "OneWay Wallet test payment failed.", 502);
    }
    return {
      walletPaymentId: this.paymentId(input.orderId, input.amountCents),
      walletPaymentStatus: "pending",
      provider: "mock",
      testModeWarning: TEST_MODE_WARNING,
    };
  }

  async authorizePayment(orderId: string, amountCents: number): Promise<WalletPaymentResult> {
    this.validateAmount(amountCents);
    return {
      walletPaymentId: this.paymentId(orderId, amountCents),
      walletPaymentStatus: "authorized",
      provider: "mock",
      testModeWarning: TEST_MODE_WARNING,
    };
  }

  async capturePayment(orderId: string): Promise<WalletPaymentResult> {
    return {
      walletPaymentId: this.paymentId(orderId),
      walletPaymentStatus: "paid",
      provider: "mock",
      testModeWarning: TEST_MODE_WARNING,
    };
  }

  async refundPayment(orderId: string): Promise<WalletPaymentResult> {
    return {
      walletPaymentId: this.paymentId(orderId),
      walletPaymentStatus: "refunded",
      provider: "mock",
      testModeWarning: TEST_MODE_WARNING,
    };
  }

  private validateAmount(amountCents: number): void {
    if (!Number.isInteger(amountCents) || amountCents <= 0) {
      throw new WalletPaymentError("invalid_wallet_payment", "Enter a valid payment amount.", 400);
    }
  }

  private paymentId(orderId: string, amountCents?: number): string {
    const normalized = orderId.replace(/[^a-zA-Z0-9]/g, "").slice(0, 16) || "order";
    const suffix = amountCents ? `_${amountCents}` : "";
    return `owpay_mock_${normalized}${suffix}`;
  }
}

class RealPlaceholderOneWayWalletPaymentService implements OneWayWalletPaymentService {
  async getStatus(): Promise<WalletServiceStatus> {
    return {
      available: false,
      provider: "real_placeholder",
      enabled: true,
      mockMode: false,
      message: "OneWay Wallet provider is configured, but live bank checkout is not wired yet.",
    };
  }

  async createCheckout(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async authorizePayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async capturePayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async refundPayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }
}

class UnavailableOneWayWalletPaymentService implements OneWayWalletPaymentService {
  async getStatus(): Promise<WalletServiceStatus> {
    return {
      available: false,
      provider: "unavailable",
      enabled: false,
      mockMode: false,
      message: "OneWay Wallet is not available for this shop yet.",
    };
  }

  async createCheckout(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async authorizePayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async capturePayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }

  async refundPayment(): Promise<WalletPaymentResult> {
    throw unavailable();
  }
}

export function createOneWayWalletPaymentService(): OneWayWalletPaymentService {
  const bankEnabled = envFlag("ONEWAY_BANK_ENABLED", false);
  const mockMode = envFlag("ONEWAY_BANK_MOCK_MODE", process.env.NODE_ENV !== "production");
  const apiUrl = (process.env.ONEWAY_BANK_API_URL ?? "").trim();
  const apiKey = (process.env.ONEWAY_BANK_API_KEY ?? "").trim();

  if (!bankEnabled) {
    return new UnavailableOneWayWalletPaymentService();
  }

  if (mockMode && process.env.NODE_ENV !== "production") {
    return new MockOneWayWalletPaymentService();
  }

  if (bankEnabled && apiUrl && apiKey) {
    return new RealPlaceholderOneWayWalletPaymentService();
  }

  return new UnavailableOneWayWalletPaymentService();
}

export const oneWayWalletPaymentService = createOneWayWalletPaymentService();

function envFlag(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value == null || value.trim() === "") return defaultValue;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function unavailable(): WalletPaymentError {
  return new WalletPaymentError(
    "payment_setup_unavailable",
    "OneWay Wallet is not available for this shop yet.",
    503,
  );
}

export function isWalletPaymentError(error: unknown): error is WalletPaymentError {
  return error instanceof WalletPaymentError;
}
