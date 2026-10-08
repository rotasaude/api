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
        care_type: c.care_type, evaluated_problems: evaluated_problems(c), conducts: conducts(c),
        exam_requests: exam_requests(c), started_at: c.started_at.iso8601, finalized_at: c.finalized_at&.iso8601,
        addenda: c.addenda.order(:created_at, :id).map { |a| addendum(a) } }
    end

    def addendum(a)
      { id: a.id, author_name: Screenings::Json.staff_name(a.author_user), created_at: a.created_at.iso8601,
        reason: a.reason, text: a.text, changes: a.item_changes }
    end

    def summary(c)
      { id: c.id, finalized_at: c.finalized_at&.iso8601, author_name: Screenings::Json.staff_name(c.author_user),
        cbo_label: Professionals::Cbo.find(c.cbo_code)&.title, care_type_label: Ledi::ConsultationMapping.care_type_label(c.care_type),
        problems: evaluated_problems(c), addenda_count: c.addenda.size }
    end

    def evaluated_problems(c)
      if c.draft?
        Array(c.draft_items["evaluated_problems"]).map do |i|
          problem_item(i["problem_id"], i["terminology"], i["code"], i["release_id"], i["action"], i["onset_on"], i["onset_precision"])
        end
      else
        c.problem_items.where(addendum_id: nil).order(:created_at, :id).map do |row|
          problem_item(row.patient_problem_id, row.terminology, row.code, row.terminology_release_id, row.action,
                       row.onset_on&.iso8601, row.onset_precision)
        end
      end
    end

    def vitals(c) = Screenings::VitalSigns.json(c.vitals).merge("bmi" => Screenings::VitalSigns.bmi(c.vitals)).compact

    def conducts(c) = c.draft? ? Array(c.draft_items["conducts"]) : c.conducts.where(addendum_id: nil).order(:created_at, :id).pluck(:code)

    def exam_requests(c)
      rows = if c.draft?
               Array(c.draft_items["exam_requests"]).map { |e| e.values_at("sigtap_code", "sigtap_competence", "cid10_justification") }
             else
               c.exam_requests.where(addendum_id: nil).order(:created_at, :id).pluck(:sigtap_code, :sigtap_competence, :cid10_justification)
             end
      rows.map do |code, competence, cid|
        { sigtap_code: code, label: ClinicalTerms::SigtapExams.label(code, competence), cid10_justification: cid }.compact
      end
    end

    def problem_item(problem_id, terminology, code, release_id, action, onset_on, onset_precision)
      { problem_id: problem_id, terminology: terminology, code: code, label: ClinicalTerms.label(terminology, code, release_id),
        action: action, onset_on: onset_on, onset_precision: onset_precision }.reject { |k, v| v.nil? && %i[onset_on onset_precision].include?(k) }
    end
    private_class_method :vitals, :conducts, :exam_requests, :problem_item
  end
end
