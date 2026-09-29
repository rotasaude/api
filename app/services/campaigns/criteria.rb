# app/services/campaigns/criteria.rb
# Critérios clínicos do público (ADR 0024 §4.1). Cada kind é uma classe com
# `.relation(params)` que devolve uma relação SQL de citizen_id — nunca
# carrega cidadão em Ruby. `params` já passou por Campaigns::AudienceSchema.
module Campaigns
  module Criteria
    KINDS = {
      "protocol_period" => "ProtocolPeriod",
      "triage_tier" => "TriageTier",
      "triage_incomplete" => "TriageIncomplete",
      "attendance_outcome" => "AttendanceOutcome",
      "triaged_not_attended" => "TriagedNotAttended",
      "appointment_no_show" => "AppointmentNoShow",
      "appointment_request_open" => "AppointmentRequestOpen"
    }.freeze

    def self.for(kind)
      const_get(KINDS.fetch(kind))
    end

    # Datas inclusivas no fuso da cidade (Time.zone).
    def self.period(params)
      Date.iso8601(params.fetch("from")).in_time_zone.beginning_of_day..
        Date.iso8601(params.fetch("to")).in_time_zone.end_of_day
    end

    # Triagem → cidadão: triages.conversation_id → conversations.citizen_id.
    # Conversa sem cidadão (WhatsApp antigo) fica de fora.
    def self.triage_citizens(triages)
      Conversation.where.not(citizen_id: nil).where(id: triages.select(:conversation_id)).select(:citizen_id)
    end
  end
end
