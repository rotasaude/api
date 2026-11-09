# Registro de uma chamada (ADR 0050; plano, Desvio 12): Call, CallNext,
# chamada para a classificação e "chamar de novo" gravam uma attendance_calls
# com a senha do momento, o local e o tipo — só com o waiting_room_display
# utilizável (`enabled:`, lido pelo chamador fora da transação). Desligado,
# nenhuma linha. É o que a TV lê (senha, local, tipo e hora).
module Attendances
  module CallRecord
    module_function

    # -> AttendanceCall | nil
    def record!(attendance:, kind:, location:, by:, enabled:, at: Time.current)
      return nil unless enabled
      raise ArgumentError, "kind fora de #{Urgency::Catalog::CALL_KINDS}" unless Urgency::Catalog::CALL_KINDS.include?(kind)

      AttendanceCall.create!(attendance: attendance, ticket: attendance.ticket, call_location: location, kind: kind,
                             called_at: at, called_by_user: by)
    end

    # A chamada na forma das respostas: `{ id, kind, ticket, location, called_at }`.
    def json(call)
      return nil unless call

      { id: call.id, kind: call.kind, ticket: call.ticket, location: call.call_location&.name, called_at: call.called_at.iso8601 }
    end
  end
end
