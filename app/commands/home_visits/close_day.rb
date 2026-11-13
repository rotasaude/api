# Fecha a folha do dia (módulo 24b, ADR 0052; contrato §2, §10; plano, Task 10,
# Desvio 2). open → closed uma vez: pelo dono (`closed_by: "user"`, `by:` o
# usuário dono), pelo job das 3h20 (`"job"`) ou cheia, na 100ª visita do
# HomeVisits::Record (`"full"`) — esses dois sem usuário (`by: nil`). Trava a
# folha FOR UPDATE (a retirada trava a mesma linha antes da visita: ou ela entra
# antes e a ficha sai sem a visita, ou recebe day_closed). A ficha 8 nasce
# DENTRO desta transação (Ledi::HomeVisitDayFicha.generate, com o Current.city
# do CityConnection.with de quem chama — nunca atribuído aqui): prazo do SIAPS
# vencido fecha com "não gerada" siaps_deadline_passed; exportação não
# utilizável fecha sem ficha (not_exported, Desvio 3); folha só com retiradas
# fecha sem ficha nem falha (empty). Nunca descarta. Evento só com ids.
module HomeVisits
  module CloseDay
    EVENT = "home_visit_day.closed".freeze

    module_function

    # -> Result.ok(day:) | fail(:day_changed) | fail(:not_found)
    #  | fail(:invalid_request, details: { path: "expected_state" })
    def call(day, by:, closed_by:, expected_state: "open")
      raise ArgumentError, "closed_by" unless Catalog::CLOSED_BY.include?(closed_by)
      raise ArgumentError, "by: só (e sempre) com closed_by user" if (closed_by == "user") == by.nil?
      unless expected_state.is_a?(String) && HomeVisitDay::STATES.include?(expected_state)
        return Result.fail(:invalid_request, details: { path: "expected_state" })
      end
      return Result.fail(:not_found) if by && day.user_id != by.id

      HomeVisitDay.transaction(requires_new: true) do
        day.lock!
        next Result.fail(:day_changed) unless day.open? && expected_state == "open"

        day.update!(state: "closed", closed_at: Time.current, closed_by: closed_by, closed_by_user: by)
        Ledi::HomeVisitDayFicha.generate(day)
        DomainEvents.publish(EVENT, home_visit_day_id: day.id, closed_by: closed_by)
        Result.ok(day: day)
      end
    end
  end
end
