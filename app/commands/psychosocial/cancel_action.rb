# Cancelamento da ação do CAPS (ADR 0049; plano, Desvio 5; contrato §4, P12,
# P13, P25): a única mudança da ação imutável, uma vez, com motivo (10..2000,
# cifrado). Trava a linha do CAPS (FOR SHARE, ruling: o fechamento do mês trava
# FOR NO KEY UPDATE) e a ação, e só então lê o fechamento do mês: já cancelada → 409
# already_cancelled; mês com remessa RAAS gerada → 409 already_exported; mês
# fechado e não exportado → só `psychosocial_lead` (403 lead_required).
# Publica `psychosocial.action_cancelled` só com o id.
#
# BPA (Task 12; plano, Desvio 11; contrato §8): a linha da ação
# (performed_procedures, source psychosocial) é cancelada na mesma transação,
# pelo caminho do 22 (Billing::Cancel), com um motivo fixo — o motivo do CAPS
# nunca vai ao faturamento. Linha no arquivo de competência fechada → 409
# already_exported, e a ação também não cancela (reabra a competência antes).
# Linha já cancelada pelo faturamento: a ação cancela mesmo assim. Travas na
# ordem do ledger: CAPS (FOR SHARE) → competência da linha (FOR SHARE) → ação →
# linha. A linha é procurada depois da trava do CAPS: o
# Billing::FromPsychosocial trava o CAPS FOR NO KEY UPDATE antes de gravá-la,
# então ela já existe ou só nasce depois (e aí vê a ação cancelada). Ela é
# relida depois da trava da competência: um Billing::Close em curso pode tê-la
# posto no arquivo enquanto esperávamos (→ already_exported, nunca 500).
module Psychosocial
  module CancelAction
    class LineCancelRefused < StandardError; end

    BILLING_CANCEL_REASON = "Ação do CAPS cancelada".freeze

    module_function

    # -> Result.ok(action:) | fail(:already_cancelled | :already_exported | :lead_required) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(action:, reason:, by:, now: Time.current)
      return Result.fail(:already_cancelled) if action.cancelled?

      refusal = Catalog.text_problem(reason, Catalog::CANCEL_REASON, "reason")
      return Result.fail(refusal[:error].to_sym, details: { path: refusal[:path], problems: [ refusal ] }) if refusal

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(action.health_unit_id)
        line = PerformedProcedure.find_by(psychosocial_action_id: action.id)
        period = line&.billing_period_id && BillingPeriod.lock("FOR SHARE").find(line.billing_period_id)
        line&.reload # um Billing::Close em curso pode tê-la posto no arquivo enquanto esperávamos a competência
        action.lock!
        next Result.fail(:already_cancelled) if action.cancelled?
        next Result.fail(:already_exported) if PsychosocialRaasExport.exists?(health_unit_id: action.health_unit_id, month: action.month)
        next Result.fail(:already_exported) if line&.status == "recorded" && period&.closed? && line.billing_export_id
        next Result.fail(:lead_required) if MonthlyRecords.closed?(action.health_unit_id, action.month) && !Access.lead?(by)

        refusal = line&.status == "recorded" && cancel_line!(line, by: by, now: now)
        next refusal if refusal

        action.update!(cancelled_at: now, cancelled_by_user: by, cancel_reason: reason.strip)
        DomainEvents.publish("psychosocial.action_cancelled", action_id: action.id)
        Result.ok(action: action)
      end
    end

    # -> nil (cancelada, ou já cancelada pelo faturista no meio:
    # invalid_transition, nada a fazer) | Result.fail(:already_exported) (409;
    # rede caso a linha tenha entrado no arquivo apesar da releitura). Outra
    # recusa não é esperada e desfaz tudo.
    def cancel_line!(line, by:, now:)
      result = Billing::Cancel.call(procedure: line, reason: BILLING_CANCEL_REASON, by: by, now: now)
      return nil if result.ok? || result.reason == :invalid_transition
      return Result.fail(:already_exported) if result.reason == :already_exported

      raise LineCancelRefused, "performed_procedure_id=#{line.id} #{result.reason}"
    end

    private_class_method :cancel_line!
  end
end
