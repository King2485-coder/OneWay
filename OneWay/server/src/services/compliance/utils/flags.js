function envFlag(name, defaultValue = false) {
  const value = process.env[name];
  if (value == null || String(value).trim() === '') return defaultValue;
  return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());
}

function complianceLayerEnabled() {
  return envFlag('COMPLIANCE_LAYER_ENABLED', false);
}

function oneWayBankEnabled() {
  return envFlag('ONEWAY_BANK_ENABLED', false);
}

function ledgerEnabled() {
  return complianceLayerEnabled() && envFlag('LEDGER_ENABLED', false);
}

function reconciliationEnabled() {
  return complianceLayerEnabled() && envFlag('RECONCILIATION_ENABLED', false);
}

function disputesEnabled() {
  return complianceLayerEnabled() && envFlag('DISPUTES_ENABLED', false);
}

function assertBankEnabled(operation = 'OneWay Bank money movement') {
  if (!oneWayBankEnabled()) {
    const error = new Error(`${operation} is disabled. Storefront payments currently use Stripe/payment links.`);
    error.code = 'oneway_bank_disabled';
    error.statusCode = 503;
    throw error;
  }
}

module.exports = {
  envFlag,
  complianceLayerEnabled,
  oneWayBankEnabled,
  ledgerEnabled,
  reconciliationEnabled,
  disputesEnabled,
  assertBankEnabled,
};
