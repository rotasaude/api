# Item da fila de pedidos (contratos §4.1, §9, §10). `priority` é a do pedido
# (routine|priority); a prioridade numérica da triagem é `triage_priority`.
# A nota livre do cidadão só no detalhe. `reopened_reason` mostra só
# expired/no_show: a remarcação pedida aparece em `reschedule_requested`.
# `needs_reschedule` (spec §4.3, derivado): o horário vivo caiu num turno
# cancelado, saiu do modelo do turno depois da marcação, ou ficou depois do
# prazo (dia do horário no fuso da cidade > due_on — fusão de triagem que
# encurtou o prazo de um pedido já marcado; o horário não muda, a recepção
# decide). `overdue`: aberto com prazo vencido, ou precisa remarcar com prazo
# vencido; marcado sem precisar remarcar nunca (a marcação é a resposta).
# Quem chama carrega Scheduling::RequestJson::INCLUDES.
module Scheduling
  class RequestJson
    INCLUDES = [ :citizen, :origin_unit, :root_triage,
                 { appointments: [ :citizen, :professional, { shift: %i[professional_link schedule_template] } ] } ].freeze

    # Pares [pedido, item] em ordem: atrasados, depois prazo, prioridade do
    # pedido e criação.
    def self.sort(rows)
      rows.sort_by do |r, row|
        [ row[:overdue] ? 0 : 1, r.due_on, r.priority == "priority" ? 0 : 1, r.created_at ]
      end
    end

    def initialize(presenter:, catalog: AppointmentTypes.catalog, today: Time.zone.today)
      @catalog = catalog
      @presenter = presenter
      @today = today
    end

    def call(request, detail: false)
      live = request.appointments.select { |a| Appointment::LIVE.include?(a.status) }.max_by(&:created_at)
      appointment = live && @presenter.call(live)
      needs_reschedule = appointment.present? &&
                         (appointment[:shift_cancelled] || appointment[:outside_template] ||
                          live.scheduled_at.in_time_zone.to_date > request.due_on)
      overdue = request.due_on < @today && (request.status == "open" || needs_reschedule)
      json = {
        id: request.id, kind: request.kind, origin: request.origin, origin_unit_name: request.origin_unit&.name,
        target_unit_id: request.target_unit_id, created_at: request.created_at.iso8601,
        cpf_masked: request.citizen.cpf_masked, note: request.note,
        reopened_reason: request.reopened_reason == "citizen_reschedule" ? nil : request.reopened_reason,
        triage_priority: request.root_triage.priority, appointment_type_key: request.appointment_type_key,
        appointment_type_name: @catalog.name_for(request.appointment_type_key), priority: request.priority,
        due_on: request.due_on.iso8601, overdue: overdue,
        reschedule_requested: request.status == "open" && request.reopened_reason == "citizen_reschedule",
        reschedule_reason_code: request.reschedule_reason_code, preferred_period: request.preferred_period,
        reschedule_count: request.reschedule_count,
        needs_reschedule: needs_reschedule,
        appointment: appointment
      }
      json[:reschedule_note] = request.reschedule_note if detail
      json
    end
  end
end
