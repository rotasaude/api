# Lote do material (contrato §3): número único no material; validade não
# vencida; um código de barras por nível do material (Desvio 1): formato
# [A-Za-z0-9._-]{3,30}; só 10 dígitos é o espaço das amostras (barcode_taken);
# único na cidade (barcode_taken).
module Lab
  module Qc
    module CreateLot
      module_function

      def call(params, by:, now: Time.current)
        params = params.to_h.stringify_keys
        material = params["material_id"].to_s.match?(Exams::BaseController::UUID) ? LabQcMaterial.find_by(id: params["material_id"]) : nil
        return Result.fail(:not_found) unless material

        number = params["lot_number"].is_a?(String) ? params["lot_number"].strip : ""
        return Result.fail(:invalid_lot_number) unless number.length.between?(1, 40)

        expires_on = parse_date(params["expires_on"])
        return Result.fail(:invalid_expires_on) unless expires_on
        return Result.fail(:expired_lot) if expires_on < now.in_time_zone.to_date

        codes = params["level_barcodes"]
        codes = codes.to_unsafe_h if codes.respond_to?(:to_unsafe_h)
        return Result.fail(:invalid_levels) unless codes.is_a?(Hash) && codes.keys.map(&:to_s).sort == material.levels.sort

        codes = codes.to_h { |level, code| [ level.to_s, code.is_a?(String) ? code.strip : code ] }
        return Result.fail(:barcode_taken) if codes.values.any? { |c| c.is_a?(String) && c.match?(LabQcLotBarcode::SAMPLE_SPACE) }
        return Result.fail(:invalid_barcode) unless codes.values.all? { |c| LabQcLotBarcode.valid_code?(c) }
        return Result.fail(:barcode_taken) unless codes.values.map(&:downcase).uniq.size == codes.size

        ApplicationRecord.transaction(requires_new: true) do
          material.lock!
          next Result.fail(:duplicate_lot) if material.lots.exists?(lot_number: number)
          next Result.fail(:barcode_taken) if LabQcLotBarcode.exists?([ "lower(barcode) IN (?)", codes.values.map(&:downcase) ])

          lot = LabQcLot.create!(lab_qc_material: material, lot_number: number, expires_on: expires_on, status: "in_use",
                                 opened_on: now.in_time_zone.to_date, created_by_user: by)
          codes.each { |level, code| LabQcLotBarcode.create!(lab_qc_lot: lot, level: level, barcode: code, created_at: now) }
          Result.ok(lot: lot)
        end
      rescue ActiveRecord::RecordNotUnique
        Result.fail(:barcode_taken) # o mesmo código gravado por outro lote ao mesmo tempo
      end

      def parse_date(raw)
        raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(raw) : nil
      rescue Date::Error
        nil
      end
    end
  end
end
