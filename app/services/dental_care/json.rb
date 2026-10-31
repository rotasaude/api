# O bloco `dental` da consulta odontológica (ADR 0046; contrato §2, §5, §6,
# §16 O14, O25, O26): <dental_fields> mais `suggest_completed`. Rascunho: das
# colunas e de draft_items["dental"]; finalizada: das tabelas (os eventos e
# itens dos adendos ficam de fora). Forma diferente entre os dois: o achado
# de arcada (`{ arch, situation: "complete_denture" }`) sai assim no rascunho,
# mas na finalizada vira um achado por dente (é o que os eventos guardam: um
# evento de coroa por dente da arcada). Códigos da FAO e dente em string; nome
# SIGTAP da release ativa na leitura. Dado clínico: só o corpo JSON.
module DentalCare
  module Json
    module_function

    def consultation(c)
      { care_type: c.care_type&.to_s, dental_consultation_type: c.dental_consultation_type&.to_s,
        oral_health_surveillance: c.oral_health_surveillance.map(&:to_s), supplies: c.supplies.map(&:to_s),
        dental_outcomes: c.dental_outcomes.map(&:to_s), pregnant: c.pregnant, special_needs: c.special_needs,
        **(c.finalized? ? stored(c) : draft(c)), suggest_completed: Plans.suggest_completed?(c) }
    end

    def draft(c)
      dental = c.draft_items["dental"] || {}
      changes = { "add" => [], "cancel" => [], "cancel_plan" => nil }.merge(dental["plan_changes"] || {})
      procedures = Array(dental["procedures"])
      names = names(procedures.map { |p| p["sigtap"] } + changes["add"].map { |a| a["sigtap"] })
      { procedures: procedures.map do |p|
          procedure(p["id"], p["sigtap"], names, p["location"], p["quantity"], p["plan_item_id"], p["prosthesis_order_id"])
        end,
        findings: Array(dental["findings"]).map { |f| finding(f["tooth"], f["face"], f["part"], f["arch"], f["situation"]) },
        plan_changes: { add: changes["add"].map { |a| { sigtap: a["sigtap"], name: names[a["sigtap"]], location: location(a["location"]) } },
                        cancel: changes["cancel"].map { |item| { item_id: item["item_id"], reason: item["reason"] } },
                        cancel_plan: changes["cancel_plan"] && { reason: changes["cancel_plan"]["reason"] } },
        periodontal_screening: screening(dental["periodontal_screening"]&.fetch("sextants")),
        periodontal_chart: perio(dental["periodontal_chart"]&.fetch("teeth")),
        endodontics: Array(dental["endodontics"]).map { |e| endo(e["tooth"], e["canals"], e["status"]) } }
    end

    # `changes.dental` do adendo (Task 8): só as partes que o adendo mudou.
    def addendum_changes(stored)
      out = {}
      out[:findings] = stored["findings"].map { |f| finding(f["tooth"], f["face"], f["part"], f["arch"], f["situation"]) } if stored["findings"]
      cancel = stored.dig("plan_changes", "cancel")
      out[:plan_changes] = { cancel: cancel.map { |i| { item_id: i["item_id"], reason: i["reason"] } } } if cancel
      out
    end

    def stored(c)
      rows = DentalProcedure.where(consultation_id: c.id).order(:created_at, :id).to_a
      added = DentalTreatmentPlanItem.where(added_in_consultation_id: c.id).order(:created_at, :id).to_a
      names = names(rows.map(&:procedure_code) + added.map(&:procedure_code))
      plan = DentalTreatmentPlan.find_by(closed_in_consultation_id: c.id, status: "cancelled")
      cancelled = DentalTreatmentPlanItem.where(cancelled_in_consultation_id: c.id).order(:created_at, :id).to_a
      # O31: os itens que o `cancel_plan` derrubou levam o motivo do plano e ficam
      # visíveis no próprio plano; aqui só os cancelamentos explícitos.
      cancelled = cancelled.reject { |i| plan && i.dental_treatment_plan_id == plan.id && i.cancel_reason == plan.cancel_reason } if plan
      findings = DentalChartEvent.where(consultation_id: c.id, addendum_id: nil, dental_procedure_id: nil).order(:recorded_at, :seq)
      screening = PeriodontalScreening.where(consultation_id: c.id).order(:sextant).map { |s| s.slice("sextant", "code", "star") }
      charts = PeriodontalChart.where(consultation_id: c.id).includes(:sites).order(:tooth).map do |chart|
        chart.slice("tooth", "mobility", "furcation").merge("sites" => chart.sites.sort_by(&:site).map do |s|
          s.slice("site", "probing_depth_mm", "recession_mm", "bleeding")
        end)
      end
      sessions = EndodonticSession.where(consultation_id: c.id).includes(:endodontic_treatment).order(:created_at, :id)
      { procedures: rows.map do |p|
          procedure(p.id, p.procedure_code, names, p.slice("location_kind", "tooth", "face", "sextant", "arch").transform_keys { |k| k == "location_kind" ? "kind" : k },
                    p.quantity, p.dental_treatment_plan_item_id, p.dental_prosthesis_order_id)
        end,
        findings: findings.map { |e| finding(e.tooth, e.face, e.part, nil, e.situation) },
        plan_changes: { add: added.map { |i| { sigtap: i.procedure_code, name: names[i.procedure_code], location: location(item_location(i)) } },
                        cancel: cancelled.map { |i| { item_id: i.id, reason: i.cancel_reason } },
                        cancel_plan: plan && { reason: plan.cancel_reason } },
        periodontal_screening: screening.empty? ? nil : screening(screening),
        periodontal_chart: charts.empty? ? nil : perio(charts),
        endodontics: sessions.map do |s|
          treatment = s.endodontic_treatment
          endo(treatment.tooth, s.canals, treatment.completed_in_consultation_id == c.id ? "completed" : "in_progress")
        end }
    end

    def procedure(id, sigtap, names, location, quantity, plan_item_id, prosthesis_order_id)
      { id: id, sigtap: sigtap, name: names[sigtap], location: location(location), quantity: quantity, plan_item_id: plan_item_id,
        prosthesis_order_id: prosthesis_order_id }
    end

    def finding(tooth, face, part, arch, situation) = { tooth: tooth&.to_s, face: face, part: part, arch: arch, situation: situation }

    # <location> (contrato §2): dente em string.
    def location(raw)
      { kind: raw["kind"], tooth: raw["tooth"]&.to_s, face: raw["face"], sextant: raw["sextant"], arch: raw["arch"] }
    end

    def item_location(item) = item.slice("tooth", "face", "sextant", "arch").merge("kind" => item.location_kind)

    def screening(rows) = rows && { sextants: rows.map { |s| { sextant: s["sextant"], code: s["code"], star: s["star"] } } }

    def perio(teeth)
      teeth && { teeth: teeth.map do |t|
        { tooth: t["tooth"].to_s, mobility: t["mobility"], furcation: t["furcation"],
          sites: t["sites"].map { |s| { site: s["site"], probing_depth_mm: s["probing_depth_mm"], recession_mm: s["recession_mm"], bleeding: s["bleeding"] } } }
      end }
    end

    def endo(tooth, canals, status) = { tooth: tooth.to_s, canals: canals, status: status }

    # Nome SIGTAP da release ativa (contrato §16 O14); sem release, nulo.
    def names(codes)
      release = ProcedureSearch.release
      return {} unless release && codes.any?

      SigtapProcedure.where(release_id: release.id, code: codes.uniq).pluck(:code, :name).to_h
    end
    # --- Leitura nominal do paciente (Task 7; contrato §2, §16 O13, O14, O25, O27) ---
    # Dado clínico: só o corpo JSON; quem chama grava a trilha.

    def unit_ref(unit) = { id: unit.id, name: unit.name, kind: unit.kind }

    def patient_ref(patient)
      { id: patient.id, display_name: patient.display_name, **Patients::IdentifierJson.call(patient) }
    end

    def odontogram(patient, chart, plans)
      { patient: patient_ref(patient), dentition: chart[:dentition],
        teeth: chart[:teeth].map do |t|
          { tooth: t[:tooth].to_s, situation: t[:situation], root: t[:root], faces: t[:faces],
            last_event_at: t[:last_event_at]&.iso8601, notes_count: t[:notes_count] }
        end,
        open_plans: plans.map { |plan| { id: plan.id, health_unit: unit_ref(plan.health_unit) } } }
    end

    # `names`: { sigtap => nome } (procedure_names) dos eventos mostrados.
    def chart_event(event, names:)
      { id: event.id, tooth: event.tooth.to_s, part: event.part, face: event.face, situation: event.situation,
        procedure: event.procedure_code && { sigtap: event.procedure_code, name: names[event.procedure_code] },
        consultation_id: event.consultation_id, addendum_id: event.addendum_id,
        by: { name: event.author_user.professional&.professional_name, cbo: event.cbo_code }, at: event.recorded_at.iso8601(6) }
    end

    def plan(plan, names:)
      { id: plan.id, health_unit: unit_ref(plan.health_unit), status: plan.status,
        opened_in_consultation_id: plan.opened_in_consultation_id, closed_in_consultation_id: plan.closed_in_consultation_id,
        items: plan.items.sort_by { |i| [ i.created_at, i.id ] }.map do |i|
          { id: i.id, sigtap: i.procedure_code, name: names[i.procedure_code], location: location(item_location(i)), status: i.status,
            done_in_consultation_id: i.done_in_consultation_id, cancel_reason: i.cancel_reason }
        end }
    end

    def endodontic_treatment(treatment)
      { id: treatment.id, tooth: treatment.tooth.to_s, canals: treatment.canals, status: treatment.status,
        health_unit: unit_ref(treatment.health_unit),
        sessions: treatment.sessions.sort_by { |s| [ s.created_at, s.id ] }.map do |s|
          { consultation_id: s.consultation_id, canals: s.canals, at: s.created_at.iso8601,
            by: { name: s.consultation.author_user.professional&.professional_name } }
        end }
    end

    # <prosthesis_order> (Desvio 12; O27): sem created_at e sem o motivo das etapas.
    def prosthesis_order(order, names:)
      provider = order.care_provider
      { id: order.id, patient: patient_ref(order.patient), health_unit: { id: order.health_unit.id, name: order.health_unit.name },
        sigtap: order.procedure_code, name: names[order.procedure_code],
        laboratory: { care_provider_id: order.care_provider_id, name: provider ? provider.name : order.laboratory_name },
        stage: order.stage,
        stages: order.stages.sort_by { |s| [ s.created_at, s.id ] }.map do |s|
          { stage: s.stage, at: s.created_at.iso8601, by: { name: s.by_user.professional&.professional_name } }
        end,
        installed_in_consultation_id: order.installed_in_consultation_id }
    end

    def procedure_names(codes) = names(codes)

    private_class_method :draft, :stored, :procedure, :finding, :location, :item_location, :screening, :perio, :endo, :names
  end
end
