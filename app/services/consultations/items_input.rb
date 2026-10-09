# app/services/consultations/items_input.rb
# Corpo do autosave (e do adendo) → colunas e itens normalizados (ADR 0031;
# spec §4; contratos §4; Task 1). Só as chaves presentes mudam; texto clínico
# fica como veio (vazio = nil); sinais com o validador do módulo 18 (pressão
# incompleta = implausible_vital com o lado que falta); itens contra a release
# ativa. Nunca levanta: entrada ruim vira Result.fail com field/index.
module Consultations
  module ItemsInput
    MAX_PROBLEMS = 50
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    def call(params, patient:, cbo:, on: Time.zone.today)
      params = normalize(params)
      attrs = {}
      items = {}

      Consultation::TEXT_FIELDS.each do |field|
        next unless params.key?(field)

        value = params[field]
        return Result.fail(:invalid_text, details: { field: field }) unless value.nil? || value.is_a?(String)
        return Result.fail(:text_too_long, details: { field: field }) if value.to_s.length > Consultation::MAX_TEXT

        attrs[field] = value.presence && (value.strip.empty? ? nil : value)
      end

      if params.key?("vitals")
        vitals = vitals(params["vitals"])
        return vitals if vitals.failure?

        attrs.merge!(vitals.payload)
      end

      if params.key?("care_type")
        value = params["care_type"].nil? ? nil : Ledi::ConsultationMapping.code(params["care_type"])
        return Result.fail(:invalid_care_type) unless params["care_type"].nil? || Ledi::ConsultationMapping.care_type?(value)

        attrs["care_type"] = value
      end

      { "evaluated_problems" => -> { problems(params["evaluated_problems"], patient: patient, cbo: cbo, on: on) },
        "conducts" => -> { conducts(params["conducts"]) },
        "exam_requests" => -> { exams(params["exam_requests"], cbo: cbo, on: on) } }.each do |key, check|
        next unless params.key?(key)

        result = check.call
        return result if result.failure?

        items[key] = result.payload[:items]
      end

      Result.ok(attrs: attrs, draft_items: items)
    end

    def vitals(raw)
      parsed = Screenings::VitalSigns.parse(raw)
      if parsed.failure?
        return parsed unless parsed.reason == :bp_incomplete

        side = raw.is_a?(Hash) && raw.transform_keys(&:to_s)["systolic"].to_s.strip.present? ? "diastolic" : "systolic"
        return Result.fail(:implausible_vital, details: { field: side })
      end
      Result.ok(Consultation::VITAL_COLUMNS.to_h { |column| [ column, parsed.payload[:values][column] ] })
    end

    def problems(list, patient:, cbo:, on:)
      return fail_index(:invalid_problem, nil) unless list.is_a?(Array) && list.size <= MAX_PROBLEMS

      seen = []
      items = list.each_with_index.map do |raw, index|
        item = problem(raw, patient: patient, cbo: cbo, on: on, index: index)
        return item if item.is_a?(Result)

        key = item["problem_id"] || [ item["terminology"], item["code"] ]
        return fail_index(:invalid_problem, index) if seen.include?(key)

        seen << key
        item
      end
      Result.ok(items: items)
    end

    # Códigos como string de dígitos ou inteiro; a lista sai em inteiros.
    def conducts(list)
      return Result.fail(:invalid_conduct) unless list.is_a?(Array)

      codes = list.map { |code| Ledi::ConsultationMapping.code(code) }
      valid = codes.size <= Ledi::ConsultationMapping.max_conducts && codes.uniq.size == codes.size &&
              codes.all? { |code| Ledi::ConsultationMapping.conduct?(code) }
      valid ? Result.ok(items: codes) : Result.fail(:invalid_conduct)
    end

    # `kept`: pares [sigtap_code, cid10] já vigentes (adendo) — o não médico
    # mantém a justificativa CID-10 que já existe, só não põe nova.
    def exams(list, cbo:, on:, kept: [])
      return fail_index(:invalid_exam, nil) unless list.is_a?(Array) && list.size <= Ledi::ConsultationMapping.max_exams

      seen = []
      items = list.each_with_index.map do |raw, index|
        raw = normalize(raw)
        exam = ClinicalTerms::SigtapExams.find(raw["sigtap_code"], on: on)
        return fail_index(:invalid_exam, index) if exam.nil? || seen.include?(exam.code)

        seen << exam.code
        justification = nil
        if raw["cid10_justification"].present?
          cid = ClinicalTerms.find("cid10", raw["cid10_justification"])
          return fail_index(:invalid_exam, index) unless cid
          unless Ledi::ConsultationMapping.cid10_allowed?(cbo) || kept.include?([ exam.code, cid.code ])
            return fail_index(:cid10_not_allowed_for_cbo, index)
          end

          justification = cid.code
        end
        { "sigtap_code" => exam.code, "sigtap_competence" => exam.competence, "cid10_justification" => justification }
      end
      Result.ok(items: items)
    end

    def problem(raw, patient:, cbo:, on:, index:)
      return fail_index(:invalid_problem, index) unless raw.is_a?(Hash) || raw.respond_to?(:to_unsafe_h)

      raw = normalize(raw)
      action = raw["action"].to_s
      return fail_index(:invalid_problem, index) unless Patients::ApplyProblemEvent::ACTIONS.include?(action)

      onset = onset(raw, patient: patient, on: on, required: action == "correct_onset")
      return fail_index(:invalid_onset, index) if onset == :invalid

      if action == "add"
        terminology = raw["terminology"].to_s
        code = ClinicalTerms.find(terminology, raw["code"])
        return fail_index(:invalid_problem, index) unless code

        if terminology == "cid10"
          return fail_index(:cid10_not_allowed_for_cbo, index) unless Ledi::ConsultationMapping.cid10_allowed?(cbo)

          sex = ClinicalTerms.cid10_sex(code.code, code.release_id)
          return fail_index(:cid10_sex_incompatible, index) if sex && Terminology::Sigtap::SEX[patient.sex.to_s] != sex
        end
        return item(nil, terminology, code.code, code.release_id, action, onset)
      end

      found = raw["problem_id"].is_a?(String) && PatientProblem.find_by(id: raw["problem_id"], patient_id: patient.id)
      return fail_index(:invalid_problem, index) unless found
      return fail_index(:invalid_problem, index) if action == "resolve" && !found.active?

      item(found.id, found.terminology, found.code, found.terminology_release_id, action, onset)
    end

    # nil (sem início) | [Date, precisão] | :invalid. Precisão mês/ano grava o
    # primeiro dia; nunca no futuro nem antes do nascimento (dataInicioProblema).
    def onset(raw, patient:, on:, required:)
      date, precision = raw["onset_on"], raw["onset_precision"]
      return (required ? :invalid : nil) if date.nil? && precision.nil?
      return :invalid unless date.is_a?(String) && date.match?(DATE) && PatientProblem::PRECISIONS.include?(precision)

      parsed = Date.iso8601(date)
      parsed = parsed.beginning_of_month if precision == "month"
      parsed = parsed.beginning_of_year if precision == "year"
      birth = patient.birth_date.present? ? Date.iso8601(patient.birth_date) : nil
      floor = birth && { "day" => birth, "month" => birth.beginning_of_month, "year" => birth.beginning_of_year }.fetch(precision)
      return :invalid if parsed > on || (floor && parsed < floor)

      [ parsed, precision ]
    rescue Date::Error
      :invalid
    end

    def item(problem_id, terminology, code, release_id, action, onset)
      { "problem_id" => problem_id, "terminology" => terminology, "code" => code, "release_id" => release_id,
        "action" => action, "onset_on" => onset&.first&.iso8601, "onset_precision" => onset&.last }
    end

    def normalize(params)
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      params.is_a?(Hash) ? params.deep_stringify_keys : {}
    end

    def fail_index(reason, index) = Result.fail(reason, details: { index: index }.compact)
    private_class_method :vitals, :problem, :onset, :item, :normalize, :fail_index
  end
end
