# Cria ou atualiza uma versão DRAFT de protocolo a partir do editor (F-03.12).
# Rascunho é work-in-progress: NÃO exige o gate completo (só a validação mínima
# do before_save). Recusa editar uma versão já publicada/ativa/aposentada.
module Protocols
  module SaveDraft
    EDITABLE = "draft".freeze

    def self.call(definition:, by:)
      return Result.fail(:city_missing) if Current.city.nil?

      record = ProtocolDefinition.find_or_initialize_by(
        name: definition["name"],
        version: definition["version"]
      )
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, record).author?

      if record.persisted? && record.status != EDITABLE
        return Result.fail(:version_not_editable, message: "versão #{record.version} está #{record.status}")
      end

      record.status = EDITABLE
      record.definition = definition
      record.save!

      Result.ok(protocol_definition: record)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid_definition, message: e.record.errors.full_messages.join(", "))
    end
  end
end
