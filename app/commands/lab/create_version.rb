# Nova versão do exame (contrato §3): nunca edita a vigente. O código do
# aparelho é único (sem diferença de caixa) entre as versões VIGENTES dos exames
# ATIVOS do laboratório (trava do prestador).
module Lab
  module CreateVersion
    module_function

    def call(exam:, params:, by:)
      params = params.to_h.stringify_keys
      # "method" no JSON (contrato §3) = coluna analysis_method.
      analysis_method, material, container = %w[method material container].map { |k| params[k].is_a?(String) ? params[k].strip : "" }
      return Result.fail(:invalid_version) unless analysis_method.length.between?(1, 160) && material.length.between?(1, 60) && container.length.between?(1, 60)

      raw_code = params["instrument_test_code"]
      return Result.fail(:invalid_version) unless raw_code.nil? || raw_code.is_a?(String)

      # Gravado e comparado sem espaço nas pontas e em maiúsculas ("gli" = "GLI").
      code = raw_code&.strip&.upcase.presence
      return Result.fail(:invalid_version) unless code.nil? || code.match?(/\A[A-Z0-9._-]{1,30}\z/)

      # ADR 0038: aparelho do mesmo laboratório, ativo (ou nenhum).
      raw_instrument = params["lab_instrument_id"]
      unless raw_instrument.nil?
        valid = raw_instrument.is_a?(String) && raw_instrument.match?(Exams::BaseController::UUID) &&
                LabInstrument.active.exists?(id: raw_instrument, exam_provider_id: exam.exam_provider_id)
        return Result.fail(:invalid_version) unless valid
      end

      analytes = Analytes.parse(params["analytes"])
      return analytes if analytes.failure?

      ApplicationRecord.transaction do
        exam.exam_provider.lock!
        # Só versões VIGENTES de exames ATIVOS do mesmo laboratório.
        if code && LabExam.where(exam_provider_id: exam.exam_provider_id, active: true).where.not(id: exam.id)
                          .joins(:current_version).where("upper(lab_exam_versions.instrument_test_code) = ?", code).exists?
          next Result.fail(:duplicate_instrument_code)
        end

        exam.lock!
        number = exam.versions.maximum(:version).to_i + 1
        version = LabExamVersion.create!(lab_exam: exam, version: number, analysis_method: analysis_method, material: material, container: container,
                                         instrument_test_code: code, lab_instrument_id: raw_instrument, analytes: analytes.payload[:analytes], created_by_user: by)
        exam.update!(current_version: version)
        DomainEvents.publish("lab_exam.version_created", lab_exam_id: exam.id, version: number)
        Result.ok(version: version)
      end
    end
  end
end
