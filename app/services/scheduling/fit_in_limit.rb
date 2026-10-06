# Limite de encaixes do turno (ADR 0029 §3.2, §4.3): o do modelo ligado (ativo
# ou não), senão o padrão da cidade, senão 2. Conta os encaixes ATIVOS.
module Scheduling
  module FitInLimit
    DEFAULT = 2

    module_function

    def for(shift)
      shift.schedule_template&.fit_in_limit || CityProfile.current&.default_fit_in_limit || DEFAULT
    end

    def count(shift, except_request_id: nil)
      scope = Appointment.where(shift_id: shift.id, booking_kind: "fit_in", status: Appointment::ACTIVE)
      scope = scope.where.not(request_id: except_request_id) if except_request_id
      scope.count
    end
  end
end
