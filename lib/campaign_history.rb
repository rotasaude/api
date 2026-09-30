# lib/campaign_history.rb
require "digest"

# Histórico clínico no passado, gravado direto no banco (módulo 12; desvio 16
# do plano): os critérios de campanha olham para trás, mas os comandos do
# domínio só aceitam "agora" (desfecho) ou o futuro (horário). Usado pelas
# specs e pela semente de dev. INSERT direto, e o attendance! faz UPDATE pelas
# transições reais: os CHECKs e triggers de cada tabela continuam valendo, e é
# o que garante que a linha é coerente.
module CampaignHistory
  CONVERSATION_STATE = {
    "completed" => "completed", "aborted_by_timeout" => "abandoned",
    "aborted_by_cancellation" => "cancelled", "aborted_by_revocation" => "revoked"
  }.freeze

  module_function

  # CPF com dígitos verificadores válidos, determinístico pela semente.
  def cpf_for(seed)
    base = Digest::SHA256.hexdigest(seed.to_s).scan(/\d/).join[0, 9].ljust(9, "7")
    nums = base.chars.map(&:to_i)
    first = CitizenIdentity::Cpf.check_digit(nums)
    second = CitizenIdentity::Cpf.check_digit(nums + [ first ])
    "#{base}#{first}#{second}"
  end

  def citizen!(cpf:, phone:, neighborhood: nil)
    Citizen.find_or_create_by!(cpf: cpf, phone: phone) { |c| c.neighborhood = neighborhood }
  end

  def protocol
    ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active") ||
      ProtocolDefinition.order(:created_at).first ||
      raise("CampaignHistory: nenhum protocolo na cidade")
  end

  # `at` é o instante que o critério lê: a conclusão da triagem concluída, a
  # criação da abandonada. Conversa web própria e encerrada; o bairro atual do
  # cidadão é copiado, como faz o StartTriage.
  def triage!(citizen, status: "completed", protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME, tier: "alta",
              at: 2.days.ago)
    completed = status == "completed"
    created_at = completed ? at - 5.minutes : at
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone,
                                        state: CONVERSATION_STATE.fetch(status), created_at: created_at)
    Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol_name,
                   status: status, tier: completed ? tier : nil, priority: completed ? 1 : nil, answers: {},
                   created_at: created_at, completed_at: completed ? at : nil,
                   neighborhood_id: citizen.neighborhood_id)
  end

  # Atendimento encerrado em `at`, a partir de uma triagem (a dada ou uma nova,
  # uma hora antes). "left" é saída antes da chamada: sem chamada. Nasce
  # waiting e percorre as transições (o banco recusa nascer chamado ou
  # encerrado: trigger attendances_born_waiting).
  def attendance!(citizen, outcome:, at:, unit:, by:, triage: nil)
    triage ||= triage!(citizen, at: at - 1.hour)
    attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: by,
                                    checked_in_at: at - 50.minutes, check_in_method: "code")
    attendance.update!(status: "in_care", called_by_user: by, called_at: at - 30.minutes) unless outcome == "left"
    attendance.update!(status: "closed", outcome: outcome, closed_by_user: by, closed_at: at,
                       referral_note: outcome == "referred" ? "Encaminhado para avaliação especializada" : nil)
    attendance
  end

  # Pedido de agendamento nascido de um desfecho: return (mesma unidade) ou
  # referral (encaminhamento para `target`).
  def request!(citizen, kind: "return", unit:, target: unit, by:, at: 3.days.ago, status: "open", reopened_reason: nil)
    origin = attendance!(citizen, outcome: kind == "return" ? "return" : "referred", at: at, unit: unit, by: by)
    AppointmentRequest.create!(origin_attendance: origin, citizen: citizen, root_triage: origin.triage,
                               origin_unit: unit, target_unit: kind == "return" ? unit : target, kind: kind,
                               status: status, reopened_reason: reopened_reason)
  end

  # Falta em horário confirmado (MarkNoShowAppointmentsJob): o horário fica
  # no_show e o pedido volta à fila (open, reopened_reason no_show).
  def no_show!(citizen, at:, unit:, by:)
    request = request!(citizen, unit: unit, by: by, at: at - 7.days, reopened_reason: "no_show")
    Appointment.create!(request: request, citizen: citizen, health_unit: unit, scheduled_by_user: by,
                        scheduled_at: at, status: "no_show", confirmed_at: at - 1.day,
                        confirmation_deadline_at: at - 1.day, ended_at: at.end_of_day)
  end
end
