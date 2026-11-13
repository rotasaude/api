# Formas JSON da visita domiciliar (módulo 24b, ADR 0052; contrato §6, §7). Só
# o que a rota mostra: profissional por id, nome e CBO; nunca CNS.
module HomeVisits
  module Json
    DICTIONARIES = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")).fetch("home_visit").freeze

    module_function

    def professional(professional, cbo) = { id: professional.id, name: professional.professional_name, cbo: cbo }

    def micro_area(area) = { id: area.id, code: area.code, name: area.name }

    # <assignment> do GET /home_visits/assignments (§6). cbo: o do vínculo
    # ativo do profissional na equipe (nil se o vínculo acabou).
    def assignment(assignment, cbo:)
      json = { id: assignment.id, micro_area: micro_area(assignment.micro_area), professional: professional(assignment.professional, cbo),
               assigned_at: assignment.created_at.iso8601, assigned_by: { name: assignment.assigned_by_user.professional&.professional_name } }
      json[:ended_at] = assignment.ended_at.iso8601 if assignment.ended_at
      json
    end

    def candidate(member)
      { professional_id: member.professional.id, name: member.professional.professional_name, cbo: member.cbo_code }
    end

    # `context.domains` (§7, Q13): a forma `home_visit`, lida do YAML da task 1
    # (o mesmo que preenche o domains-v1.json do app). Códigos LEDI inteiros;
    # tipo de imóvel em texto, como o 24a grava (Q26).
    def domains = DOMAINS

    def build_domains
      domains = DICTIONARIES.fetch("domains")
      rules = DICTIONARIES.fetch("rules")
      groups = domains.fetch("motivo_visita_groups")
      {
        motivo_visita: domains.fetch("motivo_visita").map do |code, row|
          { code: code, label: row.fetch("label"), group: row.fetch("group"), group_label: groups.fetch(row.fetch("group")).fetch("group_label") }
        end,
        desfecho: labels(domains.fetch("desfecho")),
        turno: labels(domains.fetch("turno")),
        tipo_glicemia: labels(domains.fetch("tipo_glicemia")),
        tipo_de_imovel: TerritoryRegistry::Dictionary.domain("tipo_de_imovel").map { |code, label| { code: code.to_s, label: label } },
        non_residential_property_types: rules.fetch("non_residential_property_types"),
        non_residential_reasons: rules.fetch("non_residential_reasons"),
        male_forbidden_reasons: rules.fetch("male_forbidden_reasons"),
        without_person_allowed_reasons: rules.fetch("without_person_allowed_reasons"),
        responsible_document_reasons: rules.fetch("responsible_document_reasons"),
        reasons_max: rules.fetch("reasons_max"),
        measurement_ranges: DICTIONARIES.fetch("measurements").select { |_, row| row.key?("min") }.to_h do |key, row|
          [ key.to_sym, { min: row.fetch("min"), max: row.fetch("max"), decimals: row.fetch("decimals") } ]
        end
      }.freeze
    end

    def labels(rows) = rows.map { |code, label| { code: code, label: label } }

    DOMAINS = build_domains
    private_class_method :build_domains, :labels
  end
end
