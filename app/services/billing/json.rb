# Formas do contrato do módulo 22 (§2): <performed_procedure> e o resumo do
# atendimento/consulta. Rótulos SIGTAP memorizados por chamada (listas).
module Billing
  module Json
    module_function

    def procedures(list)
      labels = {}
      list.map { |p| procedure(p, labels: labels) }
    end

    def procedure(p, labels: {})
      { id: p.id, patient: { id: p.patient_id, display_name: p.patient.display_name }, establishment: Establishment.of(p).json,
        professional: { user_id: p.professional_user_id, name: Screenings::Json.staff_name(p.professional_user), cbo_code: p.cbo_code },
        performed_on: p.performed_on.iso8601, sigtap_code: p.sigtap_code, label: label(p, labels), sigtap_competence: p.sigtap_competence,
        quantity: p.quantity, cid10: p.cid10, character: p.character, source: p.source, source_ref: source_ref(p),
        instrument: p.instrument, billable: p.billable, blocking_reasons: p.blocking_reasons, status: p.status,
        cancel_reason: p.cancel_reason, billing_competence: p.billing_competence, late: p.late, sigtap_fallback: p.sigtap_fallback }
    end

    def summary(p, labels: {})
      { id: p.id, sigtap_code: p.sigtap_code, label: label(p, labels), quantity: p.quantity, performed_on: p.performed_on.iso8601,
        billable: p.billable, blocking_reasons: p.blocking_reasons, status: p.status }
    end

    # `procedures` do atendimento e da consulta (contrato §3), na ordem de gravação.
    def attached(scope)
      labels = {}
      scope.order(:created_at, :id).map { |p| summary(p, labels: labels) }
    end

    def source_ref(p)
      case p.source
      when "attendance" then { type: "attendance", id: p.attendance_id }
      when "consultation" then { type: "consultation", id: p.consultation_id }
      when "lab_report" then { type: "lab_report_item", id: p.lab_report_item_id }
      end
    end

    def label(p, labels) = labels[[ p.sigtap_code, p.sigtap_competence ]] ||= Labels.procedure(p.sigtap_code, p.sigtap_competence)
    # <billing_period> (contrato §2 com B11): id sempre; versão 0 antes do primeiro fechamento.
    def period(period)
      { id: period.id, establishment: Establishment.of(period).json, competence: period.competence, status: period.status,
        version: period.version, closed_at: period.closed_at&.iso8601, closed_by: Screenings::Json.staff_name(period.closed_by_user),
        reopened_reason: period.reopened_reason, summary: Summary.call(period) }
    end

    # Versão do arquivo (B9): `generated_by` é o nome.
    def export(export)
      { id: export.id, version: export.version, sha256: export.sha256, lines_bpa_i: export.lines_bpa_i, lines_bpa_c: export.lines_bpa_c,
        generated_at: export.generated_at.iso8601, generated_by: Screenings::Json.staff_name(export.generated_by_user) }
    end

    # Configuração (contrato §6 com B10): sem linha, nulls.
    def settings(setting)
      { origin_name: setting&.origin_name, origin_acronym: setting&.origin_acronym, origin_cnpj: setting&.origin_cnpj,
        destination_body: setting&.destination_body, management: setting&.management, updated_at: setting&.updated_at&.iso8601 }
    end

    private_class_method :source_ref, :label
  end
end
