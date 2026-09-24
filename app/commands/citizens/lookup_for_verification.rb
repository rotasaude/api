# O cartão do balcão (spec 2026-09-24 §4, §5): o par que o código identifica e
# as triagens do CPF (todos os pares) só com data e protocolo.
module Citizens
  class LookupForVerification
    def self.call(cpf:, code:)
      match = VerificationCodeMatch.call(cpf: cpf, code: code)
      return match if match.failure?

      citizen = match.payload[:citizen]
      if (active = citizen.active_verification)
        return Result.fail(:already_verified, details: { verified_at: active.verified_at })
      end

      Result.ok(citizen: citizen, triages: triages_of_cpf(citizen.cpf))
    end

    def self.triages_of_cpf(cpf)
      Triage.joins(:conversation)
            .where(conversations: { channel: "web", citizen_id: Citizen.where(cpf: cpf).select(:id) })
            .order(created_at: :desc)
            .map { |t| { date: t.completed_at || t.created_at, protocol_name: t.protocol_name } }
    end
  end
end
