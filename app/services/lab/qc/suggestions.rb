# Sugestão da referência do laboratório (spec §5.8; Desvio 4): por lote em
# uso, nível, analito e aparelho, com a referência vigente; conta as
# corridas aceitas (approved/warning) com valor não reprovado gravado DEPOIS da
# referência vigente (o último valor de cada corrida); com 20 ou mais, média e
# dp amostral (n − 1), 4 casas, BigDecimal.
module Lab
  module Qc
    module Suggestions
      MIN_RUNS = 20
      Suggestion = Data.define(:lot_id, :level, :analyte_key, :instrument_id, :mean, :sd, :runs, :current_version, :current_source)

      module_function

      def list(provider_id:)
        lots = LabQcLot.joins(:lab_qc_material).where(status: "in_use", lab_qc_materials: { exam_provider_id: provider_id }).select(:id)
        current = LabQcTarget.where(lab_qc_lot_id: lots).order(:version).to_a
                             .group_by { |t| [ t.lab_qc_lot_id, t.level, t.analyte_key, t.lab_instrument_id ] }.values.map(&:last)
        current.filter_map { |target| for_target(target) }.sort_by { |x| [ x.analyte_key, x.level, x.lot_id ] }
      end

      def find(lot_id:, level:, analyte_key:, instrument_id:)
        target = LabQcTarget.current(lot_id: lot_id, level: level, analyte_key: analyte_key, instrument_id: instrument_id)
        target && for_target(target)
      end

      def for_target(target)
        rows = LabQcValue.joins(:lab_qc_run)
                         .where(lab_qc_runs: { lab_instrument_id: target.lab_instrument_id, status: LabQcRun::ACCEPTED })
                         .where(lab_qc_lot_id: target.lab_qc_lot_id, level: target.level, analyte_key: target.analyte_key)
                         .where.not(outcome: "reject").where("lab_qc_values.entered_at > ?", target.accepted_at)
                         .order(:entered_at, :created_at).pluck(:lab_qc_run_id, :value)
        values = rows.each_with_object({}) { |(run_id, value), last| last[run_id] = BigDecimal(value.to_s) }.values
        return nil if values.size < MIN_RUNS

        mean = values.sum / values.size
        sd = (values.sum { |v| (v - mean)**2 } / (values.size - 1)).sqrt(20)
        return nil unless sd.round(4).positive?

        Suggestion.new(lot_id: target.lab_qc_lot_id, level: target.level, analyte_key: target.analyte_key, instrument_id: target.lab_instrument_id,
                       mean: mean.round(4), sd: sd.round(4), runs: values.size, current_version: target.version, current_source: target.source)
      end
      private_class_method :for_target
    end
  end
end
