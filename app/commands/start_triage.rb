# Abre a triagem de um protocolo numa conversa já consentida. Usado pela web
# (Citizens::StartConversation, com o nome escolhido no catálogo) e pelo
# WhatsApp descontinuado (ConversationAdvance, com o nome padrão). Ver ADR-0009.
#
# ADR 0027 (spec 2026-10-05 §5.2): com cidadão, trava o par e confere a regra
# de oferta (Triages::Offer) antes de criar — a mesma triagem pedida duas vezes
# em paralelo não fura o intervalo de repetição; a sugestão pendente daquele
# protocolo vira `taken` na mesma transação. Sem cidadão (WhatsApp), como
# antes. Reasons: :no_protocol, :not_offered.
#
# Copia o bairro atual do cidadão na criação (ADR 0023): é a única escrita de
# triages.neighborhood_id — depois, o trigger triages_neighborhood_immutable
# recusa qualquer mudança. Conversa do WhatsApp sem cidadão: sem bairro.
class StartTriage
  DEFAULT_PROTOCOL_NAME = "triage-respiratoria"

  def self.call(conversation:, protocol_name: DEFAULT_PROTOCOL_NAME)
    name = protocol_name.to_s
    citizen = conversation.citizen
    ApplicationRecord.transaction do
      if citizen
        citizen.lock!
        return Result.fail(:not_offered) unless Triages::Offer.available?(citizen: citizen, protocol_name: name)
      end

      record = ProtocolDefinition.find_by(name: name, status: "active")
      return Result.fail(:no_protocol) unless record

      engine = Protocols.current(name: name)
      triage = conversation.triages.create!(
        protocol_definition: record,
        protocol_name: record.name,
        answers: {},
        current_step: engine.start_step_id.to_s,
        status: :in_progress,
        neighborhood_id: citizen&.neighborhood_id
      )
      take_suggestion!(citizen, triage) if citizen
      Result.ok(triage: triage)
    end
  rescue Protocols::NotFound
    Result.fail(:no_protocol)
  end

  # UPDATE guardado por status = pending: se uma leitura do catálogo em paralelo
  # já expirou a sugestão, o WHERE não casa (READ COMMITTED reavalia a linha) e
  # nada muda — em vez de o trigger recusar expired → taken com 500.
  def self.take_suggestion!(citizen, triage)
    TriageSuggestion.status_pending.where(citizen_id: citizen.id, protocol_name: triage.protocol_name)
                    .update_all(status: "taken", taken_triage_id: triage.id, resolved_at: Time.current)
  end
end
