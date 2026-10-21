# Raça/cor, etnia e endereço do paciente para o BPA-I (ADR 0039; D-U1 do
# contrato §12). `parse` valida só as chaves presentes ("" ou nil apaga; o
# número vazio vira "SN", §13 E4); `check` confere etnia × raça na combinação
# final (chamado antes de validar o par, §13 E12, e de novo em `save!`, sob
# trava). Larguras do layout do BPA recusadas, nunca cortadas. Nada daqui vai
# a log, evento ou mensagem de erro (só o nome do campo).
module Patients
  module Demographics
    LIMITS = { "address_street" => 30, "address_number" => 5, "address_complement" => 10, "address_district" => 30 }.freeze
    # O que faz falta no BPA-I (Billing::Critic#demographic_reasons): o número vazio é SN.
    ADDRESS = %w[address_zip address_street address_district].freeze
    NO_NUMBER = "SN".freeze

    module_function

    def parse(params)
      values = {}
      Patient::DEMOGRAPHICS.each do |key|
        next unless params.key?(key)

        raw = params[key]
        return Result.fail(:invalid_demographics, details: { field: key }) unless raw.nil? || raw.is_a?(String)

        values[key] = raw.to_s.squish.presence
      end
      values["address_number"] ||= NO_NUMBER if values.key?("address_number")
      if values["race_color"] && !Patient::RACE_COLORS.include?(values["race_color"])
        return Result.fail(:invalid_race_color, details: { field: "race_color" })
      end
      return Result.fail(:invalid_ethnicity, details: { field: "ethnicity" }) if values["ethnicity"] && !values["ethnicity"].match?(/\A\d{4}\z/)

      if values["address_zip"]
        values["address_zip"] = values["address_zip"].gsub(/[\s.-]/, "")
        return Result.fail(:invalid_zip, details: { field: "address_zip" }) unless values["address_zip"].match?(/\A\d{8}\z/)
      end
      LIMITS.each do |key, limit|
        return Result.fail(:too_long, details: { field: key }) if values[key] && values[key].length > limit
      end
      Result.ok(values: values)
    end

    # A combinação final (o gravado mesclado com o novo): etnia só e sempre com indígena (05).
    def check(final)
      return Result.fail(:ethnicity_required, details: { field: "ethnicity" }) if final["race_color"] == "05" && final["ethnicity"].nil?
      return Result.fail(:invalid_ethnicity, details: { field: "ethnicity" }) if final["ethnicity"] && final["race_color"] != "05"

      Result.ok
    end

    # O chamador trava o paciente.
    def save!(patient, values)
      checked = check(current(patient).merge(values))
      return checked if checked.failure?

      patient.update!(values) if values.any?
      Result.ok(patient: patient)
    end

    def current(patient) = patient ? Patient::DEMOGRAPHICS.to_h { |key| [ key, patient.public_send(key) ] } : {}

    # O que a tela pode ver sem o dado.
    def flags(patient)
      return { race_color_set: false, address_set: false } unless patient

      { race_color_set: patient.race_color.present?, address_set: ADDRESS.all? { |key| patient.public_send(key).present? } }
    end
  end
end
