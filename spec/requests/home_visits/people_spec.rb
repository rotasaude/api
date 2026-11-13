require "rails_helper"

# Módulo 24b (ADR 0052; contrato §5, §13; Desvio 4/A-8; Q8, Q21): as buscas
# de pessoa da visita e da atividade coletiva, no padrão do
# Vaccination::PersonLookupsController (27a/29): CPF ou CNS só no corpo,
# 404 person_not_found, 409 citizen_not_verified, par validado vira paciente;
# a forma ganha birth_date e sex, e os candidatos do duplicado ganham sex e
# has_cns. Trilha por pessoa mostrada; 30 por minuto por usuário; só quem
# registra no módulo.
RSpec.describe "Visita domiciliar e atividade coletiva — buscas de pessoa", type: :request do
  let!(:city) { home_visit_city!(collective: true) }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:clerk) { field_agent!(cbo: "225225", team: team) }

  def json_headers = { "CONTENT_TYPE" => "application/json" }
  def search(base, action, body = {}, query: "", **fields)
    post("/#{base}/people/#{action}#{query}", params: body.merge(fields).to_json, headers: json_headers)
  end
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  def person_shape(patient)
    { "patient_id" => patient.id, "display_name" => patient.display_name, "birth_date" => patient.birth_date, "sex" => patient.sex,
      "has_cpf" => patient.cpf.present?, "cns_masked" => patient.cns_masked }
  end

  describe "/home_visits/people/*" do
    before { sign_in_as(acs) }

    it "lookup por CPF → paciente com birth_date, has_cpf, cns_masked e trilha" do
      patient = registry_patient!
      search("home_visits", "lookup", cpf: patient.cpf)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(person_shape(patient))
      expect(json_body).to include("has_cpf" => true, "sex" => "female")
      expect(response.body).not_to include(patient.cpf)
      expect(trail).to eq([ { "access" => "home_visits", "patient_id" => patient.id, "user_id" => acs.id, "reason_code" => nil,
                              "person_ref" => "patient:#{patient.id}" } ])

      typed = registry_no_cpf_patient!(cns: valid_cns(5))
      search("home_visits", "lookup", cns: typed.cns)
      expect(json_body).to eq(person_shape(typed))
      expect(response.body).not_to include(typed.cns)
    end

    it "par validado sem paciente vira paciente; ninguém → 404 person_not_found; par só declarado → 409 citizen_not_verified" do
      citizen = verified_citizen!(21)
      expect { search("home_visits", "lookup", cpf: citizen.cpf) }.to change(Patient, :count).by(1)
      expect(json_body["patient_id"]).to eq(Patient.find_by!(cpf: citizen.cpf).id)
      trail_size = trail.size

      search("home_visits", "lookup", cpf: valid_cpf(9_990))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      search("home_visits", "lookup", cpf: screening_citizen!(22).cpf)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
      search("home_visits", "lookup", cpf: "123")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cpf", "path" => "cpf" } ])
      search("home_visits", "lookup", cns: "123")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cns", "path" => "cns" } ])
      search("home_visits", "lookup", {})
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cpf" } ])
      expect(trail.size).to eq(trail_size)
    end

    it "CPF na query → 422 invalid_request, nada lido da URL nem logado" do
      patient = registry_patient!
      search("home_visits", "lookup", {}, query: "?cpf=#{patient.cpf}")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      search("home_visits", "duplicates", { full_name: patient.full_name, birth_date: patient.birth_date }, query: "?x=1")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(trail).to be_empty

      log = capture_log { search("home_visits", "lookup", cpf: patient.cpf) }
      expect(log.lines.grep(/Parameters/).join).to include("FILTERED")
      [ patient.cpf, patient.full_name ].each { |secret| expect(log).not_to include(secret) }
    end

    it "duplicates → candidatos com sex e has_cns (até 10), trilha por candidato; nascimento inválido → 422" do
      no_cpf = registry_no_cpf_patient!(cns: valid_cns(6)).tap { |typed| typed.update!(full_name: "Lia Santos Moura", birth_date: "1990-05-06") }
      search("home_visits", "duplicates", full_name: "Lia Santos-Moura", birth_date: "1990-05-06")
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("candidates" => [ { "patient_id" => no_cpf.id, "display_name" => "Lia Santos Moura", "birth_date" => "1990-05-06",
                                                 "sex" => "female", "has_cpf" => false, "has_cns" => true } ])
      expect(trail.map { |payload| payload["patient_id"] }).to eq([ no_cpf.id ])

      search("home_visits", "duplicates", full_name: "Lia Santos Moura", birth_date: "06/05/1990")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "birth_date" } ])
      search("home_visits", "duplicates", full_name: 12, birth_date: "1990-05-06")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "full_name" } ])
    end

    it "31ª busca no minuto → 429 too_many_requests" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { search("home_visits", "lookup", cpf: valid_cpf(9_991)) }
      expect(response).to have_http_status(:not_found)
      search("home_visits", "lookup", cpf: valid_cpf(9_991))
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end

    it "enfermeiro (não registra visita) → 403 cbo_not_allowed; interruptor desligado → 403 feature_disabled" do
      patient = registry_patient!
      sign_in_as(nurse)
      %w[lookup duplicates].each do |action|
        search("home_visits", action, cpf: patient.cpf, full_name: patient.full_name, birth_date: patient.birth_date)
        expect([ action, response.status, json_body ]).to eq([ action, 403, { "error" => "cbo_not_allowed" } ])
      end
      expect(trail).to be_empty

      sign_in_as(acs)
      Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      search("home_visits", "lookup", cpf: patient.cpf)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])
    end
  end

  describe "/collective_activities/people/*" do
    before { sign_in_as(nurse) }

    it "lookup por CPF → a mesma forma, trilha access collective_activities; ninguém → 404 person_not_found" do
      patient = registry_patient!
      search("collective_activities", "lookup", cpf: patient.cpf)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(person_shape(patient))
      expect(trail).to eq([ { "access" => "collective_activities", "patient_id" => patient.id, "user_id" => nurse.id, "reason_code" => nil,
                              "person_ref" => "patient:#{patient.id}" } ])

      search("collective_activities", "lookup", cns: valid_cns(7))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      search("collective_activities", "lookup", {}, query: "?cpf=#{patient.cpf}")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    end

    it "duplicates → candidatos com sex e has_cns e trilha; 31ª → 429" do
      twin = registry_no_cpf_patient!(cns: valid_cns(8)).tap { |typed| typed.update!(full_name: "Rui Prado Lopes", birth_date: "1970-01-02") }
      search("collective_activities", "duplicates", full_name: "Rui Prado Lopes", birth_date: "1970-01-02", mother_name: nil)
      expect(json_body["candidates"].map { |candidate| candidate.slice("patient_id", "sex", "has_cns") })
        .to eq([ { "patient_id" => twin.id, "sex" => "female", "has_cns" => true } ])
      expect(trail.sole).to include("access" => "collective_activities", "patient_id" => twin.id)

      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { search("collective_activities", "duplicates", full_name: "Ninguém Aqui", birth_date: "1970-01-02") }
      expect(response).to have_http_status(:ok)
      search("collective_activities", "duplicates", full_name: "Ninguém Aqui", birth_date: "1970-01-02")
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end

    it "CBO fora da Tabela 5 → 403 cbo_not_allowed; interruptor desligado → 403 feature_disabled" do
      expect(CollectiveActivities::Catalog::CBOS).not_to include("225225")
      patient = registry_patient!
      sign_in_as(clerk)
      %w[lookup duplicates].each do |action|
        search("collective_activities", action, cpf: patient.cpf, full_name: patient.full_name, birth_date: patient.birth_date)
        expect([ action, response.status, json_body ]).to eq([ action, 403, { "error" => "cbo_not_allowed" } ])
      end
      expect(trail).to be_empty

      sign_in_as(nurse)
      Platform::Features.set!(city: city, key: CollectiveActivities::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      search("collective_activities", "lookup", cpf: patient.cpf)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "collective_activities" } ])
    end
  end
end
