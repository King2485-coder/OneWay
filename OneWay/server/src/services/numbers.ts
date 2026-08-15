import { prisma } from "../lib/db";
import { loadPublicIdentity } from "./identity";

export const EXTRA_NUMBERS_PRODUCT_ID = "oneway.extra_numbers.monthly";

export interface CallerIdentity {
  callerName: string;
  callerNumber: string;
  callerDisplay: string;
}

export async function generateUniqueOneWayNumber(): Promise<string> {
  while (true) {
    const number = `OW-${Math.floor(100000 + Math.random() * 900000)}`;
    const existing = await prisma.userNumber.findUnique({
      where: { number },
      select: { id: true },
    });
    if (!existing) {
      return number;
    }
  }
}

export async function assignInitialFreeNumbers(userId: string, targetCount = 2): Promise<void> {
  const existing = await prisma.userNumber.findMany({
    where: { userId, isPaid: false },
    orderBy: [{ isPrimary: "desc" }, { createdAt: "asc" }],
  });

  const labels = ["Personal", "Fun"];
  const created = [...existing];
  while (created.length < targetCount) {
    const number = await generateUniqueOneWayNumber();
    const item = await prisma.userNumber.create({
      data: {
        userId,
        number,
        label: labels[created.length] ?? "OneWay number",
        isPrimary: created.length === 0,
        isPaid: false,
      },
    });
    created.push(item);
  }
}

export async function assignInitialNumber(userId: string): Promise<void> {
  await assignInitialFreeNumbers(userId, 2);
}

export async function userHasExtraNumberSubscription(userId: string): Promise<boolean> {
  const now = new Date();
  const active = await prisma.subscription.findFirst({
    where: {
      userId,
      productId: EXTRA_NUMBERS_PRODUCT_ID,
      status: "active",
      OR: [
        { expiresAt: null },
        { expiresAt: { gt: now } },
      ],
    },
    select: { id: true },
  });

  return Boolean(active);
}

export async function loadCallerIdentity(userId: string): Promise<CallerIdentity> {
  const [identity, user] = await Promise.all([
    loadPublicIdentity(userId),
    prisma.user.findUnique({
    where: { id: userId },
    select: {
      numbers: {
        where: { isPrimary: true },
        orderBy: { createdAt: "asc" },
        take: 1,
        select: { number: true },
      },
    },
  }),
  ]);

  const primaryNumber = user?.numbers[0]?.number ?? userId;
  const preferredIdentity =
    identity.preferredCallerIdentity == "number" && primaryNumber
      ? primaryNumber
      : identity.onewayId || primaryNumber;

  return {
    callerName: identity.displayName,
    callerNumber: preferredIdentity,
    callerDisplay: ["OneWay", identity.displayName, preferredIdentity].join("\n"),
  };
}
