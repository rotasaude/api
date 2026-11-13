require "rails_helper"

# Módulo 24b (ADR 0052; contrato §1, §6, §13; 6A; Q11, Q13, Q14, Q21; ruling
# A3): contexto da equipe e atribuição de microárea aos CBOs de campo que não
# são ACS. Só o enfermeiro da equipe atribui e encerra, com step-up; o evento
# micro_area.field_assignment_changed leva só ids.
RSpec.describe "Visita domiciliar — contexto e atribuição de microárea", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:tacs) { field_agent!(cbo: "322255", team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:doctor) { field_agent!(cbo: "225142", team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:open_area) { registry_micro_area!(code: "03", team: team) }

  def assign(micro_area: open_area, professional: tacs.professional)
    json_post "/home_visits/assignments", micro_area_id: micro_area.id, professional_id: professional.id
  end

  def assignment_events = DomainEvent.where(name: "micro_area.field_assignment_changed").order(:occurred_at)

  it "enfermeiro atribui com step-up (201) e sem step-up recebe 401 mfa_required" do
    sign_in_as(nurse)
    assign
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    expect(MicroAreaFieldAssignment.count).to eq(0)

    stepped_up!(nurse)
    assign
    expect(response).to have_http_status(:created)
    expect(json_body).to include("micro_area" => { "id" => open_area.id, "code" => "03", "name" => "Microárea 03" },
                                 "professional" => { "id" => tacs.professional.id, "name" => tacs.professional.professional_name,
                                                     "cbo" => "322255" },
                                 "assigned_by" => { "name" => nurse.professional.professional_name })
    expect(json_body["id"]).to eq(MicroAreaFieldAssignment.sole.id)
    expect(json_body["assigned_at"]).to be_present
    expect(assignment_events.sole.payload).to eq("micro_area_id" => open_area.id, "professional_id" => tacs.professional.id,
                                                 "user_id" => nurse.id, "ended" => false)
  end

  it "repetido → 409 already_assigned" do
    stepped_up!(nurse)
    assign
    assign
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_assigned")
    expect(MicroAreaFieldAssignment.count).to eq(1)
  end

  it "ACS responsável pela própria ou CBO fora da Tabela 7 → 422 cbo_not_allowed" do
    stepped_up!(nurse)
    assign(micro_area: area, professional: acs.professional)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    assign(micro_area: open_area, professional: acs.professional) # ruling A3: o 515105 nunca é atribuído
    expect(json_body).to eq("error" => "cbo_not_allowed")
    assign(micro_area: open_area, professional: doctor.professional)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    stranger = field_agent!(cbo: "322255", team: registry_team!(care_unit!))
    assign(micro_area: open_area, professional: stranger.professional)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    expect(MicroAreaFieldAssignment.count).to eq(0)
  end

  it "microárea inativa → 422 micro_area_inactive; corpo sem ids → 422 invalid_request com path" do
    stepped_up!(nurse)
    open_area.update!(active: false)
    assign
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "micro_area_inactive")
    json_post "/home_visits/assignments", micro_area_id: area.id
    expect(json_body).to eq("error" => "invalid_request", "path" => "professional_id")
    json_post "/home_visits/assignments", professional_id: tacs.professional.id
    expect(json_body).to eq("error" => "invalid_request", "path" => "micro_area_id")
  end

  it "só o enfermeiro da equipe: médico e ACS → 403 cbo_not_allowed; de outra equipe → 403 out_of_scope" do
    stepped_up!(doctor)
    assign
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    get "/home_visits/assignments", params: { team_id: team.id }
    expect(json_body).to eq("error" => "cbo_not_allowed")
    stepped_up!(acs)
    assign
    expect(json_body).to eq("error" => "cbo_not_allowed")
    stepped_up!(registry_nurse!(care_unit!, team: registry_team!(care_unit!)))
    assign
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    get "/home_visits/assignments", params: { team_id: team.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    expect(MicroAreaFieldAssignment.count).to eq(0)
  end

  it "candidates sem o ACS responsável; lista só as ativas" do
    acs
    agent = field_agent!(cbo: "515140", team: team)
    first = assignment!(open_area, tacs.professional, by: nurse)
    ended = assignment!(area, agent.professional, by: nurse)
    ended.update!(ended_at: Time.current, ended_by_user: nurse)
    sign_in_as(nurse)
    get "/home_visits/assignments", params: { team_id: team.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"]).to contain_exactly(
      include("id" => first.id, "micro_area" => { "id" => open_area.id, "code" => "03", "name" => "Microárea 03" },
              "professional" => include("id" => tacs.professional.id, "cbo" => "322255"))
    )
    expect(json_body["candidates"]).to contain_exactly(
      { "professional_id" => tacs.professional.id, "name" => tacs.professional.professional_name, "cbo" => "322255" },
      { "professional_id" => agent.professional.id, "name" => agent.professional.professional_name, "cbo" => "515140" }
    )
    get "/home_visits/assignments", params: { team_id: team.id, cpf: "12345678909" }
    expect(json_body).to eq("error" => "invalid_request")
  end

  it "encerrar → 200 e evento com ended: true só com ids; de novo → 409 assignment_already_ended; sem step-up → 401" do
    assignment = assignment!(open_area, tacs.professional, by: nurse)
    sign_in_as(nurse)
    json_post "/home_visits/assignments/#{assignment.id}/end", {}
    expect(response).to have_http_status(:unauthorized)
    expect(assignment.reload.ended_at).to be_nil

    stepped_up!(nurse)
    json_post "/home_visits/assignments/#{assignment.id}/end", {}
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => assignment.id, "ended_at" => be_present)
    expect(assignment.reload).to have_attributes(ended_by_user_id: nurse.id)
    expect(assignment_events.last.payload).to eq("micro_area_id" => open_area.id, "professional_id" => tacs.professional.id,
                                                 "user_id" => nurse.id, "ended" => true)

    json_post "/home_visits/assignments/#{assignment.id}/end", {}
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "assignment_already_ended")
    expect(assignment_events.count).to eq(1)
  end

  it "encerrar a atribuição de outra equipe (ou id desconhecido) → 404" do
    foreign_team = registry_team!(care_unit!)
    foreign = assignment!(registry_micro_area!(code: "01", team: foreign_team), field_agent!(cbo: "322255", team: foreign_team).professional)
    stepped_up!(nurse)
    json_post "/home_visits/assignments/#{foreign.id}/end", {}
    expect(response).to have_http_status(:not_found)
    json_post "/home_visits/assignments/#{SecureRandom.uuid}/end", {}
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.ended_at).to be_nil
  end

  it "ACS lê o contexto com scope: responsible, TACS com assigned, enfermeiro com team" do
    area
    assignment!(open_area, tacs.professional, by: nurse)
    registry_micro_area!(code: "09", team: team).update!(active: false)

    sign_in_as(acs)
    get "/home_visits/context"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("today" => Time.zone.today.iso8601, "min_date" => HomeVisits::Rules.min_date(Time.zone.today).iso8601)
    expect(json_body["teams"].sole).to include(
      "id" => team.id, "ine" => team.ine, "name" => team.name, "cbo" => "515105", "can_register" => true, "can_assign" => false,
      "can_register_device" => true, "reads_whole_team" => false, "out_of_area_allowed" => true, "professionals" => [],
      "micro_areas" => [ { "id" => area.id, "code" => "01", "name" => "Microárea 01", "scope" => "responsible" } ]
    )

    sign_in_as(tacs)
    get "/home_visits/context"
    expect(json_body["teams"].sole).to include(
      "cbo" => "322255", "can_register" => true, "can_assign" => false, "can_register_device" => true, "reads_whole_team" => false,
      "out_of_area_allowed" => false, "professionals" => [],
      "micro_areas" => [ { "id" => open_area.id, "code" => "03", "name" => "Microárea 03", "scope" => "assigned" } ]
    )

    sign_in_as(nurse)
    get "/home_visits/context"
    nurse_team = json_body["teams"].sole
    expect(nurse_team).to include("cbo" => "223505", "can_register" => false, "can_assign" => true, "can_register_device" => false,
                                  "reads_whole_team" => true, "out_of_area_allowed" => false)
    expect(nurse_team["micro_areas"]).to eq([ { "id" => area.id, "code" => "01", "name" => "Microárea 01", "scope" => "team" },
                                              { "id" => open_area.id, "code" => "03", "name" => "Microárea 03", "scope" => "team" } ])
    expect(nurse_team["professionals"]).to contain_exactly(
      { "id" => acs.professional.id, "name" => acs.professional.professional_name, "cbo" => "515105" },
      { "id" => tacs.professional.id, "name" => tacs.professional.professional_name, "cbo" => "322255" }
    )

    sign_in_as(care_admin!)
    get "/home_visits/context"
    expect(response).to have_http_status(:ok)
    expect(json_body["teams"]).to eq([])
    expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty # contexto sem trilha (§13)
  end

  it "contexto serve os domínios da visita (§7) a partir do YAML da task 1" do
    sign_in_as(acs)
    get "/home_visits/context"
    domains = json_body["domains"]
    expect(domains.keys).to include("motivo_visita", "desfecho", "turno", "tipo_glicemia", "tipo_de_imovel", "non_residential_property_types",
                                    "non_residential_reasons", "male_forbidden_reasons", "without_person_allowed_reasons",
                                    "responsible_document_reasons", "reasons_max", "measurement_ranges")
    expect(domains["motivo_visita"].first).to eq("code" => 1, "label" => "Cadastramento / Atualização", "group" => "TIPO_VISITA",
                                                 "group_label" => "Tipo de visita")
    expect(domains["desfecho"]).to eq([ { "code" => 1, "label" => "Visita realizada" }, { "code" => 2, "label" => "Visita recusada" },
                                        { "code" => 3, "label" => "Ausente" } ])
    expect(domains["tipo_de_imovel"].first).to eq("code" => "1", "label" => "Domicílio")
    expect(domains["tipo_de_imovel"].map { _1["code"] }).to match_array(TerritoryRegistry::Catalog::PROPERTY_TYPES)
    expect(domains["male_forbidden_reasons"]).to eq([ 5, 6 ])
    expect(domains["reasons_max"]).to eq(36)
    expect(domains["measurement_ranges"]["weight_kg"]).to eq("min" => 0.5, "max" => 500, "decimals" => 3)
    expect(domains["measurement_ranges"].keys).to match_array(%w[weight_kg height_cm systolic diastolic temperature_c glucose_mg_dl])
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    stepped_up!(nurse)
    get "/home_visits/context"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "home_visits")
    get "/home_visits/assignments", params: { team_id: team.id }
    expect(json_body).to include("error" => "feature_disabled")
    assign
    expect(json_body).to include("error" => "feature_disabled")
    expect(MicroAreaFieldAssignment.count).to eq(0)
  end

  # Q11 (ruling A5b): o CBO de campo que não é ACS lê o 24a nas microáreas
  # atribuídas, só leitura, pelas rotas do 24a e com a trilha do 24a.
  it "TACS lê domicílios e moradores da microárea atribuída pelas rotas do 24a, não os da não atribuída (403), e não escreve; encerrar tira a leitura na hora" do
    household = registry_household!(micro_area: open_area)
    registration = registry_registration!(household: household)
    other = registry_household!(micro_area: area)
    assignment = assignment!(open_area, tacs.professional, by: nurse)

    sign_in_as(tacs)
    get "/territory/households", params: { micro_area_id: open_area.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["households"].map { _1["id"] }).to eq([ household.id ])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).last.payload).to include("access" => "territory_registry",
                                                                                     "household_ids" => [ household.id ])
    get "/territory/households/#{household.id}"
    expect(response).to have_http_status(:ok)
    get "/territory/registrations", params: { household_id: household.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["registrations"].map { _1["id"] }).to eq([ registration.id ])

    get "/territory/households", params: { micro_area_id: area.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    get "/territory/households/#{other.id}"
    expect(response).to have_http_status(:not_found)
    get "/territory/registrations", params: { household_id: other.id }
    expect(response).to have_http_status(:not_found)

    # Escrita do 24a segue só do ACS.
    json_patch "/territory/households/#{household.id}", registry_household_params(household).merge("version" => household.reload.version,
                                                                                                    "contact_phone" => "41988887777")
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    families = Family.count
    json_post "/territory/households/#{household.id}/families", responsible: { patient_id: registry_patient!.id }, members_count: 1,
                                                                version: household.reload.version
    expect(response).not_to be_successful
    expect(Family.count).to eq(families)

    assignment.update!(ended_at: Time.current, ended_by_user: nurse)
    get "/territory/households", params: { micro_area_id: open_area.id }
    expect(response).to have_http_status(:forbidden)
    get "/territory/registrations", params: { household_id: household.id }
    expect(response).to have_http_status(:not_found)
  end
end
