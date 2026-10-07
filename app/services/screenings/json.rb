# app/services/screenings/json.rb
# Formas da escuta (contratos §3–§4). A recepção só recebe queue_block (cor,
# destino, espera) — nunca queixa nem sinais. Números saem como número
# (BigDecimal vira Float); chaves opcionais só aparecem quando há valor.
module Screenings
  module Json
    module_function

    def screening(screening, with_revisions: false)
      revision = screening.current_revision
      json = {
        id: screening.id, attendance_id: screening.attendance_id, status: screening.status,
        started_at: screening.started_at&.iso8601, completed_at: screening.completed_at&.iso8601,
        destination: screening.destination, current_revision: revision && revision(revision),
        revisions_count: screening.revisions.size
      }
      json[:orientation_note] = screening.orientation_note if screening.orientation_note
      json[:appointment_request_id] = screening.appointment_request_id if screening.appointment_request_id
      json[:revisions] = screening.revisions.order(:created_at, :id).map { |r| revision(r) } if with_revisions
      json
    end

    def revision(revision)
      vitals = revision.vitals
      json = {
        id: revision.id, created_at: revision.created_at.iso8601,
        by: { id: revision.by_user_id, name: staff_name(revision.by_user) },
        ciap2: { code: revision.ciap2_code, label: Ciap2.label(revision.ciap2_code, revision.ciap2_release_id) },
        vitals: VitalSigns.json(vitals).merge("bmi" => VitalSigns.bmi(vitals)).compact,
        alerts: VitalSigns.alerts(vitals), suggested_color: revision.suggested_color,
        final_color: revision.final_color, matched_rules: matched_rules(revision)
      }
      json[:complaint_note] = revision.complaint_note if revision.complaint_note
      json[:color_change_reason] = revision.color_change_reason if revision.color_change_reason
      json
    end

    # As regras que casaram na revisão, com o texto do protocolo que as avaliou.
    def matched_rules(revision)
      return [] if revision.matched_rules.blank?

      rules = ProtocolDefinition.find_by(id: revision.rule_protocol_definition_id)&.definition&.dig("risk_rules")
      matched_rules_for(revision.matched_rules, rules)
    end

    # Única tradução índice → frase da regra (revisão, suggest e simulador).
    # Índice sem regra (ou regra que não é objeto) vira "regra inválida".
    def matched_rules_for(indexes, rules)
      Array(indexes).map do |index|
        rule = Array(rules)[index]
        text = rule.is_a?(Hash) ? Protocols::ConditionText.call(rule["when"]) : Protocols::ConditionText::INVALID
        { index: index, text: text }
      end
    end

    def queue_item(attendance)
      screening = attendance.screening
      {
        attendance_id: attendance.id, citizen: { id: attendance.citizen_id, cpf_masked: attendance.citizen.cpf_masked },
        checked_in_at: attendance.checked_in_at.iso8601, triage_priority: attendance.priority,
        screening: screening && { id: screening.id, status: screening.status,
                                  started_by_name: staff_name(screening.started_by_user) }
      }
    end

    def queue_block(attendance, now: Time.current)
      screening = attendance.screening
      return nil unless screening&.completed? && screening.current_revision

      { id: screening.id, color: screening.current_revision.final_color, destination: screening.destination,
        waited_minutes: ((now - attendance.checked_in_at) / 60).floor }
    end

    # Como a fila do módulo 13 (F-10.5): nome profissional; sem perfil, o
    # e-mail. Única implementação (o AttendancesController passa a usar esta).
    def staff_name(user)
      return nil unless user

      user.professional&.professional_name || user.email_address
    end
  end
end
