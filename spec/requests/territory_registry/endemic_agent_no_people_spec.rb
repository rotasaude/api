require "rails_helper"

# Módulo 35a (Q41, minimização da Q13(1)): o agente de endemias (515140) não
# recebe dado de morador pelo 24a. O domicílio que as rotas lhe serializam vem
# com `families: []` e só `families_count` (as famílias que ainda moram, como
# o mapa); os moradores do GET /territory/registrations?household_id= não vêm.
# Varredura de chave e de valor em toda rota do 24a que ele lê: nenhum nome,
# CPF, CNS ou id de paciente semeado, nenhuma chave de pessoa. O ACS e o TACS
# atribuído leem o mesmo domicílio como antes (guarda de regressão).
#
# Fora da varredura, de propósito: POST /territory/person_lookup e
# /territory/patients/duplicates. Ali quem chama já traz o CPF ou o nome (a
# busca de qualquer health_professional, igual à de outros módulos); não é o
# domicílio que o api serializa. Ver o relatório da Q41.
RSpec.describe "Território — o agente de endemias não recebe morador (Q41)", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let!(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:acs) { area.reload.acs_professional.user }

  let!(:household) { registry_household!(micro_area: area) }
  let!(:responsible) { person!(1, "Zuleica Marambaia Teixeira", "Iracema Marambaia Teixeira") }
  let!(:member) { person!(2, "Bartolomeu Quintanilha Prado", "Genoveva Quintanilha Prado") }
  let!(:registrations) do
    [ responsible, member ].map { |patient| registry_registration!(patient: patient, household: household) }
  end
  let!(:family) { registry_family!(household, responsible: responsible, members_count: 2) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  # CPF e CNS conhecidos (CNS definitivo de 15 dígitos, pelo gerador do api).
  def person!(n, full_name, mother_name)
    Patient.create!(cpf: valid_cpf(9_000 + n), cns: valid_cns(9_000 + n), full_name: full_name, mother_name: mother_name,
                    birth_date: "1980-03-0#{n}", sex: n.odd? ? "female" : "male", race_color: "03")
  end

  # Tudo o que identifica as pessoas semeadas: nomes, mães, CPF, CNS (cru e
  # mascarado) e os ids de paciente.
  def person_values
    [ responsible, member ].flat_map do |patient|
      [ patient.full_name, patient.mother_name, patient.cpf, patient.cns, patient.cns_masked, patient.id ]
    end.compact.uniq
  end

  def person_keys
    %w[responsible display_name full_name mother_name social_name cpf cns cns_masked has_cpf no_cpf_reason
       patient patient_id citizen_id birth_date patient_demographics]
  end

  def keys_of(value)
    case value
    when Hash then value.keys + value.values.flat_map { |inner| keys_of(inner) }
    when Array then value.flat_map { |inner| keys_of(inner) }
    else []
    end
  end

  # [método, caminho, corpo] → a resposta crua, varrida por valor e por chave.
  def swept(verb, path, params = nil)
    case verb
    when :get then get(path, params: params)
    when :post then json_post(path, params || {})
    when :patch then json_patch(path, params || {})
    end
    raw = response.body.to_s
    leaked = person_values.select { |value| raw.include?(value.to_s) }
    expect(leaked).to eq([]), "#{verb.upcase} #{path} (#{response.status}) vazou #{leaked.inspect}"
    parsed = response.media_type == "application/json" && raw.present? ? JSON.parse(raw) : nil
    expect(keys_of(parsed) & person_keys).to eq([]), "#{verb.upcase} #{path} trouxe chave de pessoa"
    parsed
  end

  def commerce_body(**over)
    { micro_area_id: area.id, property_type: "2", refused: false, contact_phone: "4133334444", address: registry_address }.merge(over)
  end

  it "toda rota do 24a que o 515140 lê: nenhum nome, CPF, CNS ou id de morador, nenhuma chave de pessoa" do
    sign_in_as(agent)

    teams = swept(:get, "/territory/teams")
    expect(teams.fetch("teams").map { _1["id"] }).to eq([ team.id ])

    page = swept(:get, "/territory/households", micro_area_id: area.id)
    listed = page.fetch("households").find { _1["id"] == household.id }
    expect(listed).to include("families" => [], "families_count" => 1)

    shown = swept(:get, "/territory/households/#{household.id}")
    expect(shown).to include("id" => household.id, "property_type" => "1", "families" => [], "families_count" => 1)
    expect(shown).to have_key("living_conditions")

    created = swept(:post, "/territory/households", commerce_body)
    expect(response).to have_http_status(:created)
    expect(created).to include("property_type" => "2", "families" => [], "families_count" => 0)
    commerce_id = created.fetch("id")
    expect(swept(:get, "/territory/households/#{commerce_id}")).to include("families" => [], "families_count" => 0)
    updated = swept(:patch, "/territory/households/#{commerce_id}", commerce_body(property_type: "4", version: 1))
    expect(response).to have_http_status(:ok)
    expect(updated).to include("version" => 2, "families" => [], "families_count" => 0)

    expect(swept(:get, "/territory/registrations", household_id: household.id)).to eq("registrations" => [])
    expect(swept(:get, "/territory/registrations", patient_id: responsible.id)).to eq("registrations" => [])
    swept(:get, "/territory/registrations/#{registrations.first.id}")
    expect(response).to have_http_status(:not_found)

    points = swept(:get, "/territory/map/households", micro_area_id: area.id)
    expect(points).to have_key("items")
    swept(:get, "/territory/map")
    swept(:get, "/territory/registry_status", team_id: team.id, micro_area_id: area.id)
    expect(response).to have_http_status(:forbidden)
    swept(:get, "/territory/registry_status/count", team_id: team.id, micro_area_id: area.id)
    expect(response).to have_http_status(:forbidden)

    swept(:post, "/territory/households/#{household.id}/families", responsible: { patient_id: member.id }, members_count: 1, version: 1)
    expect([ 403, 404 ]).to include(response.status)
    swept(:patch, "/territory/families/#{family.id}", members_count: 3, version: household.reload.version)
    expect([ 403, 404 ]).to include(response.status)
    swept(:post, "/territory/families/#{family.id}/replace_responsible", responsible: { patient_id: member.id }, version: household.version)
    expect([ 403, 404 ]).to include(response.status)
    swept(:get, "/territory/admin/teams")
    swept(:get, "/territory/admin/micro_areas", team_id: team.id)
  end

  it "o ACS da microárea segue lendo o responsável e os moradores (regressão)" do
    sign_in_as(acs)
    get "/territory/households/#{household.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).not_to have_key("families_count")
    expect(json_body.fetch("families")).to contain_exactly(
      a_hash_including("id" => family.id, "responsible" => { "patient_id" => responsible.id, "display_name" => responsible.full_name })
    )
    get "/territory/households", params: { micro_area_id: area.id }
    expect(json_body.fetch("households").first.fetch("families").first.dig("responsible", "display_name")).to eq(responsible.full_name)
    get "/territory/registrations", params: { household_id: household.id }
    expect(json_body.fetch("registrations").map { _1.dig("patient", "full_name") })
      .to contain_exactly(responsible.full_name, member.full_name)
  end

  it "o TACS (515130) atribuído à mesma microárea segue lendo como no 24b (Q11)" do
    tacs = field_agent!(cbo: "515130", team: team)
    assignment!(area, tacs.professional)
    sign_in_as(tacs)
    get "/territory/households/#{household.id}"
    expect(json_body).not_to have_key("families_count")
    expect(json_body.fetch("families").first.dig("responsible", "display_name")).to eq(responsible.full_name)
    get "/territory/registrations", params: { household_id: household.id }
    expect(json_body.fetch("registrations").size).to eq(2)
  end

  it "com vector_control desligado o 515140 também não recebe morador (o papel decide, não o interruptor)" do
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(agent)
    expect(swept(:get, "/territory/households/#{household.id}")).to include("families" => [], "families_count" => 1)
    expect(swept(:get, "/territory/registrations", household_id: household.id)).to eq("registrations" => [])
  end
end
