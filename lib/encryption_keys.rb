# Resolução das chaves do AR Encryption (ADR-0013, F-06.12). Ordem, chave a
# chave: credentials → ACTIVE_RECORD_ENCRYPTION_* (o que deploy/<env>/secrets
# injeta) → AR_ENCRYPTION_* (nome legado de dev). Ambiente publicado sem alguma
# das três não sobe: cifrar com chave nil, ou com a de outro ambiente, é pior
# que não subir.
#
# Fica em lib/ e é `require`ado pelo initializer (mesmo motivo de lib/rota.rb):
# roda antes do Zeitwerk.
#
# Ambiente publicado só lê as credentials DELE (Rota::ISOLATED_CREDENTIALS_ENVS):
# as chaves do arquivo compartilhado de dev nunca vencem as do cofre.
module EncryptionKeys
  class Missing < StandardError; end

  KEYS = {
    primary_key:         %w[ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY AR_ENCRYPTION_PRIMARY_KEY],
    deterministic_key:   %w[ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY AR_ENCRYPTION_DETERMINISTIC_KEY],
    key_derivation_salt: %w[ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT AR_ENCRYPTION_KEY_DERIVATION_SALT]
  }.freeze

  module_function

  def resolve(credentials:, env:, deployed:)
    keys = KEYS.to_h do |name, env_names|
      candidates = [ credentials.dig(:active_record_encryption, name), *env_names.map { |n| env[n] } ]
      [ name, candidates.find { |value| value.present? } ]
    end

    missing = keys.select { |_, value| value.nil? }.keys
    if deployed && missing.any?
      raise Missing, "AR Encryption sem chave em ambiente publicado: defina " \
                     "#{missing.map { |name| KEYS[name].first }.join(', ')} (deploy/<env>/secrets) ou as credentials"
    end

    keys
  end
end
