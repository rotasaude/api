# Auditoria platform-scope (ADR-0012, ADR-0014), na PLATAFORMA — só eventos sobre
# objetos de plataforma: cidades, canais, canais desconhecidos e operadores
# (operator.login). Eventos de usuário/membership/convite são DomainEvent da
# cidade (Ruling R18).
#
# INVARIANTE (PlatformRecord): nenhum dado pessoal. A validação abaixo recusa,
# em qualquer profundidade do payload, as chaves que a R18 fixou como sinal de
# dado pessoal — é a guarda de runtime; spec/events/platform_event_payload_guard_spec.rb
# é a guarda de regressão.
#
# Como casa (M2 do review 5b), sem diferenciar maiúsculas:
#   - FORBIDDEN_KEY_FRAGMENTS por SUBSTRING: user_email, admin_email,
#     phone_number, display_phone_number, citizen_cpf, full_name,
#     display_name, username... são recusadas, não só a chave exata.
#   - FORBIDDEN_EXACT_KEYS por nome EXATO: `from` é curto demais para
#     substring (casaria `from_state`, `from_city`...).
#   - ALLOWED_PAYLOAD_KEYS vence os dois. `phone_number_id` é o id do número
#     do canal WhatsApp na Meta (CityChannel/UnknownChannel), identificador de
#     CANAL de plataforma, não de pessoa — decisão registrada aqui porque
#     channel.token_rotated e channel.unknown_seen o auditam. `city_name` é o
#     nome da cidade, objeto de plataforma. Qualquer chave nova que case um
#     fragmento só entra por esta allow-list, com justificativa.
class PlatformEvent < PlatformRecord
  # `id` é UUID aleatório (Platform.audit grava `SecureRandom.uuid`), sem
  # relação nenhuma com a ordem de inserção — `.last`/`.first` sem isto ordenam
  # por um valor arbitrário, não por tempo. Um par tentativa/resultado (Plano 3)
  # é o primeiro caso na suíte com DOIS eventos do mesmo nome no mesmo exemplo,
  # e foi isto que expôs o problema: `.last` falhava de forma intermitente.
  self.implicit_order_column = "created_at"

  FORBIDDEN_KEY_FRAGMENTS = %w[email cpf phone wa_id provider_uid body name].freeze
  FORBIDDEN_EXACT_KEYS = %w[from].freeze
  FORBIDDEN_PAYLOAD_KEYS = (FORBIDDEN_KEY_FRAGMENTS + FORBIDDEN_EXACT_KEYS).freeze
  ALLOWED_PAYLOAD_KEYS = %w[phone_number_id city_name].freeze

  validates :name, :occurred_at, presence: true
  validate :payload_without_personal_data

  scope :pending, -> { where(published_at: nil) }

  def self.forbidden_payload_key?(key)
    key = key.to_s.downcase
    return false if ALLOWED_PAYLOAD_KEYS.include?(key)

    FORBIDDEN_EXACT_KEYS.include?(key) || FORBIDDEN_KEY_FRAGMENTS.any? { |fragment| key.include?(fragment) }
  end

  def self.forbidden_payload_keys_in(value)
    case value
    when Hash
      value.flat_map do |key, nested|
        hit = forbidden_payload_key?(key) ? [key.to_s] : []
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
