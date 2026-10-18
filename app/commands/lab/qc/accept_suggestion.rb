# Aceite do RT/substituto (spec §5.8): a sugestão é recalculada no servidor
# com o lote travado (nunca vem do cliente); vira nova versão `laboratory`
# com based_on_runs. Sem sugestão → not_found. Ordem de travas (C-E35): o
# APARELHO (FOR SHARE) antes do lote, como no valor de controle.
module Lab
  module Qc
    module AcceptSuggestion
      module_function

      def call(lot_id:, level:, analyte_key:, instrument_id:, reason:, by:, now: Time.current)
        text = reason.is_a?(String) ? reason.strip : ""
        return Result.fail(:reason_required) if text.empty? # C6
        return Result.fail(:invalid_reason) if text.length > 1000 # C-E11

        lot = lot_id.to_s.match?(Exams::BaseController::UUID) ? LabQcLot.find_by(id: lot_id) : nil
        return Result.fail(:not_found) unless lot
        return Result.fail(:not_found) unless instrument_id.to_s.match?(Exams::BaseController::UUID)

        ApplicationRecord.transaction(requires_new: true) do
          next Result.fail(:not_found) unless LabInstrument.lock("FOR SHARE").find_by(id: instrument_id)

          lot.lock!
          next Result.fail(:lot_closed) if lot.status == "closed"

          suggestion = Suggestions.find(lot_id: lot.id, level: level.to_s, analyte_key: analyte_key.to_s, instrument_id: instrument_id)
          next Result.fail(:not_found) unless suggestion

          target = LabQcTarget.create!(lab_qc_lot: lot, level: suggestion.level, analyte_key: suggestion.analyte_key,
                                       lab_instrument_id: suggestion.instrument_id,
                                       version: CreateTarget.next_version(lot.id, suggestion.level, suggestion.analyte_key, suggestion.instrument_id),
                                       source: "laboratory", mean: suggestion.mean, sd: suggestion.sd, based_on_runs: suggestion.runs, reason: text,
                                       accepted_by_user: by, accepted_at: now, created_at: now)
          DomainEvents.publish("lab_qc_target.accepted", lab_qc_target_id: target.id, source: "laboratory")
          Result.ok(target: target)
        end
      end
    end
  end
end
