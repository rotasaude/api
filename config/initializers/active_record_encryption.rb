# Chaves do AR Encryption. Ver ADR-0013 e lib/encryption_keys.rb (ordem de
# resolução e falha de boot em ambiente publicado).
# Em dev/test, gere com:
#   bin/rails db:encryption:init
# e copie a saída para credentials, ou exporte:
#   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,
#   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT (os AR_ENCRYPTION_* antigos ainda valem)
require_relative "../../lib/encryption_keys"

config = Rails.application.config.active_record.encryption
keys = EncryptionKeys.resolve(credentials: Rails.application.credentials, env: ENV, deployed: Rota.deployed?)

config.primary_key         = keys[:primary_key]
config.deterministic_key   = keys[:deterministic_key]
config.key_derivation_salt = keys[:key_derivation_salt]
