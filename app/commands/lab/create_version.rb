# Nova versão do exame (contrato §3): nunca edita a vigente. O código do
# aparelho é único (sem diferença de caixa) entre as versões VIGENTES dos exames
# ATIVOS do laboratório (trava do prestador). Com aparelho (C-E35), trava o
# APARELHO (FOR SHARE) antes do exame: a FK da versão toma FOR KEY SHARE no
# aparelho, e o lote em uso trava aparelho → exame. Sem aparelho, como no 21b.
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

      # ADR 0038: aparelho do mesmo laboratório, ativo (ou nenhum). C-E44: chave
      # AUSENTE herda o aparelho da versão vigente (desligar o CIQ não pode soltar
      # o vínculo em silêncio); `null` explícito desvincula.
      inherit = !params.key?("lab_instrument_id")
      base_version_id = exam.current_version_id
      raw_instrument = inherit ? exam.current_version&.lab_instrument_id : params["lab_instrument_id"]
      unless inherit || raw_instrument.nil?
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

        if raw_instrument
          instrument = LabInstrument.lock("FOR SHARE").find_by(id: raw_instrument, exam_provider_id: exam.exam_provider_id)
          # O herdado fica como está (mesmo inativo); o enviado precisa estar ativo.
          next Result.fail(:invalid_version) unless instrument && (inherit || instrument.active)
        end

        exam.lock!
        # Herdou de uma vigente que mudou entre a leitura e a trava: recusa em vez de
        # travar o aparelho depois do exame (ordem aparelho → exame, C-E35).
        next Result.fail(:conflict) if inherit && exam.current_version_id != base_version_id
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
