# Caso compartilhado no matriciamento (ADR 0049; contrato §7, P12, P25): o
# texto que a UBS da equipe do matriciamento vê no vínculo do paciente com o
# CAPS (Psychosocial::Link). Campos (só o corpo JSON): `patient_id` (paciente
# existente) e `shared_text` (10..2000, cifrado; acima → too_long, abaixo →
# invalid_request). O autor é quem pede, lotado no CAPS do matriciamento (o
# controller confere). Recusas de campo todas de uma vez. Sem evento: o
# texto nunca sai do registro; a leitura pela UBS grava a trilha.
module Psychosocial
  module AddMatrixCase
    KEYS = %w[patient_id shared_text].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(matrix_case:) | fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(support:, attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }

      patient = Input.uuid?(attrs["patient_id"]) ? Patient.find_by(id: attrs["patient_id"].downcase) : nil
      problems << problem("patient_id") unless patient
      text = attrs["shared_text"]
      problems << Catalog.text_problem(text, Catalog::SHARED_TEXT, "shared_text")
      problems.compact!
      if problems.any?
        first = problems.first
        return Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
      end

      matrix_case = PsychosocialMatrixCase.create!(psychosocial_matrix_support: support, patient: patient, shared_text: text.strip,
                                                   created_by_user: by)
      Result.ok(matrix_case: matrix_case)
    end

    def problem(path) = { error: "invalid_request", path: path }

    private_class_method :problem
  end
end
