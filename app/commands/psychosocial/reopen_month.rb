# Reabertura do mês de um CAPS (ADR 0049; contrato §6, P13, P25; plano,
# Desvio 7). Quem chama confere a coordenação e o step-up.
#
# `reason` de 10 a 500 (abaixo → invalid_request, acima → too_long, path
# `reason`). Numa transação: trava a linha do CAPS (FOR UPDATE, como o
# fechamento) e só então lê: mês com remessa RAAS → 409 already_exported; sem
# fechamento ativo → 409 month_open. Nada se apaga: o fechamento ganha quando,
# quem e o motivo (cifrado), e os registros fechados voltam a `open` sem foto.
# Publica `psychosocial.month_reopened` só com `health_unit_id` e `month`
# ("YYYY-MM"); o motivo nunca vai ao evento.
module Psychosocial
  module ReopenMonth
    module_function

    # month: dia 1º. -> Result.ok(closure:) | fail(:already_exported | :month_open) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(unit:, month:, reason:, by:, now: Time.current)
      refusal = Catalog.text_problem(reason, Catalog::REASON, "reason")
      return Result.fail(refusal[:error].to_sym, details: { path: refusal[:path], problems: [ refusal ] }) if refusal

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR UPDATE").find(unit.id)
        next Result.fail(:already_exported) if exported?(unit.id, month)

        closure = PsychosocialMonthClosure.active.lock.find_by(health_unit_id: unit.id, month: month)
        next Result.fail(:month_open) unless closure

        closure.update!(reopened_at: now, reopened_by_user: by, reopen_reason: reason.strip)
        PsychosocialMonthlyRecord.where(health_unit_id: unit.id, month: month, status: "closed").lock.each do |record|
          record.update!(status: "open", closed_at: nil, snapshot: nil)
        end
        DomainEvents.publish("psychosocial.month_reopened", health_unit_id: unit.id, month: month.strftime("%Y-%m"))
        Result.ok(closure: closure)
      end
    end

    def exported?(health_unit_id, month)
      PsychosocialRaasExport.exists?(health_unit_id: health_unit_id, month: month) ||
        PsychosocialMonthlyRecord.exists?(health_unit_id: health_unit_id, month: month, status: "exported")
    end

    private_class_method :exported?
  end
end
