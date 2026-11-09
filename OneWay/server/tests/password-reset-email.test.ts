import assert from "node:assert/strict";
import test from "node:test";
import type { PrismaClient } from "@prisma/client";
import type { EmailProvider } from "../src/services/email/EmailProvider";
import {
  getEmailDeliveryReadiness,
  resolveConfiguredEmailProvider,
} from "../src/services/email/createEmailProvider";
import { issuePasswordReset } from "../src/services/auth/PasswordResetService";

test("email provider is inferred from complete credentials when EMAIL_PROVIDER is omitted", () => {
  assert.equal(resolveConfiguredEmailProvider({
    MAILGUN_API_KEY: "key",
    ONEWAY_EMAIL_DOMAIN: "oneway.is",
  }), "mailgun");

  assert.equal(resolveConfiguredEmailProvider({
    SENDGRID_API_KEY: "key",
    SENDGRID_FROM_EMAIL: "no-reply@oneway.is",
  }), "sendgrid");

  assert.equal(resolveConfiguredEmailProvider({}), "stub");
});

test("email readiness identifies missing live-delivery configuration without exposing secrets", () => {
  assert.deepEqual(getEmailDeliveryReadiness({ EMAIL_PROVIDER: "mailgun" }), {
    ready: false,
    provider: "mailgun",
    missing: ["MAILGUN_API_KEY", "ONEWAY_EMAIL_DOMAIN or MAILGUN_DOMAIN"],
  });
  assert.deepEqual(getEmailDeliveryReadiness({
    EMAIL_PROVIDER: "mailgun",
    MAILGUN_API_KEY: "secret",
    MAILGUN_DOMAIN: "oneway.is",
  }), {
    ready: true,
    provider: "mailgun",
    missing: [],
  });
});

test("a stubbed reset email invalidates the undelivered code", async () => {
  const { prisma, tokenUpdates } = fakePrisma();
  const provider: EmailProvider = {
    name: "stub",
    async sendOutboundMessage() {
      return {
        providerMessageId: "stub-1",
        provider: "stub",
        status: "stubbed",
      };
    },
  };

  await assert.rejects(() => issuePasswordReset(prisma, "customer@example.com", provider));
  assert.equal(tokenUpdates.length, 2);
  assert.deepEqual(tokenUpdates[1]?.where, { id: "reset-1", consumedAt: null });
});

test("a provider-accepted reset email leaves its code active", async () => {
  const { prisma, tokenUpdates } = fakePrisma();
  const provider: EmailProvider = {
    name: "mailgun",
    async sendOutboundMessage() {
      return {
        providerMessageId: "mailgun-1",
        provider: "mailgun",
        status: "queued",
      };
    },
  };

  await issuePasswordReset(prisma, "customer@example.com", provider);
  assert.equal(tokenUpdates.length, 1);
});

function fakePrisma(): {
  prisma: PrismaClient;
  tokenUpdates: Array<{ where: unknown; data: unknown }>;
} {
  const tokenUpdates: Array<{ where: unknown; data: unknown }> = [];
  const prisma = {
    user: {
      findUnique: async ({ where }: { where: { email?: string; id?: string } }) => ({
        id: where.id ?? "user-1",
        email: "customer@example.com",
        accountStatus: "active",
      }),
    },
    oneWayIdentity: {
      findUnique: async () => null,
      findFirst: async () => null,
    },
    passwordResetToken: {
      updateMany: async (args: { where: unknown; data: unknown }) => {
        tokenUpdates.push(args);
        return { count: 1 };
      },
      create: async () => ({ id: "reset-1" }),
    },
    $transaction: async (operations: Array<Promise<unknown>>) => Promise.all(operations),
  } as unknown as PrismaClient;
  return { prisma, tokenUpdates };
}
