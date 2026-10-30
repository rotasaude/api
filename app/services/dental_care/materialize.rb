# A finalização da consulta odontológica grava o rascunho (ADR 0046; contrato
# §4, §6; Desvios 5, 7): nesta ordem, procedimentos → eventos do odontograma →
# plano da unidade → registro periodontal → periograma → endodontia, tudo
# antes de a consulta virar finalized (os guardas aceitam item só no
# rascunho). Eventos: primeiro os achados, depois os efeitos dos
# procedimentos (DentalCare::SigtapSituations, com o odontograma já com os
# achados), um por um — o `seq` da gravação é a ordem da dobra (o procedimento
# vence o achado da mesma face). Procedimento sem efeito num dente gera evento
# só com o SIGTAP; em sextante, arcada ou boca, nenhum. Todos com
# `recorded_at` = agora e o CBO da consulta. Endodontia: a sessão entra no
# tratamento em andamento do dente (ou num novo, na unidade da consulta);
# `completed` o conclui. Quem chama travou atendimento, consulta, paciente e
# planos.
module DentalCare
  module Materialize
    module_function

    def call(consultation:, patient:, by:, now: Time.current)
      dental = consultation.draft_items["dental"] || {}
      procedures = Array(dental["procedures"]).map { |item| procedure!(consultation, patient, item) }
      install_prostheses!(procedures, consultation, by)
      event = event_writer(consultation, patient, by, now)
      Array(dental["findings"]).each { |finding| finding!(finding, event) }
      chart = Chart.call(patient)
      procedures.each { |procedure| effects!(procedure, chart, event) }
      Plans.apply!(consultation: consultation, by: by, procedures: procedures, now: now)
      screening!(consultation, patient, dental["periodontal_screening"])
      periodontal_chart!(consultation, patient, dental["periodontal_chart"])
      Array(dental["endodontics"]).each { |entry| endodontics!(consultation, patient, entry) }
      nil
    end

    # Adendo (Task 8): os achados viram eventos com o `addendum_id`, depois dos
    # da consulta (recorded_at = agora, seq): o achado corrigido vence. Quem
    # chama travou consulta e paciente.
    def addendum!(consultation:, patient:, addendum:, by:, findings:, now: Time.current)
      event = event_writer(consultation, patient, by, now, addendum: addendum)
      Array(findings).each { |finding| finding!(finding, event) }
    end

    def procedure!(consultation, patient, item)
      location = item.fetch("location")
      DentalProcedure.create!(id: item.fetch("id"), consultation: consultation, patient: patient, procedure_code: item.fetch("sigtap"),
                              location_kind: location["kind"], tooth: location["tooth"], face: location["face"],
                              sextant: location["sextant"], arch: location["arch"], quantity: item.fetch("quantity"),
                              dental_treatment_plan_item_id: item["plan_item_id"], dental_prosthesis_order_id: item["prosthesis_order_id"])
    end

    # Desvio 12: o procedimento com pedido de prótese o passa de `received` a
    # `installed` (a Requirements já recusou o resto; quem chama travou os pedidos).
    def install_prostheses!(procedures, consultation, by)
      procedures.filter_map(&:dental_prosthesis_order_id).each do |id|
        order = DentalProsthesisOrder.find(id)
        order.update!(stage: "installed", installed_in_consultation_id: consultation.id)
        order.stages.create!(stage: "installed", by_user: by)
        DomainEvents.publish("prosthesis_order.stage_changed", order_id: order.id, stage: "installed", user_id: by.id)
      end
    end

    def event_writer(consultation, patient, by, now, addendum: nil)
      lambda do |tooth:, part:, face:, situation:, procedure: nil|
        DentalChartEvent.create!(patient: patient, consultation: consultation, author_user: by, addendum: addendum, cbo_code: consultation.cbo_code,
                                 tooth: tooth, part: part, face: face, situation: situation, recorded_at: now,
                                 procedure_code: procedure&.procedure_code, dental_procedure: procedure)
      end
    end

    # A prótese total na arcada vira um evento de coroa por dente em que vale.
    def finding!(finding, event)
      if finding["arch"]
        teeth = Location.teeth({ kind: "arch", arch: finding["arch"] })
                        .select { |tooth| Situations.valid?(finding["situation"], part: "arch", tooth: tooth) }
        teeth.each { |tooth| event.(tooth: tooth, part: "crown", face: nil, situation: finding["situation"]) }
      else
        event.(tooth: finding["tooth"], part: finding["part"], face: finding["face"], situation: finding["situation"])
      end
    end

    def effects!(procedure, chart, event)
      location = { kind: procedure.location_kind, tooth: procedure.tooth, face: procedure.face, sextant: procedure.sextant,
                   arch: procedure.arch }
      effects = SigtapSituations.effects(procedure.procedure_code, location, chart: chart)
      if effects.empty?
        return unless %w[tooth face].include?(procedure.location_kind)

        effects = [ { tooth: procedure.tooth, part: "crown", face: procedure.face, situation: nil } ]
      end
      effects.each { |effect| event.(**effect, procedure: procedure) }
    end

    def screening!(consultation, patient, screening)
      return if screening.nil?

      screening.fetch("sextants").each do |row|
        PeriodontalScreening.create!(consultation: consultation, patient: patient, sextant: row["sextant"], code: row["code"], star: row["star"])
      end
    end

    def periodontal_chart!(consultation, patient, chart)
      return if chart.nil?

      chart.fetch("teeth").each do |row|
        record = PeriodontalChart.create!(consultation: consultation, patient: patient, tooth: row["tooth"], mobility: row["mobility"],
                                          furcation: row["furcation"])
        row.fetch("sites").each do |site|
          record.sites.create!(site: site["site"], probing_depth_mm: site["probing_depth_mm"], recession_mm: site["recession_mm"],
                               bleeding: site["bleeding"])
        end
      end
    end

    def endodontics!(consultation, patient, entry)
      completed = entry["status"] == "completed"
      treatment = EndodonticTreatment.lock.find_by(patient_id: patient.id, tooth: entry["tooth"], status: "in_progress")
      attrs = { canals: entry["canals"], status: entry["status"], completed_in_consultation: completed ? consultation : nil }
      if treatment
        treatment.update!(attrs)
      else
        treatment = EndodonticTreatment.create!(patient: patient, health_unit_id: consultation.attendance.health_unit_id, tooth: entry["tooth"],
                                                opened_in_consultation: consultation, **attrs)
      end
      treatment.sessions.create!(consultation: consultation, canals: entry["canals"])
    end
    private_class_method :procedure!, :install_prostheses!, :event_writer, :finding!, :effects!, :screening!, :periodontal_chart!, :endodontics!
  end
end
