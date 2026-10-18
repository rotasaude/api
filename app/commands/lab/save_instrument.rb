# Aparelho do laboratório (contrato §2; F-21.25): nome único no laboratório;
# identificador HL7 (OBX-18) único no laboratório sem diferenciar caixa.
# Nunca apagado (desativar). Trava do prestador contra duplicado concorrente.
module Lab
  module SaveInstrument
    LIMITS = { "manufacturer" => 80, "model" => 80, "serial_number" => 60 }.freeze
    HL7_ID = /\A[A-Za-z0-9._-]{1,50}\z/

    module_function

    def call(params, instrument: nil)
      params = params.to_h.stringify_keys
      provider = instrument&.exam_provider || provider_for(params["provider_id"])
      return Result.fail(:invalid_provider) unless provider

      name = params["name"].is_a?(String) ? params["name"].strip : ""
      return Result.fail(:invalid_name) unless name.length.between?(1, 80)
      return Result.fail(:invalid_sector) unless LabExam::SECTORS.include?(params["sector"])
      return Result.fail(:invalid_instrument) unless (LIMITS.keys + [ "hl7_equipment_id" ]).all? { |k| params[k].nil? || params[k].is_a?(String) }

      extras = LIMITS.to_h { |key, _| [ key.to_sym, params[key]&.strip.presence ] }
      return Result.fail(:invalid_instrument) if LIMITS.any? { |key, max| extras[key.to_sym].to_s.length > max }

      hl7 = params["hl7_equipment_id"]&.strip.presence
      return Result.fail(:invalid_instrument) unless hl7.nil? || hl7.match?(HL7_ID)
      return Result.fail(:invalid_active) unless [ true, false ].include?(params["active"])

      ApplicationRecord.transaction(requires_new: true) do
        provider.lock!
        others = LabInstrument.where(exam_provider_id: provider.id).where.not(id: instrument&.id)
        next Result.fail(:duplicate_hl7_equipment_id) if hl7 && others.where("upper(hl7_equipment_id) = ?", hl7.upcase).exists?
        next Result.fail(:duplicate_name) if others.where("lower(name) = ?", name.downcase).exists?

        record = instrument || LabInstrument.new(exam_provider: provider)
        record.update!(name: name, sector: params["sector"], hl7_equipment_id: hl7, active: params["active"], **extras)
        Result.ok(instrument: record)
      end
    end

    def provider_for(id)
      id.is_a?(String) && id.match?(Exams::BaseController::UUID) ? Access.labs.find_by(id: id) : nil
    end
    private_class_method :provider_for
  end
end
