function unavailable() {
  const error = new Error('Optional dependency axios is not installed because OneWay Bank is dormant.');
  error.code = 'oneway_bank_disabled';
  throw error;
}

try {
  module.exports = require('axios');
} catch {
  module.exports = {
    create: () => ({ get: unavailable, post: unavailable, interceptors: { response: { use: () => {} } } }),
    get: unavailable,
    post: unavailable,
  };
}
