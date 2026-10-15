# Nova versão do exame (contrato §3): nunca edita a vigente. O código do
# aparelho é único entre as versões VIGENTES do laboratório (trava do prestador).
module Lab
  module CreateVersion
    module_function

    def call(exam:, params:, by:)
      params = params.to_h.stringify_keys
      # "method" no JSON (contrato §3) = coluna analysis_method.
      analysis_method, material, container = %w[method material container].map { |k| params[k].is_a?(String) ? params[k].strip : "" }
      return Result.fail(:invalid_version) unless analysis_method.length.between?(1, 160) && material.length.between?(1, 60) && container.length.between?(1, 60)

      code = params["instrument_test_code"].presence
      return Result.fail(:invalid_version) unless code.nil? || (code.is_a?(String) && code.match?(/\A[A-Za-z0-9._-]{1,30}\z/))

      analytes = Analytes.parse(params["analytes"])
      return analytes if analytes.failure?

      ApplicationRecord.transaction do
        exam.exam_provider.lock!
        if code && LabExam.where(exam_provider_id: exam.exam_provider_id).where.not(id: exam.id)
                          .joins(:current_version).where(lab_exam_versions: { instrument_test_code: code }).exists?
          next Result.fail(:duplicate_instrument_code)
        end

        exam.lock!
        number = exam.versions.maximum(:version).to_i + 1
        version = LabExamVersion.create!(lab_exam: exam, version: number, analysis_method: analysis_method, material: material, container: container,
                                         instrument_test_code: code, analytes: analytes.payload[:analytes], created_by_user: by)
        exam.update!(current_version: version)
        DomainEvents.publish("lab_exam.version_created", lab_exam_id: exam.id, version: number)
        Result.ok(version: version)
      end
    end
  end
end
