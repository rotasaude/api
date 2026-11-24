# Referência offline do app de campo, GET /field/v1/reference (módulo 24c,
# ADR 0053; contrato §3.5; Q6, Q7, Q27, Q29): o que o app precisa para montar
# os formulários sem rede. Montada com as mesmas fontes que servem o dashboard
# (sem cópia de regra) e sem dado de cidadão; do profissional, só nome, CBO do
# vínculo e se tem CNS válido.
#
# O conteúdo depende só da cidade e das equipes do aparelho (nunca do usuário),
# e `reference_version` é o SHA-256 do JSON canônico (RFC 8785) do corpo sem
# ele: o app compara, nunca recalcula. O cache guarda só o hex.
#
# Módulo 35a (§13; Q6, Q8, Q15): `vector_control_domains` =
# VectorControl::Json.domains (o corpo de GET /vector_control/domains) só com o
# gate utilizável; o estado do gate entra na chave do cache (e no conteúdo,
# logo no reference_version).
#
# Módulo 35b (§11; Q10, Q11, Q20): `zoonoses_domains` = a parte do §11 do
# Zoonoses::Json.domains (o corpo de GET /zoonoses/domains, sem as listas que
# são só do dashboard) só com Zoonoses::Gate.field_usable?; o gate entra na
# chave do cache ("/zoonoses"). A campanha aberta está no conteúdo: abrir ou
# fechar muda o reference_version (no máximo REFERENCE_CACHE depois).
module FieldSync
  module Reference
    FIELD_KEYS = %w[domain max min max_items required].freeze
    # As chaves do $defs/zoonoses_domains do reference-response v1.4.0 (§11).
    ZOONOSES_KEYS = %i[species sexes sizes animal_statuses dpp_results products open_campaign parameters limits].freeze

    module_function

    # -> Hash na forma do reference-response-v1 (chaves texto).
    def build(user:, city:)
      body = body(Json.field_teams(user).map(&:first), vector_control: VectorControl::Gate.usable?(city),
                                                       zoonoses: Zoonoses::Gate.field_usable?(city)).as_json
      { "reference_version" => digest(body) }.merge(body)
    end

    # O mesmo valor de `build`, do cache (só o hex; Q29).
    def version(user:, city:)
      teams = Json.field_teams(user).map(&:first)
      teams_digest = Digest::SHA256.hexdigest(teams.map(&:id).sort.join(","))
      vector = VectorControl::Gate.usable?(city)
      zoonoses = Zoonoses::Gate.field_usable?(city)
      key = "field_sync/reference_version/#{city.id}/#{teams_digest}#{'/vector_control' if vector}#{'/zoonoses' if zoonoses}"
      Rails.cache.fetch(key, expires_in: Catalog::REFERENCE_CACHE) do
        digest(body(teams, vector_control: vector, zoonoses: zoonoses).as_json)
      end
    end

    def digest(body) = Digest::SHA256.hexdigest(Signatures::Jcs.dump(body))

    def body(teams, vector_control:, zoonoses:)
      data = TerritoryRegistry::Dictionary::DATA
      { registration_dictionaries: { version: data.fetch("version"), domains: lists(data.fetch("domains")),
                                     sections: data.fetch("sections").transform_values { |fields| fields(fields) } },
        string_domains: lists(data.fetch("string_domains")),
        neighborhoods: Neighborhood.active_neighborhoods.order(:name, :id).map { |row| { id: row.id, name: row.name } },
        health_units: HealthUnit.active_units.order(:id).map { |unit| { id: unit.id, cnes: unit.cnes.presence, name: unit.name } },
        team_professionals: teams.flat_map { |team| professionals(team) },
        home_visit_domains: HomeVisits::Json.domains,
        collective_activity_domains: CollectiveActivities::Json.domains,
        **(vector_control ? { vector_control_domains: VectorControl::Json.domains } : {}),
        **(zoonoses ? { zoonoses_domains: Zoonoses::Json.domains.slice(*ZOONOSES_KEYS) } : {}) }
    end

    # Q27: cada domínio é uma LISTA na ordem do YAML (um objeto de códigos
    # inteiros seria reordenado pelo JavaScript).
    def lists(domains)
      domains.transform_values { |entries| entries.map { |code, label| { code: code, label: label } } }
    end

    # A forma do gerador do dashboard (ledi-dictionaries.mjs), na ordem do YAML.
    def fields(specs)
      specs.map do |key, spec|
        field = { key: key, ledi: spec.fetch("ledi"), type: spec.fetch("type") }
        FIELD_KEYS.each { |prop| field[prop.to_sym] = spec[prop] if spec.key?(prop) }
        field[:fields] = fields(spec.fetch("fields")) if spec.fetch("type") == "object"
        field
      end
    end

    # Q6: a função das opções da atividade, só com o vínculo NESTA equipe.
    def professionals(team)
      CollectiveActivities::Access.professional_memberships(team).values
                                  .select { |member| member.health_team_id == team.id }
                                  .map do |member|
        professional = member.professional
        { team_id: team.id, professional_id: professional.id, name: professional.professional_name, cbo: member.cbo_code,
          has_cns: Professionals::Cns.valid?(professional.cns) }
      end.sort_by { |row| [ row[:name].to_s, row[:professional_id] ] }
    end

    private_class_method :digest, :body, :lists, :fields, :professionals
  end
end
