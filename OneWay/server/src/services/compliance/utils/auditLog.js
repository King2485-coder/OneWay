const logger = require('./logger');

async function auditLog(event) {
  logger.info(event || {}, '[compliance] audit log stubbed');
}

module.exports = { auditLog };
