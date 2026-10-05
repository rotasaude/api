# Valida o par no balcão (spec 2026-09-24 §2, §4). Confere e consome o código
# sob lock: dois atendentes com o mesmo código → só um valida.
# ADR 0027 (spec 2026-10-05 §5.4): o atendente confere no documento a data de
# nascimento e o sexo (e, se quiser, a identidade de gênero); o perfil do par
# validado passa a `verified` e só muda no posto. gender_identity ausente
# (UNCHANGED) mantém o declarado. Os valores são conferidos ANTES do código:
# um erro de digitação não gasta o código.
module Citizens
  class Verify
    UNCHANGED = Object.new.freeze

    def self.call(cpf:, code:, document_checked:, by:, birth_date:, sex:, gender_identity: UNCHANGED)
      return Result.fail(:document_check_required) unless document_checked == true

      keep_identity = gender_identity.equal?(UNCHANGED)
      values = ProfileValues.call(birth_date: birth_date, sex: sex, gender_identity: keep_identity ? nil : gender_identity)
      return values if values.failure?

      result = nil
      ApplicationRecord.transaction do
        match = VerificationCodeMatch.call(cpf: cpf, code: code, lock: true)
        next result = match if match.failure?

        citizen = match.payload[:citizen]
        if (active = citizen.active_verification)
          next result = Result.fail(:already_verified, details: { verified_at: active.verified_at })
        end

        match.payload[:verification_code].update!(consumed_at: Time.current)
        verification = record!(citizen: citizen, by: by)
        apply_profile!(citizen, values.payload, keep_identity: keep_identity)
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

    def self.apply_profile!(citizen, values, keep_identity:)
      attributes = values.merge(profile_source: "verified")
      attributes.delete(:gender_identity) if keep_identity
      citizen.update!(attributes)
      DomainEvents.publish("citizen.profile_changed", citizen_id: citizen.id)
    end
  end
end
