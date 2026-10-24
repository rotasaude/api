require "rails_helper"

# Módulo 24a (ADR 0042; contrato §2, §5, §14 L3, L4, L5, L7, L9, L11; F-24.3,
# F-24.5): cadastro individual pela equipe; cada gravação é versão imutável e
# ficha de cadastro individual; leitura nominal com trilha clinical_record.viewed
# (access territory_registry) por pessoa; dado sensível só no corpo.
RSpec.describe "Território — cadastro individual", type: :request do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:household) { registry_household!(micro_area: area) }
  let(:sections) { registry_registration_sections }
  let(:demographics) { { patient_demographics: { race_color: "03" } } }

  def body(**over) = sections.merge(demographics).merge(household_id: household.id, is_responsible: false).merge(over)

  it "cria paciente sem CPF com CNS direto do cadastro; versão 1 e ficha individual com CNS" do
    sign_in_as(acs)
    json_post "/territory/registrations", body(new_patient: { full_name: "Lia Santos", birth_date: "2026-08-01", sex: "female",
                                                              mother_name: "Carla Santos", no_cpf_reason: "3", cns: valid_cns(41) })
    expect(response).to have_http_status(:created)
    expect(json_body["patient"]).to include("has_cpf" => false, "no_cpf_reason" => "3", "display_name" => "Lia Santos",
                                            "birth_date" => "2026-08-01", "sex" => "female")
    expect(json_body).to include("version" => 1, "status" => "valid", "exit" => nil, "refused" => false, "household_id" => household.id,
                                 "team" => { "id" => team.id, "ine" => team.ine, "name" => team.name },
                                 "micro_area" => { "id" => area.id, "code" => "01" }, "identity_changed_at" => nil)
    expect(json_body["street_situation"]).to eq("status_situacao_rua" => false)
    expect(json_body["patient_demographics"]).to eq("race_color" => "03", "ethnicity" => nil)
    expect(response.body).not_to include(valid_cns(41))
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual").count).to eq(1)
    expect(DomainEvent.where(name: "territory_registration.saved").last.payload.keys)
      .to match_array(%w[registration_id registration_version_id patient_id user_id])
  end

  # Review Focus 4: sem CPF e sem CNS grava (201), a ficha fica "não gerada"
  # (patient_without_identifier) e o PATCH com o CNS gera a da nova versão.
  it "sem CPF e sem CNS: grava, ficha não gerada; informar o CNS gera a ficha da nova versão" do
    sign_in_as(acs)
    json_post "/territory/registrations", body(new_patient: { full_name: "Rui Alves", birth_date: "1970-01-01", sex: "male",
                                                              mother_name: "Ana Alves", no_cpf_reason: "5" })
    expect(response).to have_http_status(:created)
    id = json_body["id"]
    expect(LediGenerationFailure.last.reason_codes).to eq(%w[patient_without_identifier])
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual").count).to eq(0)
    json_patch "/territory/registrations/#{id}", body(version: 1, cns: valid_cns(42))
    expect(response).to have_http_status(:ok)
    expect(json_body["version"]).to eq(2)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual").count).to eq(1)
    json_patch "/territory/registrations/#{id}", body(version: 1)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "stale_version")
  end

  it "CPF de outro paciente → 409 cpf_taken; sem CPF e sem justificativa → 422" do
    other, _ = exam_patient!(3, age: 30, sex: "female")
    sign_in_as(acs)
    json_post "/territory/registrations", body(new_patient: { full_name: "Ana Paula", birth_date: "1996-01-01", sex: "female",
                                                              mother_name: "Rosa Paula", no_cpf_reason: "8" })
    json_patch "/territory/registrations/#{json_body['id']}", body(version: 1, cpf: other.cpf)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "cpf_taken")
    json_post "/territory/registrations", body(new_patient: { full_name: "Sem Doc", birth_date: "1996-01-01", sex: "female" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "cpf_or_reason_required")
  end

  it "par validado sem paciente cria o paciente pelo Resolve; segundo cadastro ativo → already_registered com o id" do
    citizen = verified_citizen!(9)
    sign_in_as(acs)
    json_post "/territory/registrations", body(citizen_id: citizen.id)
    expect(response).to have_http_status(:created)
    first = json_body["id"]
    expect(citizen.reload.patient_id).to eq(json_body["patient"]["id"])
    json_post "/territory/registrations", body(patient_id: citizen.patient_id)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_registered", "registration_id" => first)
    json_patch "/territory/registrations/#{first}", body(version: 1, patient: { full_name: "Nome Trocado Aqui" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "identity_locked", "path" => "patient.full_name")
  end

  it "recusa com termo (sem saída); saída por óbito congela e não se repete; técnico de enfermagem não grava; CPF nunca na URL" do
    sign_in_as(acs)
    patient = care_patient!(age: 50, sex: "male")
    json_post "/territory/registrations", household_id: household.id, is_responsible: false, patient_id: patient.id, refused: true,
                                          identification: sections[:identification]
    expect(response).to have_http_status(:created)
    expect(json_body).to include("refused" => true, "status" => "refused")
    json_post "/territory/registrations/#{json_body['id']}/exit", reason: "moved", on: Time.zone.today.iso8601
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_transition")

    saved = registry_registration!(household: household)
    id = saved.id
    today = Time.zone.today.iso8601
    json_post "/territory/registrations/#{id}/exit", reason: "death", on: today
    expect(json_body).to eq("error" => "invalid_registration", "path" => "death_on")
    json_post "/territory/registrations/#{id}/exit", reason: "death", on: today, death_on: today, death_certificate: "12345"
    expect(json_body).to eq("error" => "invalid_registration", "path" => "death_certificate")
    json_post "/territory/registrations/#{id}/exit", reason: "death", on: today, death_on: (Time.zone.today - 1).iso8601,
                                                     death_certificate: "123456789"
    expect(response).to have_http_status(:ok)
    expect(json_body["exit"]).to eq("reason" => "death", "on" => today, "death_on" => (Time.zone.today - 1).iso8601,
                                    "death_certificate" => "123456789")
    # registered_at é o da última gravação (save/identity_refresh), nunca o da saída
    expect(json_body).to include("status" => "exited", "version" => 2, "registered_at" => saved.registered_at.iso8601)
    expect(DomainEvent.where(name: "territory_registration.exited").last.payload.keys)
      .to match_array(%w[registration_id registration_version_id patient_id user_id])
    json_post "/territory/registrations/#{id}/exit", reason: "moved", on: today
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_transition")
    json_patch "/territory/registrations/#{id}", body(version: 2)
    expect(json_body).to eq("error" => "invalid_transition")

    technician = screener!(unit, cbo: "322245")
    HealthTeamMember.create!(professional: technician.professional, health_team: team, cbo_code: "322245", started_on: Time.zone.today - 1)
    sign_in_as(technician)
    json_post "/territory/registrations", body(patient_id: care_patient!(age: 30, sex: "male").id)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")

    sign_in_as(acs)
    get "/territory/registrations", params: { patient_id: patient.id, cpf: patient.cpf }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_request")
    expect(response.body).not_to include(patient.cpf)
  end

  it "saída: motivo e data validados; o admin nunca registra saída" do
    registration = registry_registration!(household: household)
    sign_in_as(acs)
    json_post "/territory/registrations/#{registration.id}/exit", reason: "fugiu", on: Time.zone.today.iso8601
    expect(json_body).to eq("error" => "invalid_registration", "path" => "reason")
    json_post "/territory/registrations/#{registration.id}/exit", reason: "moved", on: (Time.zone.today + 1).iso8601
    expect(json_body).to eq("error" => "invalid_registration", "path" => "on")
    json_post "/territory/registrations/#{registration.id}/exit", reason: "moved", on: "1900-01-01"
    expect(json_body).to eq("error" => "invalid_registration", "path" => "on")
    json_post "/territory/registrations/#{registration.id}/exit", reason: "moved", on: Time.zone.today.iso8601, death_on: Time.zone.today.iso8601
    expect(json_body).to eq("error" => "invalid_registration", "path" => "death_on")
    expect(registration.reload.exited?).to be(false)
    sign_in_as(care_admin!)
    json_post "/territory/registrations/#{registration.id}/exit", reason: "moved", on: Time.zone.today.iso8601
    expect(response).to have_http_status(:not_found)
    expect(TerritoryRegistry::ExitRegistration.call(registration: registration, params: { "reason" => "moved", "on" => Time.zone.today.iso8601 },
                                                    by: care_admin!).reason).to eq(:out_of_scope)
  end

  it "leitura nominal com trilha por pessoa; enfermeiro da equipe lê; profissional de fora → 404" do
    registration = registry_registration!(household: household)
    sign_in_as(registry_nurse!(unit, team: team))
    get "/territory/registrations/#{registration.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => registration.id, "version" => 1)
    event = DomainEvent.where(name: "clinical_record.viewed").last
    expect(event.payload).to include("access" => "territory_registry", "patient_id" => registration.patient_id)
    sign_in_as(registry_nurse!(care_unit!))
    get "/territory/registrations/#{registration.id}"
    expect(response).to have_http_status(:not_found)
    json_patch "/territory/registrations/#{registration.id}", body(version: 1)
    expect(response).to have_http_status(:not_found)
  end

  it "moradores do domicílio (L3) e cadastros do paciente: trilha uma por pessoa mostrada; só ids na URL" do
    first = registry_registration!(household: household)
    second = registry_registration!(household: household)
    elsewhere = registry_registration!
    sign_in_as(acs)
    expect { get "/territory/registrations", params: { household_id: household.id } }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(2)
    expect(response).to have_http_status(:ok)
    expect(json_body["registrations"].pluck("id")).to match_array([ first.id, second.id ])
    get "/territory/registrations", params: { patient_id: first.patient_id }
    expect(json_body["registrations"].pluck("id")).to eq([ first.id ])
    get "/territory/registrations", params: { patient_id: elsewhere.patient_id }
    expect(json_body["registrations"]).to eq([])
    get "/territory/registrations", params: { household_id: elsewhere.household_id }
    expect(response).to have_http_status(:not_found)
    get "/territory/registrations"
    expect(json_body).to eq("error" => "invalid_request")
  end

  it "fora de área (L7): sem domicílio, pela equipe; JSON sem microárea" do
    sign_in_as(registry_nurse!(unit, team: team))
    json_post "/territory/registrations", body(household_id: nil, team_id: team.id, patient_id: registry_patient!.id)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("household_id" => nil, "micro_area" => nil, "team" => include("id" => team.id))
  end

  it "sem IBGE no perfil da cidade: 201 e nenhuma ficha (não gerada city_profile_incomplete)" do
    CityProfile.current.update!(ibge_code: nil)
    sign_in_as(acs)
    json_post "/territory/registrations", body(patient_id: registry_patient!.id)
    expect(response).to have_http_status(:created)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual")).to be_empty
    expect(LediGenerationFailure.last.reason_codes).to eq(%w[city_profile_incomplete])
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: City.find(Current.city.id), key: "territory_registry", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(acs)
    json_post "/territory/registrations", body(patient_id: registry_patient!.id)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "territory_registry")
  end
end
