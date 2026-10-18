# Adequação do CEQ por analito no ano (contrato §4; forma C3 do dashboard):
# rodadas em que o analito apareceu, adequadas e inadequadas.
module Lab
  module Eqa
    module Summary
      module_function

      def call(provider_id:, year:)
        items = LabEqaRound.where(exam_provider_id: provider_id, round_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)).flat_map(&:items)
        rows = items.group_by { |i| [ i["analyte_key"], i["lab_exam_id"] ] }.map do |(key, exam_id), list|
          adequate = list.count { |i| i["adequacy"] == "adequate" }
          { analyte_key: key, lab_exam_id: exam_id, rounds: list.size, adequate: adequate, inadequate: list.size - adequate }
        end
        { year: year, rows: rows.sort_by { |r| [ r[:analyte_key], r[:lab_exam_id] ] } }
      end
    end
  end
end
