# Abre a triagem do protocolo padrão numa conversa já consentida. Usado pelo
# WhatsApp (ConversationAdvance) e pela web (Citizens::StartConversation).
# Ver ADR-0009. Reasons: :no_protocol.
#
# Copia o bairro atual do cidadão na criação (ADR 0023): é a única escrita de
# triages.neighborhood_id — depois, o trigger triages_neighborhood_immutable
# recusa qualquer mudança. Conversa do WhatsApp sem cidadão: sem bairro.
class StartTriage
  DEFAULT_PROTOCOL_NAME = "triage-respiratoria"

  def self.call(conversation:)
    record = ProtocolDefinition.where(name: DEFAULT_PROTOCOL_NAME, status: "active").first
    return Result.fail(:no_protocol) unless record

    engine = Protocols.current(name: DEFAULT_PROTOCOL_NAME)
    triage = conversation.triages.create!(
      protocol_definition: record,
      protocol_name: record.name,
      answers: {},
      current_step: engine.start_step_id.to_s,
      status: :in_progress,
      neighborhood_id: conversation.citizen&.neighborhood_id
    )
    Result.ok(triage: triage)
  rescue Protocols::NotFound
    Result.fail(:no_protocol)
  end
end
