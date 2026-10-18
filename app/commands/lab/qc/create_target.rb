# Referência da bula (contrato §3): por lote, nível, analito do material e
# aparelho ativo do laboratório; média e dp como string com ponto (C-E9) (dp > 0); nova
# versão a cada gravação (nunca edita), com motivo quando troca a vigente
# (C6). Lote travado: versões sem buraco. Ordem de travas (C-E35): o
# APARELHO (FOR SHARE) antes do lote — a FK da referência toma FOR KEY SHARE
# no aparelho, e o valor de controle trava aparelho → lote.
module Lab
  module Qc
    module CreateTarget
      module_function

      def call(params, by:, now: Time.current)
        params = params.to_h.stringify_keys
        lot = params["lot_id"].to_s.match?(Exams::BaseController::UUID) ? LabQcLot.find_by(id: params["lot_id"]) : nil
        return Result.fail(:not_found) unless lot

        material = lot.lab_qc_material
        return Result.fail(:invalid_levels) unless material.levels.include?(params["level"])
        return Result.fail(:invalid_analytes) unless material.analyte_entry(params["analyte_key"])

        instrument = instrument_for(params["instrument_id"], material.exam_provider_id)
        return Result.fail(:invalid_instrument) unless instrument

        mean = Decimal.json(params["mean"])
        sd = Decimal.json(params["sd"])
        return Result.fail(:invalid_value) unless mean && sd && sd.positive?

        reason = params["reason"].is_a?(String) ? params["reason"].strip.presence : nil
        return Result.fail(:invalid_reason) if reason && reason.length > 1000

        ApplicationRecord.transaction(requires_new: true) do
          instrument = LabInstrument.lock("FOR SHARE").find(instrument.id)
          next Result.fail(:invalid_instrument) unless instrument.active

          lot.lock!
          next Result.fail(:lot_closed) if lot.status == "closed"
          next Result.fail(:expired_lot) if lot.expired?(now.in_time_zone.to_date)

          # C6 (spec §9): trocar a referência vigente exige motivo; a primeira, não.
          replacing = LabQcTarget.current(lot_id: lot.id, level: params["level"], analyte_key: params["analyte_key"], instrument_id: instrument.id)
          next Result.fail(:reason_required) if replacing && reason.nil?

          target = LabQcTarget.create!(lab_qc_lot: lot, level: params["level"], analyte_key: params["analyte_key"], lab_instrument: instrument,
                                       version: next_version(lot.id, params["level"], params["analyte_key"], instrument.id),
                                       source: "package_insert", mean: mean, sd: sd, reason: reason, accepted_by_user: by, accepted_at: now,
                                       created_at: now)
          DomainEvents.publish("lab_qc_target.accepted", lab_qc_target_id: target.id, source: "package_insert")
          Result.ok(target: target)
        end
      end

      # Chame com o lote travado.
      def next_version(lot_id, level, analyte_key, instrument_id)
        LabQcTarget.where(lab_qc_lot_id: lot_id, level: level, analyte_key: analyte_key, lab_instrument_id: instrument_id).maximum(:version).to_i + 1
      end

      def instrument_for(id, provider_id)
        return nil unless id.to_s.match?(Exams::BaseController::UUID)

        LabInstrument.active.find_by(id: id, exam_provider_id: provider_id)
      end
      private_class_method :instrument_for
    end
  end
end
