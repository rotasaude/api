# Lança um turno no vínculo (ADR 0021): até 24h, dentro do vínculo, sem
# sobrepor outro turno válido do mesmo profissional em qualquer unidade (a
# EXCLUDE do banco decide; aqui só se nomeia o conflito). FOR SHARE no
# vínculo: o encerramento (FOR UPDATE) espera, ou é visto. O modelo de agenda
# (ADR 0029 §3.2) é opcional e tem de estar ativo.
module Professionals
  class ScheduleShift
    def self.call(link:, starts_at:, ends_at:, by:, schedule_template_id: nil)
      starts = parse(starts_at)
      ends = parse(ends_at)
      return Result.fail(:invalid_shift) unless starts && ends && ends > starts && ends - starts <= ProfessionalShift::MAX_DURATION

      ApplicationRecord.transaction(requires_new: true) do
        locked = ProfessionalLink.lock("FOR SHARE").find(link.id)
        next Result.fail(:link_ended) unless locked.active?
        next Result.fail(:invalid_shift) if starts < locked.started_at

        template = nil
        if schedule_template_id.present?
          template = SetShiftTemplate.active_template(schedule_template_id)
          next Result.fail(:invalid_template) unless template
        end

        shift = ProfessionalShift.create!(professional_link: locked, professional_id: locked.professional_id,
                                          starts_at: starts, ends_at: ends, created_by_user: by,
                                          schedule_template: template)
        DomainEvents.publish("professional.shift_scheduled", shift_id: shift.id, professional_link_id: locked.id,
                                                             professional_id: locked.professional_id, by_user_id: by.id)
        Result.ok(shift: shift)
      end
    rescue ActiveRecord::ExclusionViolation
      Result.fail(:shift_overlap, details: { conflict: conflict_for(link.professional_id, starts, ends) })
    end

    def self.parse(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone) && !value.is_a?(String)

      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.conflict_for(professional_id, starts, ends)
      shift = ProfessionalShift.valid_shifts.includes(professional_link: :health_unit)
                               .where(professional_id: professional_id)
                               .where("starts_at < ? AND ends_at > ?", ends, starts).order(:starts_at).first
      return {} unless shift

      { unit_name: shift.professional_link.health_unit.name, starts_at: shift.starts_at.iso8601,
        ends_at: shift.ends_at.iso8601 }
    end
  end
end
