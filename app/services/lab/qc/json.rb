# Formas do CIQ (contrato §3). Números saem como string com ponto (C-E9).
# Nada de paciente: revisão e exceção levam número da requisição e código do exame.
module Lab
  module Qc
    module Json
      module_function

      def out(number) = Decimal.out(number)
      def at(time) = time&.iso8601

      def material(m)
        { id: m.id, provider_id: m.exam_provider_id, name: m.name, manufacturer: m.manufacturer, levels: m.levels,
          analytes: m.analytes, active: m.active, has_lots: m.lots.exists? }
      end

      def lot(l)
        { id: l.id, material_id: l.lab_qc_material_id, material_name: l.lab_qc_material.name, lot_number: l.lot_number, expires_on: l.expires_on.iso8601,
          level_barcodes: l.level_barcodes, status: l.status, opened_on: l.opened_on.iso8601, closed_on: l.closed_on&.iso8601,
          expired: l.expired? }
      end

      def target(t)
        { id: t.id, lot_id: t.lab_qc_lot_id, level: t.level, analyte_key: t.analyte_key, instrument_id: t.lab_instrument_id,
          version: t.version, source: t.source, mean: out(t.mean), sd: out(t.sd), based_on_runs: t.based_on_runs, reason: t.reason,
          accepted_by: Screenings::Json.staff_name(t.accepted_by_user), accepted_at: at(t.accepted_at) }
      end
    end
  end
end
