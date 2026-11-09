import type { LedgerPostResult } from "./LedgerBalanceService";
import { LedgerBalanceService } from "./LedgerBalanceService";

export interface MoneyMovementInput {
  accountId: string;
  amountCents: number;
  currency?: string;
  externalId?: string | null;
  unitTxId?: string | null;
  stripeId?: string | null;
  metadata?: Record<string, unknown>;
}

/**
 * Compliance-facing money movement API.
 *
 * This is intentionally thin: business validation happens before this layer,
 * then every movement posts immutable ledger entries and refreshes account
 * balance projections from the ledger. No caller should mutate account balance
 * columns directly.
 */
export class FinancialComplianceService {
  constructor(private readonly ledger: LedgerBalanceService) {}

  processDeposit(input: MoneyMovementInput): Promise<LedgerPostResult> {
    return this.ledger.postLedgerTransaction({
      accountId: input.accountId,
      amountCents: input.amountCents,
      currency: input.currency,
      type: "deposit",
      direction: "credit",
      externalId: input.externalId,
      unitTxId: input.unitTxId,
      stripeId: input.stripeId,
      metadata: input.metadata,
      description: "External deposit posted through compliance pipeline.",
    });
  }

  processWithdrawal(input: MoneyMovementInput & { allowNegativeBalance?: boolean }): Promise<LedgerPostResult> {
    return this.ledger.postLedgerTransaction({
      accountId: input.accountId,
      amountCents: input.amountCents,
      currency: input.currency,
      type: "withdrawal",
      direction: "debit",
      externalId: input.externalId,
      unitTxId: input.unitTxId,
      stripeId: input.stripeId,
      metadata: input.metadata,
      allowNegativeBalance: input.allowNegativeBalance,
      description: "External withdrawal posted through compliance pipeline.",
    });
  }

  processStorefrontPayment(input: MoneyMovementInput): Promise<LedgerPostResult> {
    return this.ledger.postLedgerTransaction({
      accountId: input.accountId,
      amountCents: input.amountCents,
      currency: input.currency,
      type: "storefront_payment",
      direction: "credit",
      externalId: input.externalId,
      unitTxId: input.unitTxId,
      stripeId: input.stripeId,
      metadata: input.metadata,
      counterpartyAccountId: "system:storefront-clearing",
      description: "Storefront payment credited through ledger pipeline.",
    });
  }

  processDisputeProvisionalCredit(input: MoneyMovementInput): Promise<LedgerPostResult> {
    return this.ledger.postLedgerTransaction({
      accountId: input.accountId,
      amountCents: input.amountCents,
      currency: input.currency,
      type: "dispute_provisional_credit",
      direction: "credit",
      externalId: input.externalId,
      unitTxId: input.unitTxId,
      stripeId: input.stripeId,
      metadata: input.metadata,
      counterpartyAccountId: "system:dispute-provisional",
      description: "Dispute provisional credit posted as reversible ledger movement.",
    });
  }

  processReversal(input: {
    accountId: string;
    transactionId: string;
    externalId?: string | null;
    metadata?: Record<string, unknown>;
  }): Promise<LedgerPostResult> {
    return this.ledger.reverseTransaction(input);
  }
}
