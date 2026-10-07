# app/services/screenings/scope.rb
# A unidade escolhe para quem a escuta é obrigatória (ADR 0030; spec §3.1):
# walk_in (padrão) = só quem chegou sem horário marcado; all = todos.
# REQUIRED_SQL é a MESMA regra em SQL (fila do acolhimento e ordem da fila do
# profissional); pede o JOIN de UNITS_JOIN. Uma só definição: required? e o
# SQL são conferidos juntos em spec/services/screenings/queue_spec.rb.
module Screenings
  module Scope
    UNITS_JOIN = "INNER JOIN health_units scope_units ON scope_units.id = attendances.health_unit_id".freeze
    REQUIRED_SQL = "(scope_units.screening_scope = 'all' OR attendances.appointment_id IS NULL)".freeze

    module_function

    def required?(attendance)
      attendance.health_unit.screening_scope == "all" || attendance.appointment_id.nil?
    end

    # Restringe uma relação de Attendance a quem exige escuta pelo escopo.
    def requiring(relation) = relation.joins(UNITS_JOIN).where(REQUIRED_SQL)
  end
end
