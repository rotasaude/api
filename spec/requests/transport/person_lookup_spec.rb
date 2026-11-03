require "rails_helper"

# Módulo 30, Task 5 (ADR 0048; §14 T2; preflight §4): paciente na central, na
# forma do 24a/V21 (Vaccination::{PersonLookups,Duplicates}Controller do 29):
# CPF só no corpo, trilha clinical_record.viewed por pessoa mostrada, 30 por
# minuto, só a central. A central não cria paciente por digitação (sem
# new_patient).
RSpec.describe "Transporte — busca de pessoa e duplicados", type: :request do
  let!(:city) { transport_city! }
  let(:dispatcher) { dispatcher! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }

  def lookup(body = {}, query: "", **fields) = post("/transport/person_lookup#{query}", params: body.merge(fields).to_json, headers: headers)
  def duplicates(body = {}, query: "", **fields)
    post("/transport/patients/duplicates#{query}", params: body.merge(fields).to_json, headers: headers)
  end
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload).select { |p| p["access"] == "transport" }
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }

  before { sign_in_as(dispatcher) }

  describe "POST /transport/person_lookup" do
    it "acha pelo CPF sem expor CPF nem CNS inteiros; trilha +1 por pessoa" do
      patient = transport_patient!
      lookup(cpf: patient.cpf.sub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\\1.\\2.\\3-\\4'))
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("patient_id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                              "cns_masked" => patient.cns_masked)
      expect(response.body).not_to include(patient.cpf)
      expect(response.body).not_to include(patient.cns) if patient.cns
      expect(trail).to eq([ { "patient_id" => patient.id, "user_id" => dispatcher.id, "access" => "transport", "reason_code" => nil,
                              "person_ref" => "patient:#{patient.id}" } ])
      expect(trail.to_json).not_to include(patient.cpf, patient.display_name)
    end

    it "CPF inválido → 422 invalid_cpf; sem CPF ou chave desconhecida (cns) → 422; par declarado → 409; ninguém → 404; sem trilha" do
      lookup(cpf: "123")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cpf", "cpf") ])
      lookup({})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      lookup(cns: "700000000000000")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cns") ])
      lookup(cpf: screening_citizen!(15).cpf)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
      lookup(cpf: valid_cpf(9_999))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      expect(trail).to be_empty
    end

    it "CPF na query → 422 invalid_request, nada lido da URL" do
      patient = transport_patient!
      lookup({}, query: "?cpf=#{patient.cpf}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      expect(trail).to be_empty
    end

    it "comissão e motorista → 403 missing_role; transporte desligado → 403 feature_disabled" do
      patient = transport_patient!
      [ committee!, driver_user! ].each do |user|
        sign_in_as(user)
        lookup(cpf: patient.cpf)
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      sign_in_as(dispatcher)
      Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
      lookup(cpf: patient.cpf)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "sanitary_transport" } ])
      expect(trail).to be_empty
    end

    it "30 por minuto por usuário: a 31ª → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { lookup(cpf: valid_cpf(9_998)) }
      expect(response).to have_http_status(:not_found)
      lookup(cpf: valid_cpf(9_998))
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end
  end

  describe "POST /transport/patients/duplicates" do
    it "acha o homônimo com a mesma data (forma do 25/27a/29); trilha por candidato; nada na query" do
      twin = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male",
                             mother_name: "Rita Souza Lima")
      Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1961-02-01", sex: "male",
                      mother_name: "Rita Souza Lima")
      duplicates(full_name: "Jose Souza-Lima", birth_date: "1960-02-01")
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("candidates" => [ { "patient_id" => twin.id, "display_name" => twin.display_name, "birth_date" => "1960-02-01",
                                                  "has_cpf" => true } ])
      expect(trail.map { |p| p["patient_id"] }).to eq([ twin.id ])

      duplicates({ full_name: "José Souza Lima", birth_date: "1960-02-01" }, query: "?full_name=x")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "full_name") ])
      duplicates(full_name: "José Souza Lima", birth_date: "01/02/1960")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "birth_date") ])
      expect(trail.size).to eq(1)
    end

    it "só a central" do
      sign_in_as(committee!)
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end
end
