CREATE TABLE IF NOT EXISTS "SocialComment" (
 "id" TEXT NOT NULL PRIMARY KEY, "postId" TEXT NOT NULL, "authorId" TEXT NOT NULL,
 "body" TEXT NOT NULL DEFAULT '', "kind" TEXT NOT NULL DEFAULT 'text', "storageKey" TEXT,
 "mimeType" TEXT, "fileName" TEXT, "byteCount" INTEGER, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY ("postId") REFERENCES "SocialPost"("id") ON DELETE CASCADE ON UPDATE CASCADE,
 FOREIGN KEY ("authorId") REFERENCES "SocialProfile"("userId") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX IF NOT EXISTS "SocialComment_postId_createdAt_id_idx" ON "SocialComment"("postId", "createdAt", "id");
CREATE TABLE IF NOT EXISTS "SocialCommentReport" (
 "id" TEXT NOT NULL PRIMARY KEY, "commentId" TEXT NOT NULL, "reporterId" TEXT NOT NULL,
 "reason" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY ("commentId") REFERENCES "SocialComment"("id") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS "SocialCommentReport_reporterId_commentId_key" ON "SocialCommentReport"("reporterId", "commentId");
