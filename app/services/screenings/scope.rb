# app/services/screenings/scope.rb
# A unidade escolhe para quem a escuta é obrigatória (ADR 0030; spec §3.1):
# walk_in (padrão) = só quem chegou sem horário marcado; all = todos.
module Screenings
  module Scope
    module_function

    def required?(attendance)
      attendance.health_unit.screening_scope == "all" || attendance.appointment_id.nil?
    end
  end
end
