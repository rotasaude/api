# Fechamento do mês de um CAPS (ADR 0049; contrato §6, P14, P24, P37; plano,
# Desvio 7; Review Focus 3). Quem chama confere a coordenação e o step-up.
#
# Numa transação: trava a linha do CAPS (FOR UPDATE, ruling: serializa com
# RecordAction, CancelAction, StartNightStay, CloseNightStay e a matrícula, que
# a seguram FOR SHARE) e só então lê o fechamento e as pendências. Fechamento
# ativo → 409 already_closed. Alguma pendência (MonthProblems; os avisos —
# no_actions e as pendências rebaixadas pelo P57 — não bloqueiam) → 422 month_has_problems com
# `problems: [ { error, path: "records.<id>" } ]`, um por (registro, pendência),
# nada gravado. Senão trava os registros da janela (P37: os de meses depois do
# encerramento da matrícula ficam de fora e abertos), grava em cada um a foto
# cifrada e `closed`, grava o fechamento (trava as ações do mês, trigger) e
# publica `psychosocial.month_closed` só com `health_unit_id` e `month`
# ("YYYY-MM").
module Psychosocial
  module CloseMonth
    module_function

    # month: dia 1º. -> Result.ok(closure:) | fail(:already_closed) | fail(:month_has_problems, details: { problems: })
    def call(unit:, month:, by:, now: Time.current)
      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR UPDATE").find(unit.id)
        next Result.fail(:already_closed) if MonthlyRecords.closed?(unit.id, month)

        report = MonthProblems.for(health_unit: unit, month: month, today: now.in_time_zone.to_date)
        problems = report[:records].flat_map do |entry|
          entry[:problems].map { |code| { error: code, path: "records.#{entry[:record].id}" } }
        end
        next Result.fail(:month_has_problems, details: { problems: problems }) if problems.any?

        close_records!(unit, month, now)
        closure = PsychosocialMonthClosure.create!(health_unit: unit, month: month, closed_by_user: by, closed_at: now)
        DomainEvents.publish("psychosocial.month_closed", health_unit_id: unit.id, month: month.strftime("%Y-%m"))
        Result.ok(closure: closure)
      end
    end

    def close_records!(unit, month, now)
      records = MonthProblems.in_window(unit.id, month).where(status: "open").lock("FOR UPDATE OF psychosocial_monthly_records")
                             .includes(psychosocial_enrollment: :patient).to_a
      contacts = Billing::PatientContact.for(records.map { |r| r.psychosocial_enrollment.patient_id })
      records.each do |record|
        phone = MonthlyRecords.contact_phone(record, contacts[record.psychosocial_enrollment.patient_id]&.phone, unit)
        record.update!(status: "closed", closed_at: now, snapshot: MonthlyRecords.snapshot(record, phone: phone))
      end
    end

    private_class_method :close_records!
  end
end
