# Requisitos da finalização da consulta odontológica (ADR 0046; contrato §4,
# §16 O6, O7, O8, O22; Desvios 2, 6, 7, 8, 10): todas as recusas de uma vez,
# `[ { path:, error: } ]` com o caminho do corpo. Fora do registro inicial:
# tipo de atendimento, vigilância, tipo de consulta, desfechos, gestante,
# problema avaliado (FAO exige CID-10 ou CIAP-2; TSB/ASB só CIAP-2) e "A ou P"
# (O8); o papel do autor (TSB/ASB); limites de quantidade por SIGTAP; o plano
# da unidade da consulta (item de outro plano → plan_item_not_open). O
# registro inicial: achados e nada mais. O desfecho do atendimento fica com o
# Attendances::Close. Quem chama já travou consulta, paciente e planos.
# `regulating` (care_regulation utilizável, lido fora da transação): o pedido
# exigido pelos desfechos 1–9 vem do DentalCare::Referrals (Task 10).
module DentalCare
  module Requirements
    TYPED = [ Catalog::FIRST, Catalog::RETURN ].freeze

    module_function

    def call(consultation, patient, regulating: false)
      dental = consultation.draft_items["dental"] || {}
      return baseline(consultation, dental) if consultation.baseline

      problems = []
      add = ->(path, error, **extra) { problems << { path: path, error: error, **extra } }
      fao(consultation, patient, add)
      record(consultation, patient, add)
      auxiliary(consultation, dental, add) if Consultations::Cbos.role(consultation.cbo_code) == :auxiliary
      limits(dental, add)
      taken(dental, add)
      prosthesis(dental, patient, add)
      plan(consultation, dental, add, auxiliary: Consultations::Cbos.role(consultation.cbo_code) == :auxiliary)
      problems.concat(Referrals.missing(consultation)) if regulating
      problems
    end

    def baseline(consultation, dental)
      problems = []
      problems << { path: "dental.findings", error: "baseline_requires_findings" } if Array(dental["findings"]).empty?
      present = {
        "dental.care_type" => !consultation.care_type.nil?,
        "dental.dental_consultation_type" => !consultation.dental_consultation_type.nil?,
        "dental.oral_health_surveillance" => consultation.oral_health_surveillance.any?,
        "dental.supplies" => consultation.supplies.any?,
        "dental.dental_outcomes" => consultation.dental_outcomes.any?,
        "dental.procedures" => Array(dental["procedures"]).any?,
        "dental.plan_changes" => plan_changes?(dental),
        "dental.periodontal_screening" => !dental["periodontal_screening"].nil?,
        "dental.periodontal_chart" => !dental["periodontal_chart"].nil?,
        "dental.endodontics" => Array(dental["endodontics"]).any?,
        "regulation_requests" => regulation_drafts?(consultation)
      }
      problems + present.select { |_, value| value }.keys.map { |path| { path: path, error: "baseline_only_findings" } }
    end

    def fao(consultation, patient, add)
      care_type = consultation.care_type
      type = consultation.dental_consultation_type
      outcomes = consultation.dental_outcomes
      add.("dental.care_type", "care_type_required") if care_type.nil?
      add.("dental.oral_health_surveillance", "oral_health_surveillance_required") if consultation.oral_health_surveillance.empty?
      add.("dental.dental_consultation_type", "dental_consultation_type_required") if care_type == Catalog::CARE_TYPE_SCHEDULED && type.nil?
      add.("dental.dental_consultation_type", "dental_consultation_type_forbidden") if care_type == Catalog::CARE_TYPE_ORIENTATION && type
      if care_type == Catalog::CARE_TYPE_URGENCY && type == Catalog::RETURN
        add.("dental.dental_consultation_type", "return_forbidden_on_urgency")
      end
      add.("dental.dental_outcomes", "dental_outcome_required") if outcomes.empty?
      outcomes.each_with_index do |code, index|
        path = "dental.dental_outcomes[#{index}]"
        add.(path, "completed_requires_first_or_return") if code == Catalog::COMPLETED && !TYPED.include?(type)
        add.(path, "discharge_forbidden_with_first_or_return") if code == Catalog::DISCHARGE && TYPED.include?(type)
      end
      sex = patient.sex.to_s
      add.("dental.pregnant", "pregnant_required") if sex == "female" && consultation.pregnant.nil?
      add.("dental.pregnant", "pregnant_forbidden_male") if sex == "male" && consultation.pregnant == true
    end

    # O8: problema (CID-10 do dentista ou CIAP-2; TSB/ASB só CIAP-2), "A ou P" e nome.
    def record(consultation, patient, add)
      problems = Array(consultation.draft_items["evaluated_problems"])
      problems = problems.select { |item| item["terminology"] == "ciap2" } if Consultations::Cbos.role(consultation.cbo_code) == :auxiliary
      add.("evaluated_problems", "problem_required") if problems.empty?
      add.("assessment", "assessment_or_plan_required") if consultation.assessment.blank? && consultation.plan.blank?
      add.("patient", "patient_name_missing") if patient.full_name.blank?
    end

    # Desvio 8: o TSB/ASB registra só a lista da cidade, não planeja nem encaminha.
    def auxiliary(consultation, dental, add)
      allowed = DentalAuxiliaryProcedure.pluck(:procedure_code)
      Array(dental["procedures"]).each_with_index do |procedure, index|
        add.("dental.procedures[#{index}].sigtap", "auxiliary_procedure_not_allowed") unless allowed.include?(procedure["sigtap"])
      end
      add.("dental.periodontal_chart", "auxiliary_procedure_not_allowed") unless dental["periodontal_chart"].nil?
      add.("dental.endodontics", "auxiliary_procedure_not_allowed") if Array(dental["endodontics"]).any?
      add.("dental.plan_changes", "auxiliary_cannot_plan") if plan_changes?(dental)
      consultation.dental_outcomes.each_with_index do |code, index|
        add.("dental.dental_outcomes[#{index}]", "auxiliary_cannot_refer") if Catalog::REFERRAL_OUTCOMES.include?(code)
        # O 15 conclui o plano: o TSB/ASB não planeja.
        add.("dental.dental_outcomes[#{index}]", "auxiliary_cannot_plan") if code == Catalog::COMPLETED
      end
      add.("regulation_requests", "auxiliary_cannot_refer") if regulation_drafts?(consultation)
    end

    # Desvio 6: soma das quantidades por SIGTAP ≤ o máximo da lista do LEDI;
    # O32: no máximo MAX_PROCEDURE_CODES SIGTAP distintos (a FAO não leva mais).
    def limits(dental, add)
      sums = ProcedureLimits.sums(Array(dental["procedures"]).map { |p| p.values_at("sigtap", "quantity") })
      add.("dental.procedures", "too_many_procedure_codes") if sums.size > Catalog::MAX_PROCEDURE_CODES
      sums.each do |sigtap, total|
        add.("dental.procedures", "quantity_exceeds_location_limit", sigtap: sigtap) if total > ProcedureLimits.max(sigtap)
      end
    end

    # O id do procedimento vem do rascunho: um que já foi gravado (de outra
    # consulta, depois do autosave) é recusado, nunca um 500 da chave primária.
    def taken(dental, add)
      ids = Array(dental["procedures"]).map { |p| p["id"] }
      used = DentalProcedure.where(id: ids).pluck(:id)
      ids.each_with_index { |id, index| add.("dental.procedures[#{index}].id", "invalid_request") if used.include?(id) }
    end

    # Desvio 12 (D6): o procedimento com `prosthesis_order_id` instala o pedido
    # (trancado por quem chama): mesmo SIGTAP e paciente, e cada pedido uma vez
    # só (senão `prosthesis_order_mismatch`); só `received` instala
    # (senão `prosthesis_order_not_received`).
    def prosthesis(dental, patient, add)
      used = []
      Array(dental["procedures"]).each_with_index do |procedure, index|
        id = procedure["prosthesis_order_id"]
        next unless id

        path = "dental.procedures[#{index}].prosthesis_order_id"
        order = DentalProsthesisOrder.find_by(id: id)
        if order.nil? || order.patient_id != patient.id || order.procedure_code != procedure["sigtap"] || used.include?(id)
          add.(path, "prosthesis_order_mismatch")
        elsif order.stage != "received"
          add.(path, "prosthesis_order_not_received")
        end
        used << id
      end
    end

    # Desvio 7 (Ruling 14): o item tem de ser `planned` do plano aberto da
    # unidade da consulta (e do mesmo SIGTAP, na baixa).
    def plan(consultation, dental, add, auxiliary: false)
      plan = Plans.open_plan(consultation)
      planned = plan ? plan.items.where(status: "planned").pluck(:id, :procedure_code).to_h : {}
      changes = Plans.changes(consultation)
      used = []
      Array(dental["procedures"]).each_with_index do |procedure, index|
        id = procedure["plan_item_id"]
        next unless id

        add.("dental.procedures[#{index}].plan_item_id", "plan_item_not_open") unless planned[id] == procedure["sigtap"] && !used.include?(id)
        used << id
      end
      changes["cancel"].each_with_index do |item, index|
        id = item["item_id"]
        add.("dental.plan_changes.cancel[#{index}].item_id", "plan_item_not_open") unless planned.key?(id) && !used.include?(id)
        used << id
      end
      add.("dental.plan_changes.cancel_plan", "plan_item_not_open") if changes["cancel_plan"] && plan.nil?
      # O30: cancelar e concluir o plano na mesma consulta não combinam.
      if changes["cancel_plan"] && consultation.dental_outcomes.include?(Catalog::COMPLETED)
        add.("dental.plan_changes.cancel_plan", "cancel_plan_conflicts_with_completed")
      end
      if changes["add"].any? && plan.nil? && !Plans.opens_plan?(consultation)
        add.("dental.plan_changes.add", "plan_requires_first_consultation")
      end
      # O38: o 15 só com o plano sem item `planned` depois do rascunho (mesma regra
      # do suggest_completed: acréscimos contam; baixas e cancelamentos descontam).
      pending = (planned.keys - used).size + changes["add"].size
      if pending.positive? && !changes["cancel_plan"] && !auxiliary # o auxiliar já recebe auxiliary_cannot_plan
        consultation.dental_outcomes.each_with_index do |code, index|
          add.("dental.dental_outcomes[#{index}]", "plan_items_pending") if code == Catalog::COMPLETED
        end
      end
    end

    def plan_changes?(dental)
      changes = dental["plan_changes"] || {}
      Array(changes["add"]).any? || Array(changes["cancel"]).any? || !changes["cancel_plan"].nil?
    end

    def regulation_drafts?(consultation) = RegulationRequest.exists?(consultation_id: consultation.id, status: "draft")
    private_class_method :baseline, :fao, :record, :auxiliary, :limits, :taken, :prosthesis, :plan, :plan_changes?, :regulation_drafts?
  end
end
