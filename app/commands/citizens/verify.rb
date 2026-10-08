# Valida o par no balcão (spec 2026-09-24 §2, §4). Confere e consome o código
# sob lock: dois atendentes com o mesmo código → só um valida.
# ADR 0027 (spec 2026-10-05 §5.4): o atendente confere no documento a data de
# nascimento e o sexo (e, se quiser, a identidade de gênero); o perfil do par
# validado passa a `verified` e só muda no posto. gender_identity ausente
# (UNCHANGED) mantém o declarado. Os valores são conferidos ANTES do código:
# um erro de digitação não gasta o código.
# ADR 0031: também o nome completo (com a chave, obrigatório), o social e o da mãe.
# ADR 0028: com cadsus_confirmed, efetiva o CNS da consulta ao CADSUS desta
# sessão (Reasons: :cadsus_lookup_missing); toda validação limpa o pendente.
module Citizens
  class Verify
    UNCHANGED = Object.new.freeze

    def self.call(cpf:, code:, document_checked:, by:, birth_date:, sex:, full_name: NameValues::ABSENT, social_name: nil,
                  mother_name: nil, gender_identity: UNCHANGED, cadsus_confirmed: false, session_id: nil)
      return Result.fail(:document_check_required) unless document_checked == true

      keep_identity = gender_identity.equal?(UNCHANGED)
      values = ProfileValues.call(birth_date: birth_date, sex: sex, gender_identity: keep_identity ? nil : gender_identity)
      return values if values.failure?

      # ADR 0031: o nome conferido no documento, também antes de gastar o
      # código. Sem a chave (cliente antigo), nada a gravar.
      names = NameValues.call(full_name: full_name, social_name: social_name, mother_name: mother_name)
      return names if names.failure?

      result = nil
      ApplicationRecord.transaction do
        match = VerificationCodeMatch.call(cpf: cpf, code: code, lock: true)
        next result = match if match.failure?

        citizen = match.payload[:citizen]
        if (active = citizen.active_verification)
          next result = Result.fail(:already_verified, details: { verified_at: active.verified_at })
        end

        # ADR 0028 (contratos §5.4): confirmar o CADSUS exige consulta desta
        # sessão há no máximo 10 min — antes de consumir o código.
        if cadsus_confirmed && !cadsus_pending?(citizen, session_id)
          next result = Result.fail(:cadsus_lookup_missing)
        end

        match.payload[:verification_code].update!(consumed_at: Time.current)
        verification = record!(citizen: citizen, by: by)
        apply_profile!(citizen, values.payload, keep_identity: keep_identity)
        citizen.update!(names.payload) if names.payload.any?
        # ADR 0031: par revalidado já ligado a paciente — nome e perfil seguem.
        Patients::Resolve.refresh!(Patient.lock.find(citizen.patient_id)) if citizen.patient_id
        settle_cadsus!(citizen, confirmed: cadsus_confirmed)
        result = Result.ok(verification: verification)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_verified)
    end

    # Cria a validação dentro de uma transação que o chamador já abriu (usado
    # também pelo check-in, spec 2026-09-24-citizen-attendance-check-in §2.6).
    # Não mexe no perfil: o check-in não confere documento.
    def self.record!(citizen:, by:)
      verification = CitizenVerification.create!(citizen: citizen, verified_by_user: by, verified_at: Time.current)
      citizen.update!(verification_level: "verified")
      DomainEvents.publish("citizen.verified", citizen_id: citizen.id, verification_id: verification.id,
                                               verified_by_user_id: by.id)
      verification
    end

    def self.cadsus_pending?(citizen, session_id)
      citizen.cadsus_pending_cns.present? && session_id.present? && citizen.cadsus_pending_session_id == session_id &&
        citizen.cadsus_pending_at.present? && citizen.cadsus_pending_at >= Cadsus::Lookup::WINDOW.ago
    end

    # Do CADSUS só ficam o CNS e a marca da conferência (ADR 0028). Toda
    # validação bem-sucedida limpa o pendente (minimização, LGPD): confirmada,
    # o CNS da consulta desta sessão vira o CNS do cidadão; sem confirmação, o
    # pendente (vencido, de outra sessão ou só não confirmado) é descartado.
    def self.settle_cadsus!(citizen, confirmed:)
      cleared = { cadsus_pending_cns: nil, cadsus_pending_session_id: nil, cadsus_pending_at: nil }
      if confirmed
        citizen.update!(cleared.merge(cns: citizen.cadsus_pending_cns, cadsus_checked_at: Time.current))
      elsif cleared.keys.any? { |k| !citizen.public_send(k).nil? }
        citizen.update!(cleared)
      end
    end

    def self.apply_profile!(citizen, values, keep_identity:)
      attributes = values.merge(profile_source: "verified")
      attributes.delete(:gender_identity) if keep_identity
      citizen.update!(attributes)
      DomainEvents.publish("citizen.profile_changed", citizen_id: citizen.id)
    end
  end
end
