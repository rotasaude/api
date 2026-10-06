# Liga, troca ou tira o modelo de agenda do turno (ADR 0029 §3.2). As vagas
# são calculadas: nada do que já foi marcado muda (o horário fora da grade nova
# aparece com outside_template na agenda). FOR SHARE no modelo: a desativação
# concorrente espera, ou é vista.
module Professionals
  module SetShiftTemplate
    module_function

    def call(shift:, schedule_template_id:, by:)
      ApplicationRecord.transaction(requires_new: true) do
        template = nil
        if schedule_template_id.present?
          template = active_template(schedule_template_id)
          next Result.fail(:invalid_template) unless template
        end

        shift.lock!
        next Result.fail(:already_cancelled) if shift.cancelled_at

        shift.update!(schedule_template: template)
        DomainEvents.publish("professional.shift_template_set", shift_id: shift.id, schedule_template_id: template&.id,
                                                                by_user_id: by.id)
        Result.ok(shift: shift)
      end
    end

    # Id que não é uuid vira nil no cast do Rails: não acha, é invalid_template.
    def active_template(id)
      ScheduleTemplate.lock("FOR SHARE").find_by(id: id.to_s, active: true)
    end
  end
end
