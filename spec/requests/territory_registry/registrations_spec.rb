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
                                            "full_name" => "Lia Santos", "mother_name" => "Carla Santos",
                                            "birth_date" => "2026-08-01", "sex" => "female", "identity_locked" => false)
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

  # Contrato §14 L28: paciente digitado com nome + nascimento de outro já
  # gravado (a mesma regra da busca de duplicados) → 409 duplicate_suspected,
  # nada gravado; com duplicates_reviewed true (só no corpo; o dashboard manda
  # depois de mostrar a busca e a pessoa escolher "é outra pessoa") → 201.
  it "paciente digitado igual a outro: 409 duplicate_suspected sem nomes e nada gravado; revisado → 201; mãe diferente → 201" do
    existing = Patient.create!(full_name: "Lia Santos", birth_date: "2026-08-01", sex: "female", no_cpf_reason: "3", cns: valid_cns(42))
    typed = { full_name: "Lía Santos", birth_date: "2026-08-01", sex: "female", mother_name: "Carla Santos", no_cpf_reason: "3",
              cns: valid_cns(43) }
    sign_in_as(acs)
    expect { json_post "/territory/registrations", body(new_patient: typed) }.not_to change(Patient, :count)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_suspected")
    expect(IndividualRegistration.count).to eq(0)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual")).to be_empty
    json_post "/territory/registrations", body(new_patient: typed, duplicates_reviewed: "true")
    expect(json_body).to eq("error" => "invalid_registration", "path" => "duplicates_reviewed")
    json_post "/territory/registrations", body(new_patient: typed, duplicates_reviewed: true)
    expect(response).to have_http_status(:created)
    expect(json_body["patient"]["id"]).not_to eq(existing.id)
    # Mãe gravada diferente: a busca de duplicados não o mostra, então não é suspeito.
    Patient.create!(full_name: "Rui Alves Lima", birth_date: "1970-01-01", sex: "male", mother_name: "Maria Lima", no_cpf_reason: "3",
                    cns: valid_cns(47))
    json_post "/territory/registrations", body(new_patient: { full_name: "Rui Alves Lima", birth_date: "1970-01-01", sex: "male",
                                                              mother_name: "Ana Alves", no_cpf_reason: "3", cns: valid_cns(44) })
    expect(response).to have_http_status(:created)
  end

  it "duplicates_reviewed só no corpo: na URL não vale" do
    Patient.create!(full_name: "Lia Santos", birth_date: "2026-08-01", sex: "female", no_cpf_reason: "3", cns: valid_cns(45))
    sign_in_as(acs)
    post "/territory/registrations?duplicates_reviewed=true",
         params: body(new_patient: { full_name: "Lia Santos", birth_date: "2026-08-01", sex: "female", no_cpf_reason: "3", cns: valid_cns(46) }).to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_suspected")
    expect(IndividualRegistration.count).to eq(0)
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

  # identity_locked do JSON segue a MESMA regra da gravação (Patients::Pairs.of):
  # par validado do CPF ainda não ligado ao paciente também trava.
  it "par validado do mesmo CPF ainda não ligado: identity_locked true no JSON e 422 identity_locked no PATCH" do
    citizen = verified_citizen!(41)
    patient = Patient.create!(cpf: citizen.cpf, full_name: "Maria Aparecida da Silva", mother_name: "Joana da Silva",
                              birth_date: "1980-05-10", sex: "female", race_color: "03")
    expect(citizen.reload.patient_id).to be_nil
    registration = registry_registration!(patient: patient, household: household)
    sign_in_as(acs)
    get "/territory/registrations/#{registration.id}"
    expect(json_body["patient"]).to include("identity_locked" => true, "has_cpf" => true)
    json_patch "/territory/registrations/#{registration.id}", body(version: 1, patient: { full_name: "Maria Aparecida Souza" })
    expect(json_body).to eq("error" => "identity_locked", "path" => "patient.full_name")
  end

  # Contrato §14 L24 (coordenadora; substitui o I2 da onda final): a validação
  # no posto depois do cadastro NUNCA grava versão nem ficha em nome de quem
  # não agiu — só marca identity_changed_at; identity_review_pending avisa a
  # equipe. A próxima gravação leva a identidade validada, em nome de quem gravou.
  it "validação no posto depois do cadastro: só a marca; a próxima gravação leva a identidade validada em nome de quem gravou" do
    nurse = registry_nurse!(unit, team: team)
    patient, citizen = exam_patient!(61, age: 40, sex: "female")
    saved = TerritoryRegistry::SaveRegistration.call(params: registry_registration_params(household, patient: patient), by: nurse)
    expect(saved).to be_ok
    registration = saved.payload[:registration]
    outbox = LediOutboxEntry.count
    citizen.update!(full_name: "Maria Aparecida Validada")
    Patients::Resolve.refresh!(patient.reload)
    registration.reload
    expect([ registration.version, registration.versions.count, LediOutboxEntry.count ]).to eq([ 1, 1, outbox ])
    expect(registration.identity_changed_at).to be > registration.registered_at

    sign_in_as(nurse)
    get "/territory/registrations/#{registration.id}"
    expect(json_body).to include("version" => 1, "identity_review_pending" => true)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"].sole).to include("registration_id" => registration.id, "status" => "valid", "identity_review_pending" => true)

    sign_in_as(acs)
    json_patch "/territory/registrations/#{registration.id}", registry_registration_params(household, patient: patient).merge("version" => 1)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("version" => 2, "identity_review_pending" => false)
    version = registration.reload.latest_version
    expect(version).to have_attributes(origin: "save", saved_by_user_id: acs.id)
    expect(version.identity).to include("full_name" => "Maria Aparecida Validada")
    entry = LediOutboxEntry.find_by!(source_id: version.id)
    header = Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_individual"), Ledi::Transport.read(entry.bytes).dadoSerializado)
                          .headerTransport
    expect(header.profissionalCNS).to eq(acs.professional.cns)
    sign_in_as(nurse)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"].sole).to include("identity_review_pending" => false)
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
