require "rails_helper"

# Módulo 25, Task 10 (contrato §5, §10, §15 K4, K11, K12(c)): notificação
# manual da vigilância (POST /surveillance/notifications sem consultation_id),
# busca de pessoa e de duplicados da vigilância e a lista de unidades.
RSpec.describe "Vigilância — notificação manual", type: :request do
  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:unit) { create_unit("UBS Manual #{SecureRandom.hex(2)}") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:today) { Time.zone.today }

  before do
    # Curitiba: o IBGE da cidade, contra o qual residence_ibge é conferido.
    (CityProfile.current || CityProfile.new(name: "Curitiba")).update!(uf: "PR", ibge_code: "4106902")
    sign_in_as(officer)
  end

  def manual(**body)
    post "/surveillance/notifications", params: { disease_code: "dengue", suspected_on: today.iso8601, unit_id: unit.id }.merge(body).to_json,
                                        headers: json_headers
  end

  def typed(**over)
    { full_name: "Joana Ribeiro Lima", birth_date: "1985-04-12", sex: "female", mother_name: "Rita Ribeiro Lima",
      no_cpf_reason: "5", cns: valid_cns(registry_seq!) }.merge(over)
  end

  def viewed_events = DomainEvent.where(name: "clinical_record.viewed")

  it "(a) notifica paciente existente por patient_id: 201 completa, origem manual, notificador e trilha" do
    patient = surveillance_patient!(1)
    trail = viewed_events.count

    manual(patient_id: patient.id, symptoms_on: (today - 2).iso8601, suspected_on: (today - 1).iso8601)
    expect(response).to have_http_status(:created)
    notification = DiseaseNotification.find(json_body["id"])
    expect(json_body).to include("origin" => "manual", "status" => "notified", "suspected_on" => (today - 1).iso8601,
                                 "symptoms_on" => (today - 2).iso8601, "resident_elsewhere" => false, "residence_ibge" => nil,
                                 "consultation_id" => nil, "version" => 1)
    expect(json_body["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                                       "cns_masked" => patient.cns_masked)
    expect(json_body["notifier"]).to eq("name" => Screenings::Json.staff_name(officer))
    expect(json_body["unit"]).to eq("id" => unit.id, "cnes" => notification.unit_cnes, "name" => unit.name)
    expect(json_body.keys).to include("form", "events")
    # Desvio 5: a suspeita é o dia às 00:00 no fuso da cidade; o prazo conta daí.
    expect(notification.due_at).to eq((today - 1).in_time_zone + Surveillance::Catalog::DEADLINES.fetch(notification.deadline))

    new_events = viewed_events.order(:created_at).last(viewed_events.count - trail)
    expect(new_events.map(&:payload)).to eq([ { "patient_id" => patient.id, "user_id" => officer.id, "access" => "surveillance",
                                                "reason_code" => nil, "person_ref" => "patient:#{patient.id}" } ])

    manual(patient_id: patient.id)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_notified", "notification_id" => notification.id)
  end

  it "(b) par validado por citizen_id cria o paciente (patient.created) e notifica na mesma transação" do
    citizen = verified_citizen!(2)
    expect { manual(citizen_id: citizen.id) }.to change(Patient, :count).by(1).and change(DiseaseNotification, :count).by(1)
    expect(response).to have_http_status(:created)
    patient = Patient.find_by!(cpf: citizen.cpf)
    expect(json_body.dig("patient", "id")).to eq(patient.id)
    created = DomainEvent.where(name: "patient.created").last
    expect(created.payload).to include("patient_id" => patient.id, "citizen_id" => citizen.id)
  end

  it "(b) par não validado por citizen_id → 409 citizen_not_verified, sem paciente" do
    declared = screening_citizen!(3)
    expect { manual(citizen_id: declared.id) }.not_to change(Patient, :count)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "citizen_not_verified")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "(c) new_patient sem CPF, com no_cpf_reason e CNS válido: 201, has_cpf false e CNS mascarado" do
    cns = valid_cns(registry_seq!)
    expect { manual(new_patient: typed(cns: cns)) }.to change(Patient, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(json_body["patient"]).to include("has_cpf" => false, "cns_masked" => "*** **** **** #{cns[-4..]}")
    patient = Patient.find(json_body.dig("patient", "id"))
    expect(patient).to have_attributes(no_cpf_reason: "5", cpf: nil)
    expect(DomainEvent.where(name: "patient.created").last.payload).to include("patient_id" => patient.id, "user_id" => officer.id)
  end

  it "(c) new_patient com CPF: has_cpf true; CPF ou CNS já de outro paciente → 409 cpf_taken / cns_taken" do
    cpf = valid_cpf(registry_seq!)
    manual(new_patient: typed(no_cpf_reason: nil, cpf: cpf, cns: nil))
    expect(response).to have_http_status(:created)
    expect(json_body.dig("patient", "has_cpf")).to be(true)

    manual(new_patient: typed(full_name: "Outra Pessoa Silva", no_cpf_reason: nil, cpf: cpf, cns: nil))
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "cpf_taken")

    taken = valid_cns(registry_seq!)
    manual(new_patient: typed(full_name: "Terceira Pessoa Souza", cns: taken))
    expect(response).to have_http_status(:created)
    manual(new_patient: typed(full_name: "Quarta Pessoa Souza", cns: taken))
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "cns_taken")
  end

  it "(d) residente em outro município: residence_ibge ≠ o da cidade; igual ao da cidade ou malformado → 422 invalid_residence" do
    manual(patient_id: surveillance_patient!(4).id, resident_elsewhere: true, residence_ibge: "4113700") # Londrina
    expect(response).to have_http_status(:created)
    expect(json_body).to include("resident_elsewhere" => true, "residence_ibge" => "4113700")

    patient = surveillance_patient!(5)
    [ { resident_elsewhere: true, residence_ibge: "4106902" }, { resident_elsewhere: true, residence_ibge: "41139" },
      { resident_elsewhere: true }, { resident_elsewhere: false, residence_ibge: "4113700" },
      { resident_elsewhere: "sim", residence_ibge: "4113700" }, { residence_ibge: "4113700" } ].each do |residence|
      manual(patient_id: patient.id, **residence)
      expect(response).to have_http_status(:unprocessable_entity), residence.inspect
      expect(json_body).to eq("error" => "invalid_residence")
    end
    expect(DiseaseNotification.where(patient_id: patient.id).count).to eq(0)
  end

  it "(e) new_patient com nome de 2 letras → 422 invalid_patient new_patient.full_name e nenhum paciente criado" do
    expect { manual(new_patient: typed(full_name: "Jo")) }.not_to change(Patient, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_patient", "path" => "new_patient.full_name")
    expect(DiseaseNotification.count).to eq(0)

    manual(new_patient: typed(cns: "123"))
    expect(json_body).to eq("error" => "invalid_patient", "path" => "new_patient.cns")
    manual(new_patient: typed(no_cpf_reason: nil, cpf: "123", cns: nil))
    expect(json_body).to eq("error" => "invalid_patient", "path" => "new_patient.cpf")
    manual(new_patient: typed(no_cpf_reason: nil, cns: nil))
    expect(json_body).to eq("error" => "cpf_or_reason_required", "path" => "new_patient.no_cpf_reason")
    expect(Patient.count).to eq(0)
  end

  it "recusa da notificação desfaz o paciente criado na mesma requisição" do
    allow(Surveillance::CreateNotification).to receive(:call).and_return(Result.fail(:invalid_residence))
    expect { manual(new_patient: typed) }.not_to change(Patient, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_residence")
    expect(DomainEvent.where(name: "patient.created").count).to eq(0)
  end

  it "(f) profissional de saúde sem surveillance → 403; surveillance desligado → 403 feature_disabled" do
    patient = surveillance_patient!(6)
    sign_in_as(doctor!(unit))
    manual(patient_id: patient.id)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")

    sign_in_as(officer)
    Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
    manual(patient_id: patient.id)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "pessoa: exatamente uma das três; desconhecida → 422 invalid_patient com o caminho" do
    patient = surveillance_patient!(7)
    manual
    expect(json_body).to eq("error" => "invalid_patient", "path" => "patient_id")
    manual(patient_id: patient.id, citizen_id: SecureRandom.uuid)
    expect(json_body).to eq("error" => "invalid_patient", "path" => "citizen_id")
    manual(patient_id: SecureRandom.uuid)
    expect(json_body).to eq("error" => "invalid_patient", "path" => "patient_id")
    manual(patient_id: "nao-e-uuid")
    expect(json_body).to eq("error" => "invalid_patient", "path" => "patient_id")
    manual(new_patient: "Maria")
    expect(json_body).to eq("error" => "invalid_patient", "path" => "new_patient")
    manual(new_patient: typed, duplicates_reviewed: "sim")
    expect(json_body).to eq("error" => "invalid_patient", "path" => "duplicates_reviewed")
    expect(Patient.count).to eq(1)
  end

  it "doença, datas e unidade: invalid_disease, invalid_request (suspected_on), invalid_symptoms_on, invalid_unit" do
    patient = surveillance_patient!(8)
    manual(patient_id: patient.id, disease_code: "nao_existe")
    expect(json_body).to eq("error" => "invalid_disease")
    manual(patient_id: patient.id, disease_code: nil)
    expect(json_body).to eq("error" => "invalid_disease")

    [ (today + 1).iso8601, "27/10/2026", "2026-02-30", nil, 20_261_027 ].each do |value|
      manual(patient_id: patient.id, suspected_on: value)
      expect(response).to have_http_status(:unprocessable_entity), value.inspect
      expect(json_body).to eq("error" => "invalid_request", "field" => "suspected_on")
    end

    [ (today + 1).iso8601, "ontem", 5 ].each do |value|
      manual(patient_id: patient.id, symptoms_on: value)
      expect(json_body).to eq("error" => "invalid_symptoms_on")
    end
    manual(patient_id: patient.id, suspected_on: (today - 3).iso8601, symptoms_on: (today - 2).iso8601)
    expect(json_body).to eq("error" => "invalid_symptoms_on")

    inactive = create_unit("UBS Fechada #{SecureRandom.hex(2)}", active: false)
    [ SecureRandom.uuid, "nao-e-uuid", nil, inactive.id ].each do |value|
      manual(patient_id: patient.id, unit_id: value)
      expect(json_body).to eq("error" => "invalid_unit"), value.inspect
    end
    expect(DiseaseNotification.count).to eq(0)

    # qualquer unidade ativa serve, notificadora ou não; doença local ativa também.
    quiet = create_unit("Hospital Qualquer #{SecureRandom.hex(2)}", kind: "hospital")
    manual(patient_id: patient.id, unit_id: quiet.id)
    expect(response).to have_http_status(:created)
    expect(json_body.dig("unit", "id")).to eq(quiet.id)
  end

  it "dado na query não vale: sem corpo, a query não escolhe a pessoa nem a doença" do
    patient = surveillance_patient!(9)
    post "/surveillance/notifications?patient_id=#{patient.id}&disease_code=dengue", params: {}.to_json, headers: json_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_patient", "path" => "patient_id")
    expect(DiseaseNotification.count).to eq(0)
  end

  describe "new_patient e possível duplicado (K4)" do
    let!(:twin) do
      Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male",
                      mother_name: "Rita Souza Lima")
    end
    let(:same_person) { typed(full_name: "Jose Souza Lima", birth_date: "1960-02-01", sex: "male", mother_name: nil) }

    it "sem duplicates_reviewed → 409 duplicate_suspected sem nome nem candidatos; nada criado" do
      expect { manual(new_patient: same_person) }.not_to change(Patient, :count)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "duplicate_suspected")
      expect(response.body).not_to match(/Souza|Lima|#{twin.id}/)
      expect(DiseaseNotification.count).to eq(0)

      manual(new_patient: same_person, duplicates_reviewed: false)
      expect(response).to have_http_status(:conflict)
    end

    it "duplicates_reviewed: true segue: cria o paciente e notifica" do
      expect { manual(new_patient: same_person, duplicates_reviewed: true) }.to change(Patient, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(json_body.dig("patient", "id")).not_to eq(twin.id)
    end

    it "com CPF digitado, candidato de outro CPF não conta" do
      manual(new_patient: same_person.merge(no_cpf_reason: nil, cpf: valid_cpf(registry_seq!), cns: nil))
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /surveillance/person_lookup" do
    def lookup(**body) = post("/surveillance/person_lookup", params: body.to_json, headers: json_headers)

    it "(g) paciente, par validado sem paciente, ninguém; CPF só no corpo; trilha access surveillance" do
      patient = surveillance_patient!(10)
      trail = viewed_events.count
      lookup(cpf: patient.cpf)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("patient_id" => patient.id, "citizen_id" => nil, "display_name" => patient.display_name,
                              "has_cpf" => true, "cns_masked" => patient.cns_masked)
      expect(viewed_events.count).to eq(trail + 1)
      expect(viewed_events.order(:created_at).last.payload).to include("access" => "surveillance", "patient_id" => patient.id,
                                                                       "user_id" => officer.id)

      citizen = verified_citizen!(11)
      lookup(cpf: citizen.cpf)
      expect(json_body).to eq("patient_id" => nil, "citizen_id" => citizen.id, "display_name" => citizen.full_name,
                              "has_cpf" => true, "cns_masked" => nil)
      expect(viewed_events.order(:created_at).last.payload).to include("access" => "surveillance", "person_ref" => "citizen:#{citizen.id}")
      expect(Patient.where(cpf: citizen.cpf)).to be_empty # buscar não cria paciente

      declared = screening_citizen!(12)
      lookup(cpf: declared.cpf)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "citizen_not_verified")
      lookup(cpf: valid_cpf(999))
      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "person_not_found")
      lookup(cpf: "123")
      expect(json_body).to eq("error" => "invalid_cpf")
      lookup(cpf: 12_345)
      expect(json_body).to eq("error" => "invalid_cpf")
    end

    it "(g) CPF na query → 422 invalid_request, sem trilha; qualquer chave na query; sem o papel → 403" do
      patient = surveillance_patient!(13)
      trail = viewed_events.count
      post "/surveillance/person_lookup?cpf=#{patient.cpf}", params: {}.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
      post "/surveillance/person_lookup?x=1", params: { cpf: patient.cpf }.to_json, headers: json_headers
      expect(json_body).to eq("error" => "invalid_request")
      expect(viewed_events.count).to eq(trail)

      sign_in_as(doctor!(unit))
      lookup(cpf: patient.cpf)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
    end

    it "funciona sem territory_registry (o interruptor do 24a não é exigido)" do
      lookup(cpf: surveillance_patient!(14).cpf)
      expect(response).to have_http_status(:ok)
    end

    it "30 por minuto por usuário: a 31ª → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { lookup(cpf: valid_cpf(990)) }
      expect(response).to have_http_status(:not_found)
      lookup(cpf: valid_cpf(990))
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
    end
  end

  describe "POST /surveillance/patients/duplicates" do
    def duplicates(**body) = post("/surveillance/patients/duplicates", params: body.to_json, headers: json_headers)

    let!(:twin) do
      Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male",
                      mother_name: "Rita Souza Lima")
    end

    it "candidatos pelo nome e nascimento e pela mãe; forma sem cadastro territorial; trilha por candidato" do
      other_mother = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male",
                                     mother_name: "Ana Maria Lima")
      expect { duplicates(full_name: "Jose Souza-Lima", birth_date: "1960-02-01") }
        .to change { viewed_events.count }.by(2)
      expect(response).to have_http_status(:ok)
      expect(json_body["candidates"]).to contain_exactly(
        { "patient_id" => twin.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true },
        { "patient_id" => other_mother.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true }
      )
      expect(viewed_events.order(:created_at).last.payload).to include("access" => "surveillance", "user_id" => officer.id)

      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: "rita souza lima")
      expect(json_body["candidates"].pluck("patient_id")).to eq([ twin.id ])
    end

    it "no máximo 10 candidatos" do
      11.times { Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male") }
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01")
      expect(json_body["candidates"].size).to eq(10)
    end

    it "dado na query → 422 invalid_request; corpo sem nome ou data → 422; sem o papel surveillance → 403" do
      trail = viewed_events.count
      post "/surveillance/patients/duplicates?full_name=Jos%C3%A9+Souza+Lima&birth_date=1960-02-01", params: {}.to_json,
                                                                                                      headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
      duplicates(birth_date: "1960-02-01")
      expect(json_body).to eq("error" => "invalid_request")
      duplicates(full_name: "José Souza Lima", birth_date: "01/02/1960")
      expect(json_body).to eq("error" => "invalid_request")
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: 5)
      expect(json_body).to eq("error" => "invalid_request")
      expect(viewed_events.count).to eq(trail)

      sign_in_as(doctor!(unit))
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01")
      expect(response).to have_http_status(:forbidden)
    end

    it "30 por minuto por usuário: a 31ª → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { duplicates(full_name: "Fulano Inexistente", birth_date: "1990-01-01") }
      expect(response).to have_http_status(:ok)
      duplicates(full_name: "Fulano Inexistente", birth_date: "1990-01-01")
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "GET /surveillance/units" do
    it "unidades ativas com notifying, por nome, sem trilha; sem o papel → 403; desligado → feature_disabled" do
      zeta = create_unit("Zeta Hospital", kind: "hospital")
      alfa = create_unit("Alfa UBS", kind: "ubs")
      create_unit("Fechada UBS", active: false)
      zeta.update!(cnes: "1234567", notifying: true)
      trail = viewed_events.count

      get "/surveillance/units"
      expect(response).to have_http_status(:ok)
      expect(json_body["units"].pluck("name")).to eq([ "Alfa UBS", "Zeta Hospital" ])
      expect(json_body["units"]).to eq([
        { "id" => alfa.id, "cnes" => alfa.cnes, "name" => "Alfa UBS", "kind" => "ubs", "notifying" => true },
        { "id" => zeta.id, "cnes" => "1234567", "name" => "Zeta Hospital", "kind" => "hospital", "notifying" => true }
      ])
      expect(viewed_events.count).to eq(trail)

      sign_in_as(doctor!(unit))
      get "/surveillance/units"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")

      sign_in_as(officer)
      Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
      get "/surveillance/units"
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    end
  end

  it "(h) nenhum log da requisição contém CPF, nome, mãe, nascimento nem a doença" do
    patient = surveillance_patient!(20)
    cpf = valid_cpf(registry_seq!)
    cns = valid_cns(registry_seq!)
    log = capture_log do
      manual(new_patient: typed(full_name: "Zuleica Marcondes Pinto", mother_name: "Odete Marcondes Pinto", birth_date: "1977-09-08",
                                no_cpf_reason: nil, cpf: cpf, cns: cns),
             symptoms_on: (today - 1).iso8601)
      expect(response).to have_http_status(:created)
      manual(patient_id: patient.id)
      post "/surveillance/person_lookup", params: { cpf: cpf }.to_json, headers: json_headers
      post "/surveillance/patients/duplicates", params: { full_name: "Zuleica Marcondes Pinto", birth_date: "1977-09-08" }.to_json,
                                                headers: json_headers
      post "/surveillance/person_lookup?cpf=#{cpf}", params: {}.to_json, headers: json_headers
      manual(new_patient: typed(full_name: "Jo"))
    end
    expect(log).to include("disease_notifications") # o log foi capturado
    expect(log).not_to match(/#{cpf}|#{cns}|Zuleica|Marcondes|Odete|1977-09-08|dengue/i)
    expect(log).not_to include(patient.cpf)
  end
end
