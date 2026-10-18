# Adequação do CEQ por analito no ano (contrato §4; forma C3 do dashboard):
# rodadas em que o analito apareceu, adequadas e inadequadas; e, por programa,
# se o ano tem relatório anual (C-E24).
module Lab
  module Eqa
    module Summary
      module_function

      def call(provider_id:, year:)
        rounds = LabEqaRound.where(exam_provider_id: provider_id, round_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
        items = rounds.flat_map(&:items)
        reports = LabEqaAnnualReport.where(exam_provider_id: provider_id, year: year).index_by(&:program)
        programs = (rounds.map(&:program) | reports.keys).sort.map do |name|
          { program: name, annual_report: reports.key?(name), annual_report_id: reports[name]&.id }
        end
        rows = items.group_by { |i| [ i["analyte_key"], i["lab_exam_id"] ] }.map do |(key, exam_id), list|
          adequate = list.count { |i| i["adequacy"] == "adequate" }
          { analyte_key: key, lab_exam_id: exam_id, rounds: list.size, adequate: adequate, inadequate: list.size - adequate }
        end
        { year: year, rows: rows.sort_by { |r| [ r[:analyte_key], r[:lab_exam_id] ] }, programs: programs }
      end
    end
  end
end
