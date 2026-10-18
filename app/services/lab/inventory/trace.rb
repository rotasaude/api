# Rastreio por lote (spec §6.7; contrato §5): resultados (número da
# requisição, código do exame, data da entrada — uma linha por entrada, sem
# as cópias da escolha) e valores de controle com aquele lote. Nunca o nome
# do paciente nem valor. Até 5000 linhas por lista; busca MAX + 1 para
# avisar o corte (C-E37: results_truncated / qc_values_truncated).
module Lab
  module Inventory
    module Trace
      MAX = 5000
      CSV_HEADERS = %w[tipo requisicao_ou_corrida exame_ou_analito data].freeze

      module_function

      def call(lot:)
        results = LabResult.where(reagent_lot_id: lot.id, chosen: false)
                           .joins(lab_requisition_item: [ :lab_requisition, { lab_exam_version: :lab_exam } ])
                           .group("lab_requisitions.number", "lab_exams.sigtap_code", "lab_results.entered_at")
                           .order("lab_results.entered_at", "lab_requisitions.number", "lab_exams.sigtap_code").limit(MAX + 1)
                           .pluck("lab_requisitions.number", "lab_exams.sigtap_code", "lab_results.entered_at")
        qc = LabQcValue.where(reagent_lot_id: lot.id).order(:entered_at, :id).limit(MAX + 1).pluck(:lab_qc_run_id, :analyte_key, :entered_at)
        { lot_id: lot.id, lot_number: lot.lot_number,
          results: results.first(MAX).map { |number, code, at| { requisition_number: number, sigtap_code: code, entered_at: at.iso8601 } },
          results_truncated: results.size > MAX,
          qc_values: qc.first(MAX).map { |run_id, key, at| { run_id: run_id, analyte_key: key, entered_at: at.iso8601 } },
          qc_values_truncated: qc.size > MAX }
      end
    end
  end
end
