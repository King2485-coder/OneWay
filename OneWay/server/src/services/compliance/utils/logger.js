const { logger } = require('../../../lib/logger');
const { redactSensitiveObject, redactSensitiveString } = require('../../../lib/privacy/redaction');

module.exports = {
  info: (...args) => logger.info(format(...args), message(...args)),
  warn: (...args) => logger.warn(format(...args), message(...args)),
  error: (...args) => logger.error(format(...args), message(...args)),
  debug: (...args) => logger.debug(format(...args), message(...args)),
};

function message(...args) {
  const raw = args.find((arg) => typeof arg === 'string') || '[compliance]';
  return redactSensitiveString(raw);
}

function format(...args) {
  const meta = args.find((arg) => arg && typeof arg === 'object' && !Array.isArray(arg));
  return redactSensitiveObject(meta || {});
}
