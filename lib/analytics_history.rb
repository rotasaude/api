# lib/analytics_history.rb
require_relative "campaign_history"

# Histórico no passado para o Analytics (módulo 14): specs e semente de dev.
# Mesma razão do CampaignHistory: os comandos do domínio só aceitam "agora", e
# o Analytics olha seis meses para trás. INSERT direto e UPDATE pelas
# transições reais — os CHECKs e triggers de cada tabela continuam valendo
# (attendances nasce waiting; horário e pedido não mudam depois de encerrados).
# Dá controle fino do que o Analytics lê: início, protocolo, respostas,
# espera, desfecho, fim do horário.
module AnalyticsHistory
  CONVERSATION_STATE = CampaignHistory::CONVERSATION_STATE.merge("in_progress" => "consented").freeze
  DISMISS_REASON = "Contato sem resposta após três tentativas".freeze
  CANCEL_REASON = "Não consigo ir neste horário".freeze

  module_function

  def citizen!(cpf:, phone:, neighborhood: nil)
    CampaignHistory.citizen!(cpf: cpf, phone: phone, neighborhood: neighborhood)
  end

  # Triagem web com conversa e consentimento próprios. `created_at` é o
  # início; a concluída termina 6 min depois. `revoked: true` revoga o
  # consentimento depois de concluir (caminho real do wpda: a triagem segue
  # completed). aborted_by_revocation nasce como o AnonymizeRevokedTriageJob a
  # deixa: sem respostas e sem bairro.
  def triage!(citizen:, protocol:, created_at:, status: "completed", tier: "alta", priority: 1, answers: {},
              revoked: false)
    completed = status == "completed"
    revocation = status == "aborted_by_revocation"
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone,
                                        state: CONVERSATION_STATE.fetch(status), created_at: created_at)
    consent = Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha-analytics-dev",
                              channel: "web", given_at: created_at)
    completed_at = if completed then created_at + 6.minutes
                   elsif revocation then created_at + 10.minutes
                   end
    triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                            status: status, tier: completed ? tier : nil, priority: completed ? priority : nil,
                            answers: revocation ? {} : answers, created_at: created_at, completed_at: completed_at,
                            neighborhood_id: revocation ? nil : citizen.neighborhood_id)
    if revocation || revoked
      consent.revoke!(at: (completed_at || created_at) + 1.hour)
      conversation.update!(state: "revoked") unless conversation.state_revoked?
    end
    triage
  end

  # Atendimento: nasce waiting (trigger attendances_born_waiting) e percorre
  # as transições. `wait_minutes` é a espera entre check-in e chamada; "left"
  # sai sem chamada, `wait_minutes` depois do check-in; os demais desfechos
  # fecham 15 min depois da chamada.
  def attendance!(citizen:, unit:, by:, checked_in_at:, triage: nil, appointment: nil, wait_minutes: 20,
                  outcome: "discharged", check_in_method: "code", referral_unit: nil, stage: :closed)
    attendance = Attendance.create!(
      triage: triage, appointment: appointment, citizen: citizen, health_unit: unit, checked_in_by_user: by,
      checked_in_at: checked_in_at, check_in_method: check_in_method,
      exception_reason: check_in_method == "cpf_exception" ? "Documento conferido no balcão" : nil
    )
    return attendance if stage == :waiting

    called_at = checked_in_at + wait_minutes.minutes
    left = outcome == "left" && stage == :closed
    attendance.update!(status: "in_care", called_by_user: by, called_at: called_at) unless left
    return attendance if stage == :in_care

    attendance.update!(status: "closed", outcome: outcome, closed_by_user: by,
                       closed_at: left ? called_at : called_at + 15.minutes,
                       referral_unit: outcome == "referred" ? (referral_unit || unit) : nil)
    attendance
  end

  # Pedido nascido do desfecho: return volta à mesma unidade; referral vai
  # para `target`. Gravado já no estado final (o trigger só guarda UPDATE).
  def request!(origin:, kind:, by:, target: origin.health_unit, created_at: origin.closed_at, status: "open",
               closed_reason: nil, closed_at: nil, reopened_reason: nil)
    dismissed = closed_reason == "dismissed"
    AppointmentRequest.create!(
      origin_attendance: origin, citizen: origin.citizen, root_triage: origin.triage, origin_unit: origin.health_unit,
      target_unit: kind == "return" ? origin.health_unit : target, kind: kind, status: status,
      closed_reason: closed_reason, closed_at: closed_at, reopened_reason: reopened_reason,
      closed_by_user: dismissed ? by : nil, dismiss_reason: dismissed ? DISMISS_REASON : nil, created_at: created_at
    )
  end

  # Quando o horário termina, por estado: comparecimento 10 min depois do
  # horário; falta no fim do dia (MarkNoShowAppointmentsJob); expiração no
  # prazo de confirmação (véspera); cancelamento dois dias antes.
  def ended_at(status, scheduled_at)
    case status
    when "checked_in" then scheduled_at + 10.minutes
    when "no_show" then scheduled_at.end_of_day.floor(6) # o banco guarda microssegundos
    when "expired" then scheduled_at - 1.day
    when "cancelled_by_citizen" then scheduled_at - 2.days
    else raise ArgumentError, "horário #{status} não termina"
    end
  end

  def appointment!(request:, status:, scheduled_at:, by:)
    Appointment.create!(
      request: request, citizen: request.citizen, health_unit: request.target_unit, scheduled_by_user: by,
      scheduled_at: scheduled_at, status: status, confirmation_deadline_at: scheduled_at - 1.day,
      confirmed_at: %w[checked_in no_show].include?(status) ? scheduled_at - 2.days : nil,
      cancel_reason: status == "cancelled_by_citizen" ? CANCEL_REASON : nil,
      ended_at: ended_at(status, scheduled_at), created_at: scheduled_at - 7.days
    )
  end
end
