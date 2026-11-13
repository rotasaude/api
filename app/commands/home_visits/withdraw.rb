# Retira a visita (módulo 24b, ADR 0052; contrato §2, §13; plano, Task 10,
# Review Focus 2). Só o dono da folha (outro usuário → not_found), com
# `expected_state: "recorded"` e `reason` de 10–500 caracteres depois do strip
# (cifrado; nunca no evento, no log nem no erro). Trava folha → visita (FOR
# UPDATE, a ordem do §3 sem paciente nem domicílio): já retirada (ou estado
# esperado diferente) → 409 visit_changed; folha fechada → 409 day_closed. O
# fechamento trava a mesma folha: ou a retirada entra antes (a ficha sai sem
# ela) ou espera e recebe day_closed. A linha só ganha os três campos de
# retirada (trigger rota_home_visit_guard, que relê a folha FOR SHARE). A visita
# sai das fontes na hora (decisão 23). Evento só com ids.
module HomeVisits
  module Withdraw
    EVENT = "home_visit.withdrawn".freeze
    STATES = %w[recorded withdrawn].freeze

    module_function

    # -> Result.ok(visit:) | fail(:not_found) | fail(:visit_changed) | fail(:day_closed)
    #  | fail(:invalid_request, details: { path: "expected_state" | "reason" })
    def call(visit, by:, expected_state:, reason:)
      return Result.fail(:invalid_request, details: { path: "expected_state" }) unless STATES.include?(expected_state)

      text = reason.strip if reason.is_a?(String)
      return Result.fail(:invalid_request, details: { path: "reason" }) unless text && Catalog::WITHDRAWAL_REASON.cover?(text.length)

      day_id = visit.home_visit_day_id
      return Result.fail(:not_found) unless by && HomeVisitDay.where(id: day_id, user_id: by.id).exists?

      HomeVisit.transaction(requires_new: true) do
        day = HomeVisitDay.lock.find(day_id)
        visit.lock!
        next Result.fail(:visit_changed) if visit.withdrawn? || expected_state != "recorded"
        next Result.fail(:day_closed) unless day.open?

        visit.update!(withdrawn_at: Time.current, withdrawn_by_user: by, withdrawal_reason: text)
        DomainEvents.publish(EVENT, home_visit_id: visit.id, home_visit_day_id: day.id, user_id: by.id)
        Result.ok(visit: visit)
      end
    end
  end
end
