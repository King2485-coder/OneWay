const logger = require('../utils/logger');

async function sendEmail(to, subject, body) {
  logger.info({ to, subject }, '[compliance] email stubbed');
  return { provider: 'stub', status: 'stubbed', to, subject, bodyLength: String(body || '').length };
}

module.exports = { sendEmail };
