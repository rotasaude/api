# "Para quem é esta triagem?" com CPF novo: cria (ou acha) o par CPF + telefone.
# Reasons: :invalid_cpf, :too_many_people.
module Citizens
  class RegisterPerson
    def self.call(phone:, cpf:)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      existing = Citizen.find_by(cpf: digits, phone: phone)
      return Result.ok(citizen: existing) if existing
      return Result.fail(:too_many_people) if Citizen.where(phone: phone).count >= Citizen::MAX_PER_PHONE

      Result.ok(citizen: Citizen.create!(cpf: digits, phone: phone))
    rescue ActiveRecord::RecordNotUnique
      Result.ok(citizen: Citizen.find_by!(cpf: digits, phone: phone))
    end
  end
end
