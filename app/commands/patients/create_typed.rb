# Paciente digitado no cadastro territorial (ADR 0042; spec do 24a, decisões
# 1 e 13): sem par validado, com CPF ou com a justificativa da ficha (um dos
# dois, nunca ambos), CNS opcional e único. Com CPF, delega ao AddCpf na
# mesma transação (travas, cpf_taken, pares validados ligados). Recusas só
# com o caminho do campo — nunca o valor (nome, nascimento, CPF, CNS e
# justificativa não vão a log, evento nem erro).
module Patients
  module CreateTyped
    CNS_INDEX = "idx_patients_cns".freeze
    SOCIAL_NAME_MAX = 70
    STRINGS = %w[full_name social_name birth_date sex mother_name cpf no_cpf_reason cns].freeze

    module_function

    def call(attrs:, by:)
      parsed = parse(attrs.to_h.stringify_keys)
      return parsed if parsed.failure?

      values = parsed.payload[:values]
      cpf = parsed.payload[:cpf]
      return Result.fail(:cns_taken) if values["cns"] && Patient.exists?(cns: values["cns"])

      # Savepoint próprio: dentro da transação de quem chama (SaveRegistration),
      # a violação do idx_patients_cns desfaz só este trecho e o rescue
      # devolve cns_taken — sem savepoint, a transação de fora ficaria abortada.
      ApplicationRecord.transaction(requires_new: true) do
        patient = Patient.new(values)
        if cpf
          added = AddCpf.call(patient: patient, cpf: cpf, by: by)
          next added if added.failure?
        else
          patient.save!
        end
        DomainEvents.publish("patient.created", patient_id: patient.id, user_id: by.id)
        Result.ok(patient: patient)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(CNS_INDEX)

      Result.fail(:cns_taken)
    end

    def parse(attrs)
      STRINGS.each do |key|
        return invalid(key) unless attrs[key].nil? || attrs[key].is_a?(String)
      end
      raw = STRINGS.to_h { |key| [ key, attrs[key].to_s.squish.presence ] }

      # Regra "Validar nome" do LEDI (contrato §15.3), a mesma das fichas.
      return invalid("full_name") unless TerritoryRegistry::Dictionary.valid_name?(raw["full_name"])
      return invalid("social_name") if raw["social_name"] && raw["social_name"].length > SOCIAL_NAME_MAX

      birth_date = MatchKey.iso_date(raw["birth_date"])
      return invalid("birth_date") if birth_date.nil? || Date.iso8601(birth_date) > Time.zone.today
      return invalid("sex") unless Citizen::SEXES.include?(raw["sex"])
      return invalid("mother_name") if raw["mother_name"] && !TerritoryRegistry::Dictionary.valid_name?(raw["mother_name"])

      return Result.fail(:cpf_or_reason_required) if raw["cpf"].nil? && raw["no_cpf_reason"].nil?
      return invalid("no_cpf_reason") if raw["cpf"] && raw["no_cpf_reason"]
      if raw["no_cpf_reason"] && !TerritoryRegistry::Catalog::NO_CPF_REASONS.include?(raw["no_cpf_reason"])
        return invalid("no_cpf_reason")
      end
      return Result.fail(:invalid_cpf) if raw["cpf"] && CitizenIdentity::Cpf.normalize(raw["cpf"]).nil?

      cns = raw["cns"]&.delete(" ")
      return Result.fail(:invalid_cns) if cns && !Professionals::Cns.valid?(cns)

      values = { "full_name" => raw["full_name"], "social_name" => raw["social_name"], "birth_date" => birth_date,
                  "sex" => raw["sex"], "mother_name" => raw["mother_name"], "no_cpf_reason" => raw["no_cpf_reason"],
                  "cns" => cns }
      Result.ok(values: values, cpf: raw["cpf"])
    end

    def invalid(field) = Result.fail(:invalid_patient, details: { path: "new_patient.#{field}" })
    private_class_method :parse, :invalid
  end
end
