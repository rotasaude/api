# Consumo estimado (spec §6.8; Desvio 13; C-E8, C-E30): por item reagente do
# laboratório no mês, testes realizados contra testes das aberturas. Um teste
# é uma entrada de resultado (item + entered_at, sem cópias escolhidas — a
# repetição conta, a escolha não — e só de analitos medidos: o calculado herda
# o lote mas não é teste) ou um valor de controle (corrida + nível +
# entered_at) de analito ligado a um exame do item. Testes das aberturas =
# embalagens abertas no mês × rendimento; sem abertura no mês é nil e o desvio
# também (nunca divisão por zero). Só leitura: nada é baixado.
module Lab
  module Inventory
    module Consumption
      HEADERS = %w[linha item aparelho testes_realizados testes_das_aberturas desvio_pct].freeze

      module_function

      def call(provider_id:, month:)
        range = month.beginning_of_month.beginning_of_day...month.next_month.beginning_of_month.beginning_of_day
        LabSupply.where(exam_provider_id: provider_id, kind: "reagent").order(:name, :id).flat_map do |supply|
          performed = performed(provider_id, supply.lab_exam_ids, range)
          total = performed.values.sum
          opened = opened(supply, range)
          deviation = opened&.positive? ? BigDecimal(((total - opened) * 100).to_s).div(opened, 10).round(1).to_f : nil
          lines = performed.reject { |id, _| id.nil? }.sort_by { |id, _| id }.map { |id, count| row(supply, id, count, nil, nil, "instrument") }
          lines << row(supply, nil, performed[nil], nil, nil, "no_instrument") if performed[nil].positive?
          [ row(supply, nil, total, opened, deviation, "total") ] + lines
        end
      end

      def opened(supply, range)
        packages = -LabSupplyMovement.joins(:lab_supply_lot)
                                     .where(lab_supply_lots: { lab_supply_id: supply.id }, kind: "opening", recorded_at: range).sum(:quantity)
        packages.positive? && supply.tests_per_package ? packages * supply.tests_per_package : nil
      end

      def performed(provider_id, exam_ids, range)
        counts = Hash.new(0)
        results(exam_ids, range).each { |instrument_id| counts[instrument_id] += 1 }
        controls(provider_id, exam_ids, range).each { |instrument_id| counts[instrument_id] += 1 }
        counts
      end

      # Uma entrada por item + entered_at com ao menos um analito medido.
      def results(exam_ids, range)
        rows = LabResult.joins(lab_requisition_item: :lab_exam_version)
                        .where(chosen: false, entered_at: range, lab_exam_versions: { lab_exam_id: Array(exam_ids) })
                        .pluck("lab_exam_versions.lab_instrument_id", "lab_results.lab_requisition_item_id", "lab_results.entered_at",
                               "lab_results.analyte_key", "lab_exam_versions.id")
        calculated = LabExamVersion.where(id: rows.map(&:last).uniq).to_h { |v| [ v.id, v.calculated_analytes.map { |a| a["key"] } ] }
        rows.reject { |*, key, version_id| calculated.fetch(version_id, []).include?(key) }
            .map { |instrument_id, item_id, at, *| [ instrument_id, item_id, at ] }.uniq.map(&:first)
      end

      # Um por corrida + nível + entered_at, de analitos ligados aos exames do item.
      def controls(provider_id, exam_ids, range)
        wanted = Array(exam_ids)
        LabQcValue.joins(:lab_qc_run, lab_qc_lot: :lab_qc_material)
                  .where(entered_at: range, lab_qc_materials: { exam_provider_id: provider_id })
                  .pluck("lab_qc_runs.lab_instrument_id", :lab_qc_run_id, :level, :entered_at, :analyte_key, "lab_qc_materials.analytes")
                  .select { |*, key, analytes| analytes.any? { |a| a["analyte_key"] == key && wanted.include?(a["lab_exam_id"]) } }
                  .map { |instrument_id, run_id, level, at, *| [ instrument_id, run_id, level, at ] }.uniq.map(&:first)
      end

      def row(supply, instrument_id, performed, opened, deviation, line)
        { line: line, supply_id: supply.id, name: supply.name, instrument_id: instrument_id, tests_performed: performed, tests_opened: opened,
          deviation_pct: deviation }
      end
      private_class_method :opened, :performed, :results, :controls, :row
    end
  end
end
