-- CreateTable
CREATE TABLE IF NOT EXISTS "SocialProfile" (
    "userId" TEXT NOT NULL PRIMARY KEY,
    "handle" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "bio" TEXT NOT NULL DEFAULT '',
    "website" TEXT NOT NULL DEFAULT '',
    "discoverable" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "SocialProfile_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE IF NOT EXISTS "SocialPost" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "authorId" TEXT NOT NULL,
    "body" TEXT NOT NULL,
    "audience" TEXT NOT NULL DEFAULT 'followers',
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SocialPost_authorId_fkey" FOREIGN KEY ("authorId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE IF NOT EXISTS "SocialFollow" (
    "followerId" TEXT NOT NULL,
    "followingId" TEXT NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY ("followerId", "followingId"),
    CONSTRAINT "SocialFollow_followerId_fkey" FOREIGN KEY ("followerId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "SocialFollow_followingId_fkey" FOREIGN KEY ("followingId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE IF NOT EXISTS "SocialBlock" (
    "blockerId" TEXT NOT NULL,
    "blockedId" TEXT NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY ("blockerId", "blockedId"),
    CONSTRAINT "SocialBlock_blockerId_fkey" FOREIGN KEY ("blockerId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "SocialBlock_blockedId_fkey" FOREIGN KEY ("blockedId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE IF NOT EXISTS "SocialReport" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "reporterId" TEXT NOT NULL,
    "postId" TEXT NOT NULL,
    "reason" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SocialReport_reporterId_fkey" FOREIGN KEY ("reporterId") REFERENCES "SocialProfile" ("userId") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "SocialReport_postId_fkey" FOREIGN KEY ("postId") REFERENCES "SocialPost" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateIndex
CREATE UNIQUE INDEX IF NOT EXISTS "SocialProfile_handle_key" ON "SocialProfile"("handle");

-- CreateIndex
CREATE INDEX IF NOT EXISTS "SocialPost_authorId_createdAt_id_idx" ON "SocialPost"("authorId", "createdAt", "id");

-- CreateIndex
CREATE INDEX IF NOT EXISTS "SocialPost_audience_createdAt_id_idx" ON "SocialPost"("audience", "createdAt", "id");

-- CreateIndex
CREATE INDEX IF NOT EXISTS "SocialFollow_followingId_idx" ON "SocialFollow"("followingId");

-- CreateIndex
CREATE INDEX IF NOT EXISTS "SocialBlock_blockedId_idx" ON "SocialBlock"("blockedId");

-- CreateIndex
CREATE INDEX IF NOT EXISTS "SocialReport_status_createdAt_idx" ON "SocialReport"("status", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX IF NOT EXISTS "SocialReport_reporterId_postId_key" ON "SocialReport"("reporterId", "postId");
