const { prisma } = require('../../../lib/db');

async function query(sql, params = []) {
  const prepared = prepare(sql);
  const normalized = prepared.trim().toLowerCase();
  if (normalized.startsWith('select')) {
    const rows = await prisma.$queryRawUnsafe(prepared, ...params);
    return { rows: Array.isArray(rows) ? rows : [] };
  }
  await prisma.$executeRawUnsafe(prepared, ...params);
  return { rows: [], rowCount: 0 };
}

async function withTransaction(callback) {
  return prisma.$transaction(async (tx) => {
    const client = {
      query: async (sql, params = []) => {
        const prepared = prepare(sql);
        const normalized = prepared.trim().toLowerCase();
        if (normalized.startsWith('select')) {
          const rows = await tx.$queryRawUnsafe(prepared, ...params);
          return { rows: Array.isArray(rows) ? rows : [] };
        }
        await tx.$executeRawUnsafe(prepared, ...params);
        return { rows: [], rowCount: 0 };
      },
    };
    return callback(client);
  });
}

function prepare(sql) {
  return String(sql || '').replace(/\$(\d+)/g, '?');
}

module.exports = { prisma, query, withTransaction };
