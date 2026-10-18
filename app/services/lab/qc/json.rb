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

      def value(v)
        { id: v.id, run_id: v.lab_qc_run_id, lot_id: v.lab_qc_lot_id, level: v.level, analyte_key: v.analyte_key, value: out(v.value),
          z_score: v.z_score.to_f, rules_fired: v.rules_fired, outcome: v.outcome, source: v.source, target_version: v.lab_qc_target.version,
          reagent_lot_id: v.reagent_lot_id, reagent_lot: v.reagent_lot && { id: v.reagent_lot.id, lot_number: v.reagent_lot.lot_number },
          entered_at: at(v.entered_at), entered_by: Screenings::Json.staff_name(v.entered_by_user) }
      end

      def run(r)
        { id: r.id, instrument_id: r.lab_instrument_id, sector: r.sector, status: r.status, started_at: at(r.started_at),
          evaluated_at: at(r.evaluated_at), values: r.values.includes(:lab_qc_target, :entered_by_user, :reagent_lot).map { |v| value(v) } }
      end

      def block(b)
        { id: b.id, instrument_id: b.lab_instrument_id, analyte_key: b.analyte_key, opened_at: at(b.opened_at), opened_by_run_id: b.opened_by_run_id,
          corrective_action: b.corrective_action, corrective_action_at: at(b.corrective_action_at), closed_at: at(b.closed_at),
          closed_by_run_id: b.closed_by_run_id }
      end

      def rule(instrument_id, analyte_key, row)
        { instrument_id: instrument_id, analyte_key: analyte_key, is_default: row.nil?,
          rules: LabQcRule::RULES.index_with { |r| row ? row.rules[r] == true : true },
          justification: row&.justification, changed_by: row && Screenings::Json.staff_name(row.changed_by_user), changed_at: at(row&.created_at) }
      end
    end
  end
end
