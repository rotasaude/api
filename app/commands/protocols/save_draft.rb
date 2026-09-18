# Cria ou atualiza uma versão de protocolo a partir do editor (F-03.12), por
# autor ou mantenedor. Rascunho é work-in-progress: NÃO exige o gate completo
# (só a validação mínima do before_save). Recusa editar uma versão já
# publicada/ativa/aposentada. Registra quem editou em ProtocolContribution
# (spec de assinaturas §4): quem tem uma linha ali nunca assina esta versão.
module Protocols
  module SaveDraft
    # in_review é editável (spec §4): editar em revisão devolve a versão a
    # draft, e as assinaturas do conteúdo antigo deixam de contar pelo digest.
    EDITABLE = %w[draft in_review].freeze

    def self.call(definition:, by:, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?

      record = ProtocolDefinition.find_or_initialize_by(name: definition["name"], version: definition["version"])
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, record).author?

      if record.persisted? && !EDITABLE.include?(record.status)
        return Result.fail(:version_not_editable, message: "versão #{record.version} está #{record.status}")
      end

      ApplicationRecord.transaction do
        record.status = "draft"
        record.definition = definition
        record.save!

        # Quem editou nunca assina esta versão (spec S4) — inclusive o mantenedor,
        # que de todo modo não assina.
        ProtocolContribution.create!(protocol_definition: record, actor_id: by.id, actor_kind: by.actor_kind,
                                     content_digest: record.content_digest)

        DomainEvents.publish("protocol.draft_saved", **{
          protocol_definition_id: record.id, protocol_key: record.name, version: record.version,
          content_digest: record.content_digest, actor: by.id, actor_kind: by.actor_kind,
          correlation_id: correlation_id
        }.compact)
      end

      Result.ok(protocol_definition: record)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid_definition, message: e.record.errors.full_messages.join(", "))
    end
  end
end
