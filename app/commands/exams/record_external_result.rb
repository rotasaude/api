# Resultado sem pedido (ADR 0036; spec §6; contrato A9): origem external,
# ciência dada por quem registra (nasce reconhecido), nunca para prestador.
# Quem chama já autorizou e, se resolveu o paciente, faz isso na mesma
# transação. Savepoint próprio: o PDF consumido por quem não é PDF volta a
# ser órfão. Valor e PDF nunca vão a log, evento ou erro; o evento leva só o id.
module Exams
  module RecordExternalResult
    module_function

    def call(patient:, sigtap_code:, released_on:, laboratory_name:, file_id:, values:, by:, consultation: nil)
      exam = ClinicalTerms::SigtapExams.find(sigtap_code, on: Time.zone.today)
      return Result.fail(:sigtap_unknown) unless exam

      released = Dates.parse(released_on)
      return Result.fail(:invalid_released_on) unless released && released <= Time.zone.today
      return Result.fail(:invalid_laboratory) unless laboratory_name.is_a?(String) && laboratory_name.strip.length.between?(1, 160)

      checked = ResultValues.from_input(ExamCatalogItem.find_by(sigtap_code: exam.code), values)
      return checked if checked.failure?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        file = Files.claim!(file_id: file_id, user: by)
        unless file&.content_type == "application/pdf"
          result = Result.fail(:missing_pdf)
          raise ActiveRecord::Rollback
        end

        stored = ExamResult.create!(patient: patient, sigtap_code: exam.code, origin: "external",
                                    source: consultation ? "consultation" : "unit", pdf_file: file,
                                    values: checked.payload[:values].to_json, released_on: released,
                                    laboratory_name: laboratory_name.strip, critical: false, registered_by_user: by,
                                    consultation: consultation)
        DomainEvents.publish("exam_result.external_recorded", exam_result_id: stored.id)
        result = Result.ok(result: stored)
      end
      result
    end
  end
end
