# app/services/consultations/json.rb
# A forma <consultation> (contratos §4). Rascunho: itens de draft_items;
# finalizada: os itens gravados na finalização (os dos adendos ficam em
# `addenda[].changes`). Rótulos da release gravada; sinais como no módulo 18
# (número como número, IMC calculado). Opcionais só aparecem com valor.
module Consultations
  module Json
    module_function

    def consultation(c)
      { id: c.id, attendance_id: c.attendance_id, patient_id: c.patient_id, status: c.status,
        author: { id: c.author_user_id, name: Screenings::Json.staff_name(c.author_user) }, cbo_code: c.cbo_code,
        subjective: c.subjective, objective: c.objective, assessment: c.assessment, plan: c.plan, vitals: vitals(c),
        care_type: c.care_type&.to_s, evaluated_problems: evaluated_problems(c), conducts: conducts(c),
        exam_requests: exam_requests(c), started_at: c.started_at.iso8601, finalized_at: c.finalized_at&.iso8601,
        addenda: c.addenda.order(:created_at, :id).map { |a| addendum(a) } }
    end

    def addendum(a)
      { id: a.id, author_name: Screenings::Json.staff_name(a.author_user), created_at: a.created_at.iso8601,
        reason: a.reason, text: a.text, changes: changes(a.item_changes) }
    end

    # Mesma forma dos itens da consulta (rótulo, opcionais só com valor,
    # conduta como string); só as chaves que o adendo mudou.
    def changes(stored)
      exams = ->(list) { list.map { |e| e.values_at("sigtap_code", "sigtap_competence", "cid10_justification") } }
      { "evaluated_problems" => -> { problem_list(stored["evaluated_problems"]) },
        "conducts" => -> { stored["conducts"].map(&:to_s) },
        "exam_requests" => -> { exam_list(exams.(stored["exam_requests"])) } }
        .select { |key, _| stored.key?(key) }.transform_values(&:call)
    end

    # Item das listas de finalizadas ("minhas consultas" e a administrativa):
    # sem conteúdo clínico; nome social se houver; código como string.
    def list_item(c)
      { id: c.id, finalized_at: c.finalized_at.iso8601, patient: { id: c.patient_id, display_name: c.patient.display_name },
        care_type: c.care_type&.to_s, care_type_label: Ledi::ConsultationMapping.care_type_label(c.care_type),
        health_unit: { id: c.attendance.health_unit_id, name: c.attendance.health_unit.name } }
    end

    def summary(c)
      { id: c.id, finalized_at: c.finalized_at&.iso8601, author_name: Screenings::Json.staff_name(c.author_user),
        cbo_label: Professionals::Cbo.find(c.cbo_code)&.title, care_type_label: Ledi::ConsultationMapping.care_type_label(c.care_type),
        problems: evaluated_problems(c), addenda_count: c.addenda.size }
    end

    def evaluated_problems(c)
      if c.draft?
        problem_list(c.draft_items["evaluated_problems"])
      else
        c.problem_items.where(addendum_id: nil).order(:created_at, :id).map do |row|
          problem_item(row.patient_problem_id, row.terminology, row.code, row.terminology_release_id, row.action,
                       row.onset_on&.iso8601, row.onset_precision)
        end
      end
    end

    def vitals(c) = Screenings::VitalSigns.json(c.vitals).merge("bmi" => Screenings::VitalSigns.bmi(c.vitals)).compact

    # Contrato §4: códigos como string (guardados como inteiro).
    def conducts(c)
      codes = c.draft? ? Array(c.draft_items["conducts"]) : c.conducts.where(addendum_id: nil).order(:created_at, :id).pluck(:code)
      codes.map(&:to_s)
    end

    def exam_requests(c)
      rows = if c.draft?
               Array(c.draft_items["exam_requests"]).map { |e| e.values_at("sigtap_code", "sigtap_competence", "cid10_justification") }
             else
               c.exam_requests.where(addendum_id: nil).order(:created_at, :id).pluck(:sigtap_code, :sigtap_competence, :cid10_justification)
             end
      exam_list(rows)
    end

    # Itens no formato de draft_items / item_changes (chaves string).
    def problem_list(items)
      Array(items).map do |i|
        problem_item(i["problem_id"], i["terminology"], i["code"], i["release_id"], i["action"], i["onset_on"], i["onset_precision"])
      end
    end

    def exam_list(rows)
      rows.map do |code, competence, cid|
        { sigtap_code: code, label: ClinicalTerms::SigtapExams.label(code, competence), cid10_justification: cid }.compact
      end
    end

    def problem_item(problem_id, terminology, code, release_id, action, onset_on, onset_precision)
      { problem_id: problem_id, terminology: terminology, code: code, label: ClinicalTerms.label(terminology, code, release_id),
        action: action, onset_on: onset_on, onset_precision: onset_precision }.reject { |k, v| v.nil? && %i[onset_on onset_precision].include?(k) }
    end
    private_class_method :changes, :vitals, :conducts, :exam_requests, :problem_list, :exam_list, :problem_item
  end
end
