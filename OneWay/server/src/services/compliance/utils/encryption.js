let fieldEncryption;
try {
  fieldEncryption = require("../../privacy/EncryptionService");
} catch {
  fieldEncryption = null;
}

function encryptComplianceText(value, field) {
  const text = value == null ? "" : String(value);
  if (!fieldEncryption?.encryptIfEnabled) return text;
  return fieldEncryption.encryptIfEnabled(text, `compliance:${field}`);
}

function encryptComplianceJson(value, field) {
  const text = JSON.stringify(value || {});
  if (!fieldEncryption?.encryptIfEnabled) return text;
  return fieldEncryption.encryptIfEnabled(text, `compliance:${field}`);
}

function decryptComplianceText(value, field) {
  const text = value == null ? "" : String(value);
  if (!fieldEncryption?.decryptIfEncrypted) return text;
  return fieldEncryption.decryptIfEncrypted(text, `compliance:${field}`);
}

function decryptComplianceJson(value, field) {
  const text = decryptComplianceText(value, field);
  try { return JSON.parse(text); } catch { return {}; }
}

module.exports = {
  encryptComplianceText,
  encryptComplianceJson,
  decryptComplianceText,
  decryptComplianceJson,
};
