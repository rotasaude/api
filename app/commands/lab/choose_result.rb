# O liberador escolhe a repetição que vale (spec §5.6; Desvio 9): acrescenta
# cópia `chosen` da linha escolhida e refaz os calculados. A cópia vira a
# última do componente (created_at estritamente crescente, como EnterResults).
module Lab
  module ChooseResult
    module_function

    def call(result:, by:, now: Time.current)
      item = result.lab_requisition_item
      return Result.fail(:missing_role) unless Access.releaser_link(by, item.lab_requisition.exam_provider_id)

      ApplicationRecord.transaction do
        # E2: requisição → item.
        item.lab_requisition.lock!
        item.lock!
        next Result.fail(:invalid_transition, details: { status: item.status }) unless EnterResults::OPEN.include?(item.status)

        last = item.results.where(analyte_key: result.analyte_key).maximum(:created_at)
        at = now.round(6)
        at = last + Rational(1, 1_000_000) if last && at <= last
        copy = LabResult.create!(lab_requisition_item: item, analyte_key: result.analyte_key, value: result.value, unit: result.unit,
                                 flag: result.flag, source: result.source, lab_hl7_receipt_id: result.lab_hl7_receipt_id,
                                 entered_by_user: by, entered_at: now, chosen: true, chosen_from: result, created_at: at)
        EnterResults.recalculate!(item, source: result.source, by: by, receipt: result.lab_hl7_receipt, now: now)
        Result.ok(result: copy)
      end
    end
  end
end
