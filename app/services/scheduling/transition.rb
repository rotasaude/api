# Transição por unidade (ADR 0029): a marcação livre de hoje (legacy) vale só
# no dia em que a unidade não tem nenhum turno não cancelado cruzando o dia
# (fuso da cidade). Turno que termina exatamente à meia-noite não conta no dia
# seguinte.
module Scheduling
  module Transition
    module_function

    def shift_days(unit_id, from, to)
      window = from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day
      ProfessionalShift.joins(:professional_link)
                       .where(professional_links: { health_unit_id: unit_id }, cancelled_at: nil)
                       .where("professional_shifts.starts_at <= ? AND professional_shifts.ends_at > ?", window.end, window.begin)
                       .pluck(:starts_at, :ends_at)
                       .flat_map { |starts, ends| (starts.in_time_zone.to_date..(ends - 1.second).in_time_zone.to_date).to_a }
                       .to_set
    end

    def legacy_days(unit_id, from, to)
      with_shift = shift_days(unit_id, from, to)
      (from..to).reject { |day| with_shift.include?(day) }
    end

    def slots_day?(unit_id, date) = shift_days(unit_id, date, date).include?(date)
  end
end
