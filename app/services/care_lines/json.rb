# Formas JSON das linhas de cuidado (contrato §2, com §11 e §12).
module CareLines
  module Json
    module_function

    # §11 T5: latest_template_version — a maior versão da chave no catálogo-base
    # (nil na linha própria). `latest` vem de uma consulta só (AdminController).
    def line(line, latest: nil)
      { id: line.id, name: line.name, source: line.source, template_key: line.template_key, template_version: line.template_version,
        indicator: line.indicator, eligibility: line.eligibility, practices: line.practices, declared_condition: line.declared_condition,
        active: line.active, latest_template_version: line.template? ? latest&.fetch(line.template_key, nil) : nil }
    end

    def template(template)
      { key: template.key, version: template.version, name: template.name, indicator: template.indicator,
        declared_condition: template.declared_condition, eligibility: template.eligibility, practices: template.practices }
    end

    def line_summary(line) = { id: line.id, name: line.name, indicator: line.indicator, requires_anchor: line.eligibility["requires_anchor"] }

    def team(team)
      { id: team.id, ine: team.ine, name: team.name, unit: { id: team.health_unit_id, name: team.health_unit.name } }
    end

    # Painel e sugestões (contrato §2, §4, §5; §11 L5, L12; §12 P3).
    def person(patient: nil, citizen: nil, today: Time.zone.today)
      who = patient || citizen
      { patient_id: patient&.id, citizen_id: patient ? nil : citizen&.id, display_name: who&.display_name, age: who&.age(on: today) }
    end

    # §12 P3: a tela sabe, pela linha, se o aceite pede DUM.
    def line_ref(line) = { id: line.id, name: line.name, requires_anchor: line.eligibility["requires_anchor"] }

    def practice(status)
      { key: status.key, label: status.label, status: status.status, done_at: status.done_at&.iso8601, due_on: status.due_on&.iso8601,
        count: status.count, expected: status.expected }
    end

    # last_contact sem nota (§11 L12); a nota só no histórico do detalhe.
    def enrollment(enrollment, row:, last_contact:, today: Time.zone.today)
      { id: enrollment.id, person: person(patient: enrollment.patient, today: today), care_line: line_ref(enrollment.care_line),
        team: { id: enrollment.team.id, ine: enrollment.team.ine, name: enrollment.team.name },
        anchor_date: enrollment.anchor_date, status: enrollment.status, enrolled_at: enrollment.enrolled_at.iso8601,
        ended_reason: enrollment.ended_reason, ended_at: enrollment.ended_at&.iso8601,
        worst_status: row.worst, practices: row.practices.map { |s| practice(s) },
        last_contact: last_contact && { channel: last_contact.channel, outcome: last_contact.outcome, at: last_contact.recorded_at.iso8601 } }
    end

    # User não tem nome: o de quem registrou vem do perfil profissional.
    def contact(contact)
      { id: contact.id, channel: contact.channel, outcome: contact.outcome, note: contact.note,
        recorded_by: { id: contact.recorded_by_user_id, name: contact.recorded_by_user.professional&.professional_name },
        recorded_at: contact.recorded_at.iso8601 }
    end

    # Sem texto clínico: reason é só o código (§4).
    def suggestion(suggestion, today: Time.zone.today)
      { id: suggestion.id, person: person(patient: suggestion.patient, citizen: suggestion.citizen, today: today),
        care_line: line_ref(suggestion.care_line), team_id: suggestion.team_id, reason: suggestion.reason,
        created_at: suggestion.created_at.iso8601, enrollment_id: suggestion.enrollment_id }
    end
  end
end
