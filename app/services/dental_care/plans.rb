# Plano de tratamento por unidade e episódio (ADR 0046; Desvio 7; contrato
# §16 O6, O26). No máximo um `open` por (paciente, unidade). Na finalização de
# consulta odontológica que não é o registro inicial, sem plano aberto na
# unidade da consulta, abre quando é a primeira consulta programática (UBS e
# demais) ou quando a unidade é CEO (primeira consulta no CEO). Depois, na
# ordem: acrescenta os itens, dá baixa nos itens dos procedimentos (`done`),
# cancela itens, cancela o plano inteiro (`cancel_plan`) ou, com o desfecho
# 15, conclui. O plano de outra unidade nunca muda por aqui (Review Focus 3).
# Eventos só com ids.
module DentalCare
  module Plans
    module_function

    # Os planos abertos do paciente, travados por id (ordem de travas da Finalize).
    def lock!(patient) = DentalTreatmentPlan.open_plans.where(patient_id: patient.id).order(:id).lock.to_a

    def unit_id(consultation) = consultation.attendance.health_unit_id

    def open_plan(consultation)
      DentalTreatmentPlan.open_plans.find_by(patient_id: consultation.patient_id, health_unit_id: unit_id(consultation))
    end

    # Abre um plano na finalização quando a unidade não tem plano aberto.
    def opens_plan?(consultation)
      return false if !consultation.dental? || consultation.baseline

      consultation.dental_consultation_type == Catalog::FIRST || consultation.attendance.health_unit.kind == "ceo"
    end

    def changes(consultation)
      { "add" => [], "cancel" => [], "cancel_plan" => nil }.merge(consultation.draft_items.dig("dental", "plan_changes") || {})
    end

    # `procedures`: os DentalProcedure gravados nesta finalização.
    def apply!(consultation:, by:, procedures:, now: Time.current)
      return if consultation.baseline

      plan = open_plan(consultation)
      if plan.nil? && opens_plan?(consultation)
        plan = DentalTreatmentPlan.create!(patient_id: consultation.patient_id, health_unit_id: unit_id(consultation), status: "open",
                                           opened_in_consultation: consultation)
      end
      return unless plan

      changes = changes(consultation)
      changes["add"].each do |item|
        location = item["location"]
        plan.items.create!(procedure_code: item["sigtap"], location_kind: location["kind"], tooth: location["tooth"],
                           face: location["face"], sextant: location["sextant"], arch: location["arch"], status: "planned",
                           added_in_consultation: consultation)
      end
      procedures.select(&:dental_treatment_plan_item_id).each do |procedure|
        plan.items.find(procedure.dental_treatment_plan_item_id).update!(status: "done", done_in_consultation: consultation)
      end
      changes["cancel"].each do |item|
        plan.items.find(item["item_id"]).update!(status: "cancelled", cancel_reason: item["reason"], cancelled_in_consultation: consultation)
      end
      if changes["cancel_plan"]
        close!(plan, consultation, by, now, "cancelled", cancel_reason: changes["cancel_plan"]["reason"])
      elsif consultation.dental_outcomes.include?(Catalog::COMPLETED)
        close!(plan, consultation, by, now, "completed")
      end
    end

    # Contrato §16 O26: plano aberto da unidade com pelo menos 1 item e nenhum
    # `planned` depois do rascunho (acréscimos contam; baixas e cancelamentos
    # do rascunho descontam). Finalizada: o estado gravado.
    def suggest_completed?(consultation)
      return false if !consultation.dental? || consultation.baseline || consultation.discarded?

      plan = open_plan(consultation)
      return false unless plan

      items = plan.items.pluck(:id, :status)
      return items.any? && items.none? { |_, status| status == "planned" } unless consultation.draft?

      changes = changes(consultation)
      return false if changes["cancel_plan"]

      closing = Array(consultation.draft_items.dig("dental", "procedures")).filter_map { |p| p["plan_item_id"] } +
                changes["cancel"].map { |c| c["item_id"] }
      planned = items.count { |id, status| status == "planned" && !closing.include?(id) } + changes["add"].size
      (items.size + changes["add"].size).positive? && planned.zero?
    end

    def close!(plan, consultation, by, now, status, cancel_reason: nil)
      plan.update!(status: status, cancel_reason: cancel_reason, closed_in_consultation: consultation, closed_by_user: by, closed_at: now)
      if status == "completed"
        DomainEvents.publish("dental_plan.completed", plan_id: plan.id, consultation_id: consultation.id)
      else
        DomainEvents.publish("dental_plan.cancelled", plan_id: plan.id, consultation_id: consultation.id)
      end
    end
    private_class_method :close!
  end
end
