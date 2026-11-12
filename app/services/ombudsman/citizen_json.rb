# Formas JSON do canal do cidadão (ADR 0051; contrato §3; §16 Q2, Q4, Q40,
# Q42; preflight F-17). Separadas de Ombudsman::Json (a da equipe) de
# propósito: o cidadão nunca vê o encaminhamento, o extrato, o assunto, quem
# respondeu nem o nome do arquivo (os anexos são "Anexo N": só o id).
# `forwarded` aparece como `in_analysis` (Q40). As flags `can_*` saem dos dados
# (F-17): complementar em `awaiting_complement`; pedir reabertura em estado
# final, até 30 dias da conclusão e sem pedido no ciclo; responder a pesquisa
# em `answered`, com cidadão, até 30 dias e uma vez.
module Ombudsman
  module CitizenJson
    module_function

    def state(manifestation) = manifestation.state == "forwarded" ? "in_analysis" : manifestation.state

    # Item de "Minhas manifestações". `cpf_masked` só quando a sessão tem mais
    # de um cidadão (nil senão, como na caixa de avisos).
    def list_item(manifestation, settings:, today:, cpf_masked:, has_unread:)
      summary(manifestation, settings, today).merge(cpf_masked: cpf_masked, has_unread: has_unread)
    end

    def detail(manifestation, settings:, today:)
      unit = manifestation.referred_health_unit
      summary(manifestation, settings, today).merge(
        body: manifestation.body, health_unit: unit && { id: unit.id, name: unit.name },
        attachments: manifestation.attachments.map { |attachment| { id: attachment.id } },
        timeline: Timeline.citizen(manifestation.events),
        can_complement: manifestation.state == "awaiting_complement",
        can_request_reopen: can_request_reopen?(manifestation, today),
        can_answer_satisfaction: can_answer_satisfaction?(manifestation, today)
      )
    end

    def summary(manifestation, settings, today)
      {
        id: manifestation.id, protocol: manifestation.protocol, kind: manifestation.kind,
        identification_mode: manifestation.identification_mode, state: state(manifestation),
        received_at: manifestation.received_at.iso8601,
        due_on: Deadlines.due_on(manifestation, settings, today: today).iso8601,
        color: Deadlines.color(manifestation, settings, today: today)
      }
    end

    def can_request_reopen?(manifestation, today)
      manifestation.final? &&
        Deadlines.within_window?(manifestation.concluded_at, Catalog::REOPEN_WINDOW_DAYS, today: today) &&
        manifestation.reopen_requests.none? { |request| request.cycle == manifestation.cycle }
    end

    def can_answer_satisfaction?(manifestation, today)
      manifestation.state == "answered" && manifestation.citizen_id.present? &&
        Deadlines.within_window?(manifestation.concluded_at, Catalog::SATISFACTION_WINDOW_DAYS, today: today) &&
        manifestation.satisfaction_response.nil?
    end

    private_class_method :summary
  end
end
