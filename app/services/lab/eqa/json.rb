# Forma da rodada do CEQ (contrato §4; C12; C-E1): o relatório anual sai pela
# rota do próprio CEQ; annual_report_upload_id vem sempre (null sem relatório).
module Lab
  module Eqa
    module Json
      module_function

      def round(r)
        { id: r.id, provider_id: r.exam_provider_id, program: r.program, round_code: r.round_code, round_date: r.round_date.iso8601,
          items: r.items, annual_report_upload_id: r.annual_report_file_id,
          annual_report_url: r.annual_report_file_id && "/lab/eqa/rounds/#{r.id}/annual_report.pdf",
          recorded_by: Screenings::Json.staff_name(r.recorded_by_user), recorded_at: r.created_at.iso8601 }
      end
    end
  end
end
