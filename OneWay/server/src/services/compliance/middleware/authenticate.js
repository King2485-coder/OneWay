const { authMiddleware } = require('../../../middleware/auth');

function authenticate(req, res, next) {
  return authMiddleware(req, res, next);
}

function requireKYC(_req, _res, next) {
  next();
}

module.exports = { authenticate, requireKYC };
