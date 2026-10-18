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
        next Result.fail(:item_frozen) if Frozen.item?(item) # B54

        # Calculado é função dos insumos que valem, não uma medida repetida.
        if item.lab_exam_version.analyte(result.analyte_key)&.dig("formula").present?
          next Result.fail(:unknown_analyte, details: { analyte_key: result.analyte_key })
        end

        last = item.results.where(analyte_key: result.analyte_key).maximum(:created_at)
        at = Clock.stamp(now, requisition_id: item.lab_requisition_id) # depois da trava (I1)
        at = last + Rational(1, 1_000_000) if last && at <= last
        copy = LabResult.create!(lab_requisition_item: item, analyte_key: result.analyte_key, value: result.value, unit: result.unit,
                                 flag: result.flag, source: result.source, lab_hl7_receipt_id: result.lab_hl7_receipt_id,
                                 entered_by_user: by, entered_at: now, chosen: true, chosen_from: result, created_at: at,
                                 reagent_lot_id: result.reagent_lot_id) # não é medida nova: o lote da medida escolhida
        EnterResults.recalculate!(item, source: result.source, by: by, receipt: result.lab_hl7_receipt, now: now)
        Result.ok(result: copy)
      end
    rescue EnterResults::Incomputable => e
      Result.fail(:invalid_values, details: { analyte_key: e.analyte_key })
    end
  end
end
