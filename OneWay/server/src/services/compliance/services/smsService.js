const logger = require('../utils/logger');

async function sendOTP(phone) {
  logger.info({ phone }, '[compliance] sms stubbed');
  return { provider: 'stub', status: 'stubbed' };
}

module.exports = { sendOTP };
