# Cancelamento da ação do CAPS (ADR 0049; plano, Desvio 5; contrato §4, P12,
# P13, P25): a única mudança da ação imutável, uma vez, com motivo (10..2000,
# cifrado). Trava a linha do CAPS (FOR SHARE, ruling: o fechamento do mês trava
# FOR UPDATE) e a ação, e só então lê o fechamento do mês: já cancelada → 409
# already_cancelled; mês com remessa RAAS gerada → 409 already_exported; mês
# fechado e não exportado → só `psychosocial_lead` (403 lead_required).
# Publica `psychosocial.action_cancelled` só com o id.
module Psychosocial
  module CancelAction
    module_function

    # -> Result.ok(action:) | fail(:already_cancelled | :already_exported | :lead_required) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(action:, reason:, by:, now: Time.current)
      return Result.fail(:already_cancelled) if action.cancelled?

      refusal = Catalog.text_problem(reason, Catalog::CANCEL_REASON, "reason")
      return Result.fail(refusal[:error].to_sym, details: { path: refusal[:path], problems: [ refusal ] }) if refusal

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(action.health_unit_id)
        action.lock!
        next Result.fail(:already_cancelled) if action.cancelled?
        next Result.fail(:already_exported) if PsychosocialRaasExport.exists?(health_unit_id: action.health_unit_id, month: action.month)
        next Result.fail(:lead_required) if MonthlyRecords.closed?(action.health_unit_id, action.month) && !Access.lead?(by)

        action.update!(cancelled_at: now, cancelled_by_user: by, cancel_reason: reason.strip)
        DomainEvents.publish("psychosocial.action_cancelled", action_id: action.id)
        Result.ok(action: action)
      end
    end
  end
end
