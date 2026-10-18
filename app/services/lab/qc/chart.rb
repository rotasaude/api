# Levey-Jennings (contrato §3; spec §5.9; C-E5): referência vigente (null se
# não há) e até 200 pontos do período (os mais recentes), do mais antigo ao
# mais novo, cada um com o z e a versão da referência com que foi avaliado
# (o valor nunca é recalculado). Sem trilha (nada de paciente).
module Lab
  module Qc
    module Chart
      MAX_POINTS = 200

      module_function

      def call(lot:, level:, analyte_key:, instrument:, from:, to:)
        target = LabQcTarget.current(lot_id: lot.id, level: level, analyte_key: analyte_key, instrument_id: instrument.id)
        points = LabQcValue.joins(:lab_qc_run).includes(:lab_qc_target)
                           .where(lab_qc_runs: { lab_instrument_id: instrument.id })
                           .where(lab_qc_lot_id: lot.id, level: level, analyte_key: analyte_key, entered_at: from..to)
                           .order(entered_at: :desc, created_at: :desc).limit(MAX_POINTS).to_a.reverse
        { target: target && { mean: Decimal.out(target.mean), sd: Decimal.out(target.sd), version: target.version, source: target.source },
          points: points.map do |v|
            { at: v.entered_at.iso8601, value: Decimal.out(v.value), z_score: v.z_score.to_f, outcome: v.outcome,
              rules_fired: v.rules_fired, target_version: v.lab_qc_target.version }
          end }
      end
    end
  end
end
