# Formas JSON das linhas de cuidado (contrato §2). As do painel entram na Task 12.
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
  end
end
