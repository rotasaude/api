# Agendamentos (módulos 08/17): data, tipo e situação; o horário movido sai
# (vale o novo). O detalhe é o do pedido (a tela existente lê o pedido). Motivo de cancelamento e de encaixe (texto livre) nunca entram.
module Timeline
  module Sources
    module AppointmentSource
      KIND = "appointment".freeze
      LEGACY_TITLE = "Consulta agendada".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        catalog = Scheduling::AppointmentTypes.catalog
        scope = ::Appointment.where(citizen_id: person.citizen_ids).where.not(status: "moved").includes(:health_unit, :professional)
        Window.apply(scope, kind: KIND, column: "appointments.scheduled_at", id_column: "appointments.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |appointment| entry(appointment, catalog) }
      end

      def entry(appointment, catalog)
        type = appointment.appointment_type_key && catalog.name_for(appointment.appointment_type_key)
        title = "Agendamento — #{type.presence || LEGACY_TITLE}"
        unit = appointment.health_unit
        name = appointment.professional&.professional_name
        Entry.new(kind: KIND, source_id: appointment.id, occurred_at: appointment.scheduled_at,
                  unit: { id: unit.id, name: unit.name }, professional: name && { name: name, cbo_code: nil },
                  title: title, summary: nil, status: appointment.status,
                  detail_ref: { type: "appointment_request", id: appointment.request_id },
                  citizen: { title: title, summary: nil, status: appointment.status, professional_name: name },
                  document: nil)
      end
    end
  end
end
