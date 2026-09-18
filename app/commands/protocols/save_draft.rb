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

      # Fast fail on the un-locked read (avoids opening a transaction for the
      # common case). ProtocolPolicy#author? asks only the actor's role, never
      # the record, so it needs no re-check under the lock below.
      if record.persisted? && !EDITABLE.include?(record.status)
        return Result.fail(:version_not_editable, message: "versão #{record.version} está #{record.status}")
      end

      failure = nil
      ApplicationRecord.transaction do
        # in_review is also where Publish leaves from: without a lock, a
        # concurrent Publish can commit "published" between the read above and
        # this write, and this command would silently send a published
        # version back to draft with unsigned content. Locking and
        # re-checking EDITABLE here is the only place that race is closed —
        # the contribution and the event below are built from this same
        # locked, saved record, never from the pre-lock read.
        if record.persisted?
          record.lock!
          unless EDITABLE.include?(record.status)
            failure = Result.fail(:version_not_editable, message: "versão #{record.version} está #{record.status}")
            raise ActiveRecord::Rollback
          end
        end

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

      return failure if failure

      Result.ok(protocol_definition: record)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid_definition, message: e.record.errors.full_messages.join(", "))
    # M9: the model's before_save (validate_definition_shape) throws :abort
    # when Protocols::Validator rejects the definition — a halted callback
    # chain makes save! raise RecordNotSaved, not RecordInvalid (the shape
    # errors never reach ActiveRecord's own validations). Without this rescue
    # a rejected definition 500s instead of failing as a user error.
    rescue ActiveRecord::RecordNotSaved => e
      Result.fail(:invalid_definition, message: e.record.errors.full_messages.join(", "))
    end
  end
end
