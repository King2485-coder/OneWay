import "dotenv/config";

import bcrypt from "bcryptjs";
import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

const kingEmail = "antoniohoshaw6@gmail.com";
const kingPassword = process.env.KING_ACCOUNT_PASSWORD;

async function main() {
  if (!kingPassword || kingPassword.length < 6) {
    throw new Error("Set KING_ACCOUNT_PASSWORD before running this script.");
  }

  const existingIdentity = await prisma.oneWayIdentity.findUnique({
    where: { onewayId: "@king" },
    select: { userId: true },
  });
  const existingUser = await prisma.user.findUnique({
    where: { email: kingEmail },
    select: { id: true },
  });
  const userId = existingIdentity?.userId ?? existingUser?.id;
  if (existingUser?.id && userId && existingUser.id !== userId) {
    await prisma.user.update({
      where: { id: existingUser.id },
      data: { email: null },
      select: { id: true },
    });
  }
  const passwordHash = await bcrypt.hash(kingPassword, 12);

  const user = userId
    ? await prisma.user.update({
        where: { id: userId },
        data: {
          email: kingEmail,
          displayName: "King",
          passwordHash,
        },
        select: { id: true, email: true, displayName: true },
      })
    : await prisma.user.create({
        data: {
          email: kingEmail,
          displayName: "King",
          passwordHash,
        },
        select: { id: true, email: true, displayName: true },
      });

  await prisma.oneWayIdentity.deleteMany({
    where: {
      userId: { not: user.id },
      OR: [
        { onewayId: "@king" },
        { username: "king" },
      ],
    },
  });

  await prisma.oneWayIdentity.upsert({
    where: { userId: user.id },
    create: {
      userId: user.id,
      displayName: "King",
      walkieName: "King",
      username: "king",
      usernameHidden: true,
      onewayId: "@king",
      emailAlias: "king@oneway.app",
      showEmailAlias: true,
      showOneWayId: true,
      showNumbers: true,
      preferredCallerIdentity: "onewayId",
    },
    update: {
      displayName: "King",
      walkieName: "King",
      username: "king",
      usernameHidden: true,
      onewayId: "@king",
      emailAlias: "king@oneway.app",
      showEmailAlias: true,
      showOneWayId: true,
      showNumbers: true,
      preferredCallerIdentity: "onewayId",
    },
  });

  await prisma.userNumber.updateMany({
    where: { userId: user.id },
    data: { isPrimary: false },
  });
  await upsertNumber(user.id, "OW-123456", "OneWay", true, false);
  await upsertNumber(user.id, "+15205238383", "Business", false, true);
  await prisma.businessPresence.upsert({
    where: { userId: user.id },
    create: {
      userId: user.id,
      businessName: "King",
      publicPhoneNumber: "+15205238383",
      setupStep: "complete",
      onboardingProgress: 100,
    },
    update: {
      businessName: "King",
      publicPhoneNumber: "+15205238383",
      setupStep: "complete",
      onboardingProgress: 100,
    },
  });
  await prisma.walkiePrivacySettings.upsert({
    where: { userId: user.id },
    create: {
      userId: user.id,
      allowFriends: true,
      allowFriendsOfFriends: true,
      allowAnyone: true,
    },
    update: {
      allowFriends: true,
      allowFriendsOfFriends: true,
      allowAnyone: true,
    },
  });

  console.log(JSON.stringify({
    ok: true,
    userId: redact(user.id),
    email: user.email,
    handle: "@king",
    username: "king",
    oneWayNumber: "OW-123456",
    businessNumber: "+15205238383",
  }, null, 2));
}

async function upsertNumber(userId: string, number: string, label: string, isPrimary: boolean, isPaid: boolean) {
  await prisma.userNumber.upsert({
    where: { number },
    create: {
      userId,
      number,
      label,
      isPrimary,
      isPaid,
    },
    update: {
      userId,
      label,
      isPrimary,
      isPaid,
    },
  });
}

function redact(value: string) {
  return value.length <= 8 ? "redacted" : `${value.slice(0, 6)}…${value.slice(-6)}`;
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
