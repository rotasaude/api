# Forma da rodada e do relatório anual do CEQ (contrato §4; C12; C-E24): o
# relatório é do programa no ano e sai pela rota do próprio CEQ.
module Lab
  module Eqa
    module Json
      module_function

      def round(r)
        { id: r.id, provider_id: r.exam_provider_id, program: r.program, round_code: r.round_code, round_date: r.round_date.iso8601,
          items: r.items, recorded_by: Screenings::Json.staff_name(r.recorded_by_user), recorded_at: r.created_at.iso8601 }
      end

      def annual_report(r)
        { id: r.id, provider_id: r.exam_provider_id, program: r.program, year: r.year, url: "/lab/eqa/annual_reports/#{r.id}/pdf",
          recorded_by: Screenings::Json.staff_name(r.recorded_by_user), recorded_at: r.created_at.iso8601 }
      end
    end
  end
end
