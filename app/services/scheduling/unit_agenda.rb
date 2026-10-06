# Agenda da unidade no dia (contratos §4.5, §9, §10): por profissional, os
# turnos que cruzam o dia (cancelados também, com cancelled_at), as faixas do
# dia, o contador de encaixes e os horários; os livres (legacy) sem
# profissional em `unassigned`. `appointments` (forma antiga do módulo 08) fica
# até o dashboard novo entrar. Quem lê é a recepção: vê a justificativa do encaixe.
module Scheduling
  module UnitAgenda
    module_function

    def call(unit:, date:, catalog: AppointmentTypes.catalog, zone: Time.zone)
      window = date.in_time_zone.all_day
      shifts = Availability.unit_shifts(unit.id, window, include_cancelled: true).includes(:professional).to_a
      appointments = Appointment.where(health_unit: unit, scheduled_at: window)
                                .includes(:citizen, :request, :professional, shift: %i[professional_link schedule_template])
                                .order(:scheduled_at).to_a
      presenter = AppointmentPresenter.new(show_reason: true, catalog: catalog, zone: zone)
      professionals = (shifts.map(&:professional) + appointments.filter_map(&:professional))
                      .uniq.sort_by { |p| [ p.professional_name.to_s, p.id ] }
      {
        date: date.iso8601,
        professionals: professionals.map do |p|
          { id: p.id, name: p.professional_name,
            shifts: shifts.select { |s| s.professional_id == p.id }.map { |s| shift_json(s, date, catalog, zone) },
            appointments: appointments.select { |a| a.professional_id == p.id }.map { |a| presenter.call(a) } }
        end,
        unassigned: appointments.select { |a| a.professional_id.nil? }.map { |a| presenter.call(a) },
        appointments: appointments.map { |a| legacy_json(a) }
      }
    end

    def shift_json(shift, date, catalog, zone)
      ShiftJson.call(shift, day: date, catalog: catalog, zone: zone)
               .merge(fit_in_count: FitInLimit.count(shift), fit_in_limit: FitInLimit.for(shift))
    end

    # Forma antiga (módulo 08), lida pelo dashboard em produção.
    def legacy_json(a)
      { id: a.id, scheduled_at: a.scheduled_at.iso8601, cpf_masked: a.citizen.cpf_masked, kind: a.request.kind,
        status: a.status }
    end
  end
end
