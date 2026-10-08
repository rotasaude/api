# app/services/consultations/care_type.rb
# Tipo de atendimento sugerido (spec §4; Task 1): horário marcado → consulta
# agendada (2); o resto (demanda espontânea, com ou sem escuta same_day) →
# consulta no dia (5). O profissional edita.
module Consultations
  module CareType
    SCHEDULED = 2
    SAME_DAY = 5

    module_function

    def suggest(attendance) = attendance.appointment_id ? SCHEDULED : SAME_DAY
  end
end
