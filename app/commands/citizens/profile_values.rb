# Confere e normaliza o perfil do par (contratos §2). Usado pelo cidadão
# (SetProfile, POST /citizen/people) e pelo balcão (Verify). Puro: `today`
# vem de quem chama (o fuso da cidade). Reasons: :invalid_birth_date,
# :invalid_sex, :invalid_gender_identity.
module Citizens
  module ProfileValues
    MAX_AGE = 130

    module_function

    def call(birth_date:, sex:, gender_identity:, today: Time.zone.today)
      date = parse(birth_date)
      if date.nil? || date > today || Citizen.age_between(date, today) > MAX_AGE
        return Result.fail(:invalid_birth_date)
      end
      return Result.fail(:invalid_sex) unless Citizen::SEXES.include?(sex)

      identity = gender_identity == "" ? nil : gender_identity
      unless identity.nil? || Citizen::GENDER_IDENTITIES.include?(identity)
        return Result.fail(:invalid_gender_identity)
      end

      Result.ok(birth_date: date.iso8601, sex: sex, gender_identity: identity)
    end

    def parse(raw)
      return nil unless raw.is_a?(String) && raw.match?(Citizen::BIRTH_DATE_FORMAT)

      Date.iso8601(raw)
    rescue Date::Error
      nil
    end
  end
end
