# Limite de encaixes do turno (ADR 0029 §3.2, §4.3): o do modelo ligado (ativo
# ou não), senão o padrão da cidade, senão 2. Conta os encaixes ATIVOS, menos
# os ids dados (o horário vivo que a remarcação vai mover); um encaixe já com
# check-in segue contando.
module Scheduling
  module FitInLimit
    DEFAULT = 2

    module_function

    def for(shift)
      shift.schedule_template&.fit_in_limit || CityProfile.current&.default_fit_in_limit || DEFAULT
    end

    def count(shift, except_ids: [])
      Appointment.where(shift_id: shift.id, booking_kind: "fit_in", status: Appointment::ACTIVE)
                 .where.not(id: except_ids).count
    end
  end
end
