require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.5; Q6, Q7, Q27, Q29): a referência offline
# do app de campo. Monta com as mesmas fontes que servem o dashboard (o YAML do
# cadastro, os domínios da visita e da atividade), sem dado de cidadão, e
# resume o conteúdo num reference_version que só muda quando ele muda.
RSpec.describe FieldSync::Reference, type: :model do
  let!(:city) { home_visit_city!(collective: true) }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }

  def build(user = acs) = described_class.build(user: user, city: Current.city).as_json
  def yaml = YAML.load_file(Rails.root.join("config/ledi/registration_dictionaries.yml"))

  it "valida contra reference-response-v1 e não traz documento de ninguém" do
    reference = build
    expect(FieldSync::Schemas.errors("reference-response-v1", reference)).to eq([])
    expect(reference.keys).to match_array(%w[reference_version registration_dictionaries string_domains neighborhoods health_units
                                             team_professionals home_visit_domains collective_activity_domains])
    text = reference.to_json
    expect(text).not_to include(acs.professional.cns)
    expect(text).not_to match(/"(cpf|cns)"/)
  end

  it "dicionários e domínios de texto são os do YAML, em listas e na ordem dele (Q27)" do
    dictionaries = build.fetch("registration_dictionaries")
    expect(dictionaries.keys).to eq(%w[version domains sections])
    expect(dictionaries["version"]).to eq(yaml["version"])
    expect(dictionaries["domains"].keys).to eq(yaml["domains"].keys)
    yaml["domains"].each do |name, entries|
      expect(dictionaries["domains"][name]).to eq(entries.map { |code, label| { "code" => code, "label" => label } }), name
    end
    water = dictionaries["domains"]["abastecimento_de_agua"].map { _1["code"] }
    expect(water.first(3)).to eq([ 117, 214, 118 ]) # a ordem do YAML, não a numérica

    expect(dictionaries["sections"].keys).to eq(yaml["sections"].keys)
    section = dictionaries["sections"]["identification"]
    expect(section.map { _1["key"] }).to eq(yaml["sections"]["identification"].keys)
    expect(section.first).to eq("key" => "nome_pai_cidadao", "ledi" => "nomePaiCidadao", "type" => "name", "max" => 70, "min" => 3)
    nested = dictionaries["sections"].values.flatten.find { _1["type"] == "object" }
    expect(nested.fetch("fields")).to all(include("key", "ledi", "type")) if nested

    strings = build.fetch("string_domains")
    expect(strings.keys).to eq(%w[uf tipo_logradouro])
    expect(strings["uf"]).to eq(yaml["string_domains"]["uf"].map { |code, label| { "code" => code, "label" => label } })
    expect(strings["tipo_logradouro"].first.keys).to eq(%w[code label])
  end

  it "só bairros e unidades ativos; unidade sem CNES vem com cnes null (Q6)" do
    active = care_neighborhood!(unit)
    inactive = care_neighborhood!(unit)
    inactive.update!(active: false)
    closed = care_unit!("UBS Fechada")
    closed.update!(active: false)
    unit_without_cnes = care_unit!("Ponto de apoio")
    unit_without_cnes.update_columns(cnes: nil)

    reference = build
    expect(reference["neighborhoods"]).to include("id" => active.id, "name" => active.name)
    expect(reference["neighborhoods"].map { _1["id"] }).not_to include(inactive.id)
    expect(reference["neighborhoods"].map { _1["name"] }).to eq(reference["neighborhoods"].map { _1["name"] }.sort)
    units = reference["health_units"].index_by { _1["id"] }
    expect(units.keys).to include(unit.id, unit_without_cnes.id)
    expect(units.keys).not_to include(closed.id)
    expect(units[unit.id]).to eq("id" => unit.id, "cnes" => unit.cnes, "name" => unit.name)
    expect(units[unit_without_cnes.id]).to include("cnes" => nil)
  end

  it "profissionais só das equipes do aparelho, com o CBO do vínculo nelas e o has_cns das opções da atividade (Q6)" do
    nurse = registry_nurse!(unit, team: team)
    nurse.professional.update_columns(cns: "123456789012345") # dígito inválido: sem CNS utilizável
    expect(Professionals::Cns.valid?(nurse.professional.cns)).to be(false)
    other_team = registry_team!(unit)
    outsider = registry_acs!(unit, team: other_team)

    rows = build.fetch("team_professionals")
    expect(rows.map(&:keys).uniq).to eq([ %w[team_id professional_id name cbo has_cns] ])
    expect(rows.map { _1["team_id"] }.uniq).to eq([ team.id ])
    by_id = rows.index_by { _1["professional_id"] }
    expect(by_id.keys).to include(acs.professional.id, nurse.professional.id)
    expect(by_id.keys).not_to include(outsider.professional.id)
    expect(by_id[acs.professional.id]).to include("cbo" => "515105", "has_cns" => true, "name" => acs.professional.professional_name)
    expect(by_id[nurse.professional.id]).to include("has_cns" => false)
    expect(rows.map { _1["name"] }).to eq(rows.map { _1["name"] }.sort)
  end

  it "os domínios da visita e da atividade são os mesmos blocos do dashboard (Q7)" do
    reference = build
    expect(reference["home_visit_domains"]).to eq(HomeVisits::Json.domains.as_json)
    expect(reference["collective_activity_domains"]).to eq(CollectiveActivities::Json.domains.as_json)
  end

  describe "reference_version" do
    it "é o SHA-256 do JSON canônico do corpo sem ele; mesmo conteúdo, mesmo valor; um bairro novo muda" do
      reference = build
      body = reference.except("reference_version")
      expect(reference["reference_version"]).to eq(Digest::SHA256.hexdigest(Signatures::Jcs.dump(body)))
      expect(build["reference_version"]).to eq(reference["reference_version"])
      care_neighborhood!(unit)
      expect(build["reference_version"]).not_to eq(reference["reference_version"])
    end

    it "version devolve o mesmo valor e o cache guarda só o hex (Q29)" do
      stored = nil
      key = nil
      allow(Rails.cache).to receive(:fetch) do |cache_key, **options, &block|
        key = cache_key
        expect(options).to eq(expires_in: FieldSync::Catalog::REFERENCE_CACHE)
        stored = block.call
      end
      version = described_class.version(user: acs, city: Current.city)
      expect(version).to eq(build["reference_version"])
      expect(stored).to match(/\A[0-9a-f]{64}\z/)
      expect(key).to match(%r{\Afield_sync/reference_version/#{Current.city.id}/[0-9a-f]{64}\z})
      expect(key).not_to include(team.id)
    end
  end
end
