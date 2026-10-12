# Sessão curta da página do PEC (ADR 0035; Desvio 4, Divergência D3): token
# cifrado e assinado (MessageEncryptor, 15 min, propósito próprio) com a
# cidade, o usuário, a unidade e a pessoa. Vai no DOM da página e volta no
# cabeçalho X-Pec-View-Session do "carregar mais" — sem cookie de terceiro.
# A cada uso relê o usuário, a unidade, o vínculo, o interruptor e os pares.
module PecExternal
  module ViewSession
    HEADER = "X-Pec-View-Session".freeze
    TTL = 15.minutes
    PURPOSE = "pec_view_session".freeze

    module_function

    def issue(city:, grant:)
      encryptor.encrypt_and_sign({ "c" => city.id, "u" => grant.user.id, "h" => grant.unit.id,
                                   "p" => grant.person.patient_id, "i" => grant.person.citizen_ids },
                                 expires_in: TTL, purpose: PURPOSE)
    end

    def resume(token, city:)
      return nil unless token.is_a?(String) && token.present?

      payload = encryptor.decrypt_and_verify(token, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["c"] == city.id

      user = User.find_by(id: payload["u"], deactivated_at: nil)
      unit = HealthUnit.find_by(id: payload["h"], active: true)
      return nil unless user && unit && Timeline::Gate.pec_usable?(city) && Authorize.linked?(user, unit)

      # Os pares congelados no token são relidos: exclusão LGPD ou revogação da
      # validação depois da abertura tira o par; sem par e sem paciente, a
      # sessão acaba (pec_session_expired).
      ids = Timeline::Person.verified_pairs.where(id: Array(payload["i"])).order(:created_at, :id).pluck(:id)
      person = Timeline::Person.new(citizen_ids: ids, patient_id: payload["p"], verified: true)
      return nil if person.empty?

      Authorize::Grant.new(user: user, unit: unit, person: person)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def encryptor
      key = Rails.application.key_generator.generate_key("pec-view-session", ActiveSupport::MessageEncryptor.key_len)
      ActiveSupport::MessageEncryptor.new(key)
    end
    private_class_method :encryptor
  end
end
