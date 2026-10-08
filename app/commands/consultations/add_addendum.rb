# app/commands/consultations/add_addendum.rb
# Adendo de consulta finalizada (ADR 0031; spec §4; contrato §9; Desvio 6): só
# acréscimo, motivo 10–500, texto cifrado (1–20.000). O autor sempre (a
# abertura dele, se mandada e válida, fica registrada); outro profissional só
# com abertura justificada válida DELE para ESTE paciente. `changes`:
# `evaluated_problems` = eventos novos de problema; `conducts` e
# `exam_requests` = listas FINAIS (só entram em `changes` quando mudam). O
# banco recebe as diferenças como linhas novas (add/remove; requested/
# cancelled); a conduta efetiva nunca fica vazia. Tudo num savepoint.
module Consultations
  class AddAddendum
    CHANGE_KEYS = %w[evaluated_problems conducts exam_requests].freeze

    def self.call(consultation:, by:, reason:, text:, changes: nil, opening_id: nil)
      reason = reason.is_a?(String) ? reason.strip : ""
      unless reason.length.between?(ConsultationAddendum::MIN_REASON, ConsultationAddendum::MAX_REASON)
        return Result.fail(:invalid_reason)
      end
      return Result.fail(:text_required) unless text.is_a?(String) && text.strip.present?
      return Result.fail(:text_too_long, details: { field: "text" }) if text.length > Consultation::MAX_TEXT

      changes = normalize(changes)
      return Result.fail(:invalid_changes) unless changes

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        consultation.lock!
        next result = Result.fail(:not_finalized) unless consultation.finalized?

        patient = Patient.lock.find(consultation.patient_id)
        authorized = authorize(consultation, patient, by, opening_id)
        next result = authorized if authorized.failure?

        cbo, opening = authorized.payload.values_at(:cbo, :opening)
        plan = prepare(consultation, patient, cbo, changes)
        next result = plan if plan.failure?

        addendum = ConsultationAddendum.create!(consultation: consultation, author_user: by, text: text, reason: reason,
                                                item_changes: plan.payload[:stored], opening: opening)
        failure = apply!(consultation, patient, addendum, plan.payload, by)
        if failure
          result = failure
          raise ActiveRecord::Rollback
        end
        DomainEvents.publish("consultation.addendum_added", consultation_id: consultation.id, addendum_id: addendum.id)
        result = Result.ok(addendum: addendum, structured: plan.payload[:stored].any?)
      end
      result
    end

    def self.normalize(changes)
      changes = changes.to_unsafe_h if changes.respond_to?(:to_unsafe_h)
      return {} if changes.nil?
      return nil unless changes.is_a?(Hash)

      changes = changes.deep_stringify_keys
      (changes.keys - CHANGE_KEYS).empty? ? changes : nil
    end

    def self.authorize(consultation, patient, by, opening_id)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      opening = opening_id.is_a?(String) && ClinicalRecordOpening.valid_for(user_id: by.id, patient_id: patient.id).find_by(id: opening_id)
      return Result.ok(cbo: consultation.cbo_code, opening: opening || nil) if consultation.author_user_id == by.id
      return Result.fail(:opening_required) unless opening

      status, link = Authorization.any_allowed_link(user: by)
      status == :ok ? Result.ok(cbo: link.cbo_code, opening: opening) : Result.fail(status)
    end

    # Valida tudo antes de gravar; devolve as diferenças a gravar e o que fica em `changes`.
    def self.prepare(consultation, patient, cbo, changes)
      today = Time.zone.today
      effective = Effective.call(consultation)
      stored = {}
      plan = { problems: [], conducts_added: [], conducts_removed: [], exams_added: [], exams_removed: [] }

      if changes.key?("evaluated_problems")
        problems = ItemsInput.problems(changes["evaluated_problems"], patient: patient, cbo: cbo, on: today)
        return problems if problems.failure?

        plan[:problems] = problems.payload[:items]
        stored["evaluated_problems"] = plan[:problems] if plan[:problems].any?
      end

      if changes.key?("conducts")
        conducts = ItemsInput.conducts(changes["conducts"])
        return conducts if conducts.failure?

        final = conducts.payload[:items]
        return Result.fail(:no_conduct) if final.empty?

        plan[:conducts_added] = final - effective[:conducts]
        plan[:conducts_removed] = effective[:conducts] - final
        stored["conducts"] = final if (plan[:conducts_added] + plan[:conducts_removed]).any?
      end

      if changes.key?("exam_requests")
        kept = effective[:exam_requests].map { |row| [ row.sigtap_code, row.cid10_justification ] }
        exams = ItemsInput.exams(changes["exam_requests"], cbo: cbo, on: today, kept: kept)
        return exams if exams.failure?

        final = exams.payload[:items]
        current = effective[:exam_requests].to_h { |row| [ row.sigtap_code, row.cid10_justification ] }
        wanted = final.to_h { |e| [ e["sigtap_code"], e["cid10_justification"] ] }
        plan[:exams_removed] = current.keys.select { |code| !wanted.key?(code) || wanted[code] != current[code] }
        plan[:exams_added] = final.select { |e| !current.key?(e["sigtap_code"]) || plan[:exams_removed].include?(e["sigtap_code"]) }
        stored["exam_requests"] = final if (plan[:exams_added] + plan[:exams_removed]).any?
      end

      Result.ok(plan.merge(stored: stored))
    end

    # Devolve nil, ou o Result de falha (problema mudou desde a validação).
    def self.apply!(consultation, patient, addendum, plan, by)
      plan[:problems].each_with_index do |item, index|
        applied = Patients::ApplyProblemEvent.call(
          patient: patient, action: item["action"], by: by, source: { addendum: addendum },
          terminology: item["terminology"], code: item["code"], release_id: item["release_id"],
          problem: item["problem_id"] && PatientProblem.find_by(id: item["problem_id"]),
          onset_on: item["onset_on"] && Date.iso8601(item["onset_on"]), onset_precision: item["onset_precision"]
        )
        return Result.fail(applied.reason, details: { index: index }) if applied.failure?

        Finalize.record_problem!(consultation, applied.payload[:problem], item["action"], addendum: addendum)
      end
      plan[:conducts_added].each { |code| ConsultationConduct.create!(consultation: consultation, addendum: addendum, code: code, action: "add") }
      plan[:conducts_removed].each { |code| ConsultationConduct.create!(consultation: consultation, addendum: addendum, code: code, action: "remove") }
      plan[:exams_removed].each do |code|
        previous = consultation.exam_requests.where(sigtap_code: code, status: "requested").order(:created_at, :id).last
        ConsultationExamRequest.create!(consultation: consultation, addendum: addendum, sigtap_code: code,
                                        sigtap_competence: previous.sigtap_competence, status: "cancelled")
      end
      plan[:exams_added].each do |exam|
        ConsultationExamRequest.create!(consultation: consultation, addendum: addendum, sigtap_code: exam["sigtap_code"],
                                        sigtap_competence: exam["sigtap_competence"],
                                        cid10_justification: exam["cid10_justification"], status: "requested")
      end
      nil
    end
    private_class_method :normalize, :authorize, :prepare, :apply!
  end
end
