# Conferência da chamada do PEC (ADR 0035; spec §7), nesta ordem:
# interruptor (e configuração), assinatura, horário, uso único (Signature),
# CNES de unidade ativa, profissional (CPF ou CNS) com vínculo ativo nessa
# unidade (a regra do 19a: health_professional, vínculo, CBO permitido) e a
# pessoa com ao menos um par validado (só por CPF: o CNS do par é cifrado
# não determinístico). O código da recusa é genérico — nunca qual parâmetro.
module PecExternal
  module Authorize
    DOCUMENT = /\A(\d{11}|\d{15})\z/
    CNES = /\A\d{7}\z/

    # inspect só com ids: nada de CPF, CNS ou nome dentro do grant.
    Grant = Data.define(:user, :unit, :person) do
      def inspect = "#<PecExternal::Authorize::Grant user_id=#{user.id} unit_id=#{unit.id} person=#{person.ref}>"
      alias_method :to_s, :inspect
    end

    module_function

    def call(city:, url:, params:, now: Time.current)
      result = evaluate(city, url, params, now)
      if result.failure?
        DomainEvents.publish("pec.external_view_denied", reason_code: result.reason.to_s)
      else
        grant = result.payload[:grant]
        DomainEvents.publish("pec.external_view_opened", user_id: grant.user.id, unit_id: grant.unit.id,
                                                          patient_id: grant.person.patient_id)
      end
      result
    end

    def linked?(user, unit)
      ApplicationRecord.transaction { Consultations::Authorization.link_for(user: user, health_unit_id: unit.id).first == :ok }
    end

    def evaluate(city, url, params, now)
      setting = PecSetting.current
      configured = setting&.pec_origin.present? && setting.hmac_key_configured?
      return Result.fail(:pec_disabled) unless configured && Timeline::Gate.pec_usable?(city)

      professional_doc, citizen_doc, cnes, timestamp =
        %w[documento-profissional documento-cidadao cnes pec_timestamp].map { |name| params[name].is_a?(String) ? params[name] : nil }
      return Result.fail(:pec_signature_invalid) unless professional_doc.to_s.match?(DOCUMENT) && cnes.to_s.match?(CNES)

      checked = Signature.verify(url: url, key: setting.hmac_key, timestamp: timestamp, now: now)
      return Result.fail(checked) unless checked == :ok

      unit = HealthUnit.find_by(cnes: cnes, active: true)
      return Result.fail(:pec_unit_unknown) unless unit

      user = professional_user(professional_doc)
      return Result.fail(:pec_professional_not_linked) unless user && linked?(user, unit)
      return Result.fail(:pec_citizen_missing) if citizen_doc.blank?

      person = citizen_doc.match?(/\A\d{11}\z/) ? Timeline::Person.for_cpf(citizen_doc) : nil
      return Result.fail(:pec_citizen_not_verified) if person.nil? || person.citizen_ids.empty?

      Result.ok(grant: Grant.new(user: user, unit: unit, person: person))
    end

    def professional_user(document)
      professional = document.length == 11 ? Professional.find_by(cpf: document) : Professional.find_by(cns: document)
      user = professional&.user
      user if user && user.deactivated_at.nil?
    end
    private_class_method :evaluate, :professional_user
  end
end
