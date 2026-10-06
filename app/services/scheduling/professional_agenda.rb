# Minha agenda (ADR 0029 §7; contratos §3, §9): só leitura, os turnos do
# profissional em cada dia do intervalo (cancelados também), com unidade,
# faixas do dia e os horários daquele turno no dia. Sem justificativa de encaixe.
module Scheduling
  module ProfessionalAgenda
    module_function

    def call(professional:, from:, to:, catalog: AppointmentTypes.catalog, zone: Time.zone)
      window = from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day
      shifts = ProfessionalShift.where(professional: professional)
                                .where("starts_at <= ? AND ends_at > ?", window.end, window.begin)
                                .includes(:schedule_template, professional_link: :health_unit).order(:starts_at).to_a
      appointments = Appointment.where(shift_id: shifts.map(&:id))
                                .includes(:citizen, :professional, shift: %i[professional_link schedule_template])
                                .order(:scheduled_at).to_a
      presenter = AppointmentPresenter.new(show_reason: false, catalog: catalog, zone: zone)
      { days: (from..to).map { |day| day_json(day, shifts, appointments, presenter, catalog, zone) } }
    end

    def day_json(day, shifts, appointments, presenter, catalog, zone)
      day_window = day.in_time_zone.all_day
      today = shifts.select { |s| s.starts_at <= day_window.end && s.ends_at > day_window.begin }
      { date: day.iso8601, shifts: today.map do |shift|
        unit = shift.professional_link.health_unit
        ShiftJson.call(shift, day: day, catalog: catalog, zone: zone).merge(
          unit: { id: unit.id, name: unit.name },
          appointments: appointments.select { |a| a.shift_id == shift.id && day_window.cover?(a.scheduled_at) }
                                    .map { |a| presenter.call(a) }
        )
      end }
    end
  end
end
