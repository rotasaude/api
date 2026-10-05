# "Para quem é esta triagem?" com CPF novo: cria (ou acha) o par CPF + telefone.
# ADR 0027: com `profile` (saída de Citizens::ProfileValues), o par NOVO nasce
# com o perfil declarado, num INSERT só; o par existente não muda (a correção
# é pela rota própria). `created` diz qual dos dois aconteceu.
# Reasons: :invalid_cpf, :too_many_people.
module Citizens
  class RegisterPerson
    def self.call(phone:, cpf:, profile: nil)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      existing = Citizen.find_by(cpf: digits, phone: phone)
      return Result.ok(citizen: existing, created: false) if existing
      return Result.fail(:too_many_people) if Citizen.where(phone: phone).count >= Citizen::MAX_PER_PHONE

      attributes = { cpf: digits, phone: phone }
      attributes.merge!(profile.slice(:birth_date, :sex, :gender_identity), profile_source: "declared") if profile
      citizen = Citizen.create!(attributes)
      DomainEvents.publish("citizen.profile_changed", citizen_id: citizen.id) if profile
      Result.ok(citizen: citizen, created: true)
    rescue ActiveRecord::RecordNotUnique
      Result.ok(citizen: Citizen.find_by!(cpf: digits, phone: phone), created: false)
    end
  end
end
