# Chaves do AR Encryption. Ver ADR-0011.
# Em produção, vêm de credentials criptografados (master.key + credentials.yml.enc).
# Em dev/test, aceitamos ENV — gere com:
#   bin/rails db:encryption:init
# e copie a saída para credentials, ou exporte:
#   AR_ENCRYPTION_PRIMARY_KEY, AR_ENCRYPTION_DETERMINISTIC_KEY, AR_ENCRYPTION_KEY_DERIVATION_SALT
config = Rails.application.config.active_record.encryption
creds  = Rails.application.credentials

config.primary_key            = creds.dig(:active_record_encryption, :primary_key)            || ENV["AR_ENCRYPTION_PRIMARY_KEY"]
config.deterministic_key      = creds.dig(:active_record_encryption, :deterministic_key)      || ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
config.key_derivation_salt    = creds.dig(:active_record_encryption, :key_derivation_salt)    || ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
