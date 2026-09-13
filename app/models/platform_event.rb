# Auditoria platform-scope (ADR-0012, ADR-0014), na PLATAFORMA — só eventos sobre
# objetos de plataforma: cidades, canais, canais desconhecidos e, no Plano 3,
# operadores. Eventos de usuário/membership/convite são DomainEvent da cidade
# (Ruling R18).
#
# INVARIANTE (PlatformRecord): nenhum dado pessoal. A validação abaixo recusa,
# em qualquer profundidade do payload, as chaves que a R18 fixou como sinal de
# dado pessoal — é a guarda de runtime; spec/events/platform_event_payload_guard_spec.rb
# é a guarda de regressão.
class PlatformEvent < PlatformRecord
  FORBIDDEN_PAYLOAD_KEYS = %w[email cpf provider_uid phone from wa_id name body].freeze

  validates :name, :occurred_at, presence: true
  validate :payload_without_personal_data

  scope :pending, -> { where(published_at: nil) }

  def self.forbidden_payload_keys_in(value)
    case value
    when Hash
      value.flat_map do |key, nested|
        hit = FORBIDDEN_PAYLOAD_KEYS.include?(key.to_s.downcase) ? [key.to_s] : []
        hit + forbidden_payload_keys_in(nested)
      end
    when Array
      value.flat_map { |nested| forbidden_payload_keys_in(nested) }
    else
      []
    end
  end

  def mark_published!
    update_column(:published_at, Time.current)
  end

  private

  def payload_without_personal_data
    found = self.class.forbidden_payload_keys_in(payload)
    errors.add(:payload, "carrega chave de dado pessoal: #{found.uniq.join(', ')}") if found.any?
  end
end
