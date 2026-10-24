require "rails_helper"

# F-24.6 (contrato §6; §14 L5, L10, L12, L19): validade de 24 meses e quem
# falta cadastrar por equipe e microárea. Lista nominal com trilha (uma por
# pessoa mostrada) só para membro da equipe; contagem sem trilha, também
# para a gestão (municipal_admin, analyst).
RSpec.describe "Território — validade e quem falta cadastrar", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:team) { care_team!(unit, doctor) }
  let(:nurse) { registry_nurse!(unit, team: team) }

  def viewed = DomainEvent.where(name: "clinical_record.viewed")

  it "vencidos, a vencer e sem cadastro, com contagem sem trilha e lista com trilha por pessoa" do
    missing = care_patient!(age: 50, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    expired = travel_to(25.months.ago) { registry_registration!(household: registry_household!(micro_area: registry_micro_area!(code: "01", team: team))) }
    soon = travel_to((24.months - 30.days).ago) { registry_registration!(household: registry_household!(micro_area: MicroArea.find_by!(team: team, code: "01"))) }
    sign_in_as(nurse)
    before_count = DomainEvent.count
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to eq("valid" => 0, "due_soon" => 1, "expired" => 1, "missing" => 1, "missing_identifier" => 0)
    expect(DomainEvent.count).to eq(before_count)
    get "/territory/registry_status", params: { team_id: team.id, status: "missing" }
    expect(json_body["people"].map { |p| p["patient_id"] }).to eq([ missing.id ])
    expect(json_body["people"].first).to include("status" => "missing", "registered_at" => nil, "micro_area_code" => nil)
    get "/territory/registry_status", params: { team_id: team.id, status: "expired" }
    expect(json_body["people"].map { |p| p["registration_id"] }).to eq([ expired.id ])
    expect(json_body["people"].first).to include("status" => "expired", "micro_area_code" => "01",
                                                 "registered_at" => expired.registered_at.iso8601, "citizen_id" => nil)
    expect(viewed.last.payload["access"]).to eq("territory_registry")
    expect(soon).to be_present
  end

  it "óbito pelo cadastro sai da população; paginação com next_before; equipe alheia → 403" do
    area = registry_micro_area!(code: "01", team: team)
    living = Array.new(3) { registry_registration!(household: registry_household!(micro_area: area)) }
    # A consulta põe o falecido na equipe; a saída por óbito do cadastro o tira.
    dead = care_patient!(age: 70, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    household = registry_household!(micro_area: area)
    today = Time.zone.today.iso8601
    death = TerritoryRegistry::ExitRegistration.call(registration: registry_registration!(patient: dead, household: household),
                                                     params: { "reason" => "death", "on" => today, "death_on" => today },
                                                     by: registry_acs_of(household))
    expect(death).to be_ok
    sign_in_as(nurse)
    get "/territory/registry_status", params: { team_id: team.id, limit: 2 }
    first = json_body
    expect(first["people"].size).to eq(2)
    get "/territory/registry_status", params: { team_id: team.id, limit: 2, before: first["next_before"] }
    expect(json_body["people"].size).to eq(1)
    expect(json_body["next_before"]).to be_nil
    shown = (first["people"] + json_body["people"]).map { |p| p["patient_id"] }
    expect(shown).to match_array(living.map(&:patient_id))
    expect(shown).not_to include(dead.id)
    get "/territory/registry_status", params: { team_id: registry_team!(care_unit!).id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
  end

  it "óbito na saída do cadastro tira a pessoa da lista e da contagem (nem missing)" do
    area = registry_micro_area!(code: "01", team: team)
    household = registry_household!(micro_area: area)
    patient = care_patient!(age: 60, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    registration = registry_registration!(patient: patient, household: household)
    today = Time.zone.today.iso8601
    result = TerritoryRegistry::ExitRegistration.call(registration: registration, params: { "reason" => "death", "on" => today, "death_on" => today },
                                                      by: registry_acs_of(household))
    expect(result).to be_ok
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to eq("valid" => 0, "due_soon" => 0, "expired" => 0, "missing" => 0, "missing_identifier" => 0)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"]).to eq([])
  end

  it "saída por mudança: quem a consulta ainda põe na equipe volta a faltar cadastro" do
    household = registry_household!(micro_area: registry_micro_area!(code: "01", team: team))
    patient = care_patient!(age: 60, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    registration = registry_registration!(patient: patient, household: household)
    TerritoryRegistry::ExitRegistration.call(registration: registration, params: { "reason" => "moved", "on" => Time.zone.today.iso8601 },
                                             by: registry_acs_of(household))
    sign_in_as(nurse)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"]).to eq([ { "patient_id" => patient.id, "citizen_id" => nil, "display_name" => patient.display_name,
                                          "age" => 60, "micro_area_code" => nil, "status" => "missing", "registered_at" => nil,
                                          "registration_id" => nil } ])
  end

  it "validade conta da ÚLTIMA gravação: atualizar ontem um cadastro de 25 meses o torna válido" do
    household = registry_household!(micro_area: registry_micro_area!(code: "01", team: team))
    patient = registry_patient!
    registration = travel_to(25.months.ago) { registry_registration!(patient: patient, household: household) }
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to include("expired" => 1, "valid" => 0)
    travel_to(1.day.ago) do
      params = registry_registration_params(household, patient: patient).merge("version" => registration.reload.version)
      result = TerritoryRegistry::SaveRegistration.call(params: params, by: registry_acs_of(household), registration: registration)
      expect(result).to be_ok
    end
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to include("expired" => 0, "valid" => 1)
    get "/territory/registry_status", params: { team_id: team.id, status: "valid" }
    expect(json_body["people"].first).to include("registration_id" => registration.id,
                                                 "registered_at" => registration.reload.registered_at.iso8601)
    expect(registration.registered_at.to_date).to eq(Time.zone.today - 1)
  end

  it "sem CPF e sem CNS: missing_identifier na contagem e na lista (L5)" do
    household = registry_household!(micro_area: registry_micro_area!(code: "01", team: team))
    anonymous = registry_no_cpf_patient!(cns: nil)
    registration = registry_registration!(patient: anonymous, household: household)
    registry_registration!(patient: registry_no_cpf_patient!, household: household) # sem CPF, com CNS: válido
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to eq("valid" => 1, "due_soon" => 0, "expired" => 0, "missing" => 0, "missing_identifier" => 1)
    get "/territory/registry_status", params: { team_id: team.id, status: "missing_identifier" }
    expect(json_body["people"].map { |p| [ p["registration_id"], p["status"] ] }).to eq([ [ registration.id, "missing_identifier" ] ])
    get "/territory/registrations/#{registration.id}"
    expect(json_body["status"]).to eq("missing_identifier")
  end

  it "recusa fica fora das cinco contagens e aparece na lista com status refused" do
    household = registry_household!(micro_area: registry_micro_area!(code: "01", team: team))
    params = { "household_id" => household.id, "is_responsible" => false, "patient_id" => registry_patient!.id, "refused" => true,
               "identification" => registry_identification }
    result = TerritoryRegistry::SaveRegistration.call(params: params, by: registry_acs_of(household))
    expect(result).to be_ok
    refused = result.payload[:registration]
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body.values).to all(eq(0))
    get "/territory/registry_status", params: { team_id: team.id, status: "refused" }
    expect(json_body["people"].map { |p| p["registration_id"] }).to eq([ refused.id ])
  end

  it "par validado sem paciente aparece com citizen_id e missing; o par cujo CPF já tem paciente não duplica" do
    neighborhood = care_neighborhood!(unit)
    citizen = care_citizen!(age: 30, sex: "female", neighborhood: neighborhood)
    twin = care_citizen!(age: 31, sex: "male", neighborhood: neighborhood)
    Patient.create!(cpf: twin.cpf, full_name: "Gêmeo Digitado", birth_date: twin.birth_date, sex: "male") # a pessoa é o paciente (fora da equipe)
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to include("missing" => 1)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"]).to eq([ { "patient_id" => nil, "citizen_id" => citizen.id, "display_name" => citizen.display_name,
                                          "age" => 30, "micro_area_code" => nil, "status" => "missing", "registered_at" => nil,
                                          "registration_id" => nil } ])
    expect(viewed.last.payload).to include("person_ref" => "citizen:#{citizen.id}", "patient_id" => nil, "access" => "territory_registry")
  end

  it "paciente com consulta e cadastro na mesma equipe aparece uma vez" do
    patient = care_patient!(age: 60, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    registration = registry_registration!(patient: patient, household: registry_household!(micro_area: registry_micro_area!(code: "01", team: team)))
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to eq("valid" => 1, "due_soon" => 0, "expired" => 0, "missing" => 0, "missing_identifier" => 0)
    get "/territory/registry_status", params: { team_id: team.id }
    expect(json_body["people"].map { |p| [ p["patient_id"], p["registration_id"] ] }).to eq([ [ patient.id, registration.id ] ])
  end

  it "página que cruza de patient: para citizen: sem pular nem repetir" do
    area = registry_micro_area!(code: "01", team: team)
    patients = Array.new(2) { registry_registration!(household: registry_household!(micro_area: area)).patient_id }
    neighborhood = care_neighborhood!(unit)
    citizens = Array.new(2) { |i| care_citizen!(age: 30 + i, sex: "female", neighborhood: neighborhood).id }
    sign_in_as(nurse)
    get "/territory/registry_status", params: { team_id: team.id, limit: 3 }
    first = json_body
    expect(first["people"].first(2).map { |p| p["patient_id"] }).to eq(patients.sort.reverse)
    expect(first["next_before"]).to start_with("citizen:")
    get "/territory/registry_status", params: { team_id: team.id, limit: 3, before: first["next_before"] }
    expect(json_body["next_before"]).to be_nil
    shown = (first["people"] + json_body["people"]).map { |p| p["citizen_id"] }.compact
    expect(shown).to eq(citizens.sort.reverse)
  end

  it "uma trilha por pessoa mostrada (person_ref), nenhuma na contagem nem em página vazia; ordem por person_ref decrescente" do
    area = registry_micro_area!(code: "01", team: team)
    registrations = Array.new(3) { registry_registration!(household: registry_household!(micro_area: area)) }
    sign_in_as(nurse)
    expect { get "/territory/registry_status", params: { team_id: team.id, limit: 2 } }.to change { viewed.count }.by(2)
    shown = json_body["people"].map { |p| p["patient_id"] }
    expect(shown).to eq(registrations.map(&:patient_id).sort.reverse.first(2))
    expect(json_body["next_before"]).to eq("patient:#{shown.last}")
    expect(viewed.order(:created_at).last(2).map { |e| e.payload["person_ref"] }).to match_array(shown.map { |id| "patient:#{id}" })
    expect(viewed.last.payload).to include("user_id" => nurse.id, "access" => "territory_registry")
    expect { get "/territory/registry_status", params: { team_id: team.id, status: "expired" } }.not_to(change { viewed.count })
    expect { get "/territory/registry_status/count", params: { team_id: team.id } }.not_to(change { DomainEvent.count })
  end

  it "filtro por microárea: só os cadastros dela; quem não tem cadastro só entra sem o filtro" do
    one = registry_micro_area!(code: "01", team: team)
    two = registry_micro_area!(code: "02", team: team)
    mine = registry_registration!(household: registry_household!(micro_area: one))
    registry_registration!(household: registry_household!(micro_area: two))
    care_patient!(age: 50, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    sign_in_as(nurse)
    get "/territory/registry_status/count", params: { team_id: team.id, micro_area_id: one.id }
    expect(json_body).to eq("valid" => 1, "due_soon" => 0, "expired" => 0, "missing" => 0, "missing_identifier" => 0)
    get "/territory/registry_status", params: { team_id: team.id, micro_area_id: one.id }
    expect(json_body["people"].map { |p| p["registration_id"] }).to eq([ mine.id ])
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(json_body).to include("valid" => 2, "missing" => 1)
    get "/territory/registry_status", params: { team_id: team.id, micro_area_id: registry_micro_area!(code: "01").id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
  end

  it "ACS: só a própria microárea; sem micro_area_id ou com a de outro → 403 out_of_scope" do
    own = registry_micro_area!(code: "01", team: team)
    other = registry_micro_area!(code: "02", team: team)
    mine = registry_registration!(household: registry_household!(micro_area: own))
    registry_registration!(household: registry_household!(micro_area: other))
    acs = registry_acs_of(own)
    sign_in_as(acs)
    %w[/territory/registry_status /territory/registry_status/count].each do |path|
      get path, params: { team_id: team.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "out_of_scope")
      get path, params: { team_id: team.id, micro_area_id: other.id }
      expect(response).to have_http_status(:forbidden)
    end
    get "/territory/registry_status", params: { team_id: team.id, micro_area_id: own.id }
    expect(json_body["people"].map { |p| p["registration_id"] }).to eq([ mine.id ])
    get "/territory/registry_status/count", params: { team_id: team.id, micro_area_id: own.id }
    expect(json_body).to eq("valid" => 1, "due_soon" => 0, "expired" => 0, "missing" => 0, "missing_identifier" => 0)
  end

  it "contagem também para municipal_admin e analyst, sem trilha; lista nominal só para membro da equipe (L10)" do
    registry_registration!(household: registry_household!(micro_area: registry_micro_area!(code: "01", team: team)))
    analyst = staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst")
    [ care_admin!, analyst ].each do |manager|
      sign_in_as(manager)
      expect { get "/territory/registry_status/count", params: { team_id: team.id } }.not_to(change { DomainEvent.count })
      expect(json_body).to include("valid" => 1)
      get "/territory/registry_status", params: { team_id: team.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "out_of_scope")
    end
    outsider = registry_nurse!(care_unit!)
    sign_in_as(outsider)
    get "/territory/registry_status/count", params: { team_id: team.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "parâmetros: limit inválido → 422 invalid_limit; status, equipe e cursor inválidos → 422; equipe desconhecida → 404" do
    sign_in_as(nurse)
    get "/territory/registry_status", params: { team_id: team.id, limit: 101 }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_limit")
    get "/territory/registry_status", params: { team_id: team.id, limit: "abc" }
    expect(json_body).to eq("error" => "invalid_limit")
    get "/territory/registry_status", params: { team_id: team.id, status: "exited" }
    expect(json_body).to eq("error" => "invalid_request")
    get "/territory/registry_status", params: { team_id: team.id, before: "x" }
    expect(json_body).to eq("error" => "invalid_cursor")
    get "/territory/registry_status", params: { team_id: "nope" }
    expect(json_body).to eq("error" => "invalid_request")
    get "/territory/registry_status/count", params: { team_id: team.id, micro_area_id: "nope" }
    expect(json_body).to eq("error" => "invalid_request")
    get "/territory/registry_status", params: { team_id: SecureRandom.uuid }
    expect(response).to have_http_status(:not_found)
  end
end
