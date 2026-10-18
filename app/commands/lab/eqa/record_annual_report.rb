# Relatório anual do CEQ (C-E24): um PDF por laboratório, programa e ano. O
# upload vem de /lab/eqa/uploads (finalidade própria) e é consumido aqui; a
# recusa deixa o upload intacto. Repetido: already_recorded. Só acréscimo.
module Lab
  module Eqa
    module RecordAnnualReport
      module_function

      def call(params, by:, now: Time.current)
        params = params.to_h.stringify_keys
        provider = params["provider_id"].to_s.match?(Exams::BaseController::UUID) ? Lab::Access.labs.find_by(id: params["provider_id"]) : nil
        return Result.fail(:invalid_provider) unless provider

        program = params["program"].is_a?(String) ? params["program"].strip : ""
        return Result.fail(:invalid_program) unless program.length.between?(1, 60)

        year = params["year"]
        return Result.fail(:invalid_year) unless year.is_a?(Integer) && year.between?(2000, [ now.year, 2100 ].min)

        result = nil
        ApplicationRecord.transaction(requires_new: true) do
          provider.lock!
          next result = Result.fail(:already_recorded) if LabEqaAnnualReport.exists?(exam_provider_id: provider.id, program: program, year: year)

          file = Exams::Files.claim!(file_id: params["upload_id"], user: by, purpose: LabEqaAnnualReport::PURPOSE)
          next result = Result.fail(:invalid_file) unless file&.content_type == "application/pdf"

          report = LabEqaAnnualReport.create!(exam_provider: provider, program: program, year: year, file: file, recorded_by_user: by, created_at: now)
          DomainEvents.publish("lab_eqa_annual_report.recorded", lab_eqa_annual_report_id: report.id)
          result = Result.ok(report: report)
        end
        result
      end
    end
  end
end
