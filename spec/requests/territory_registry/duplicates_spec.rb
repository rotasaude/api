require "rails_helper"

# Módulo 24a (contrato §5; plano, Desvio 1): possíveis duplicados do paciente
# digitado, pela chave cega (nome + nascimento) e a mãe; tudo no corpo (nada
# lido da URL); no máximo 10; trilha clinical_record.viewed por candidato.
RSpec.describe "Território — possíveis duplicados", type: :request do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:acs) { registry_acs!(unit) }

  def twin!(mother: "Rita Souza Lima")
    Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male", mother_name: mother)
  end

  it "candidatos pelo nome e nascimento (sem acento e com hífen) e pela mãe; trilha por candidato" do
    match = twin!
    other_mother = twin!(mother: "Ana Maria Lima")
    Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1961-02-01", sex: "male")
    sign_in_as(acs)
    expect { json_post "/territory/patients/duplicates", full_name: "Jose Souza-Lima", birth_date: "1960-02-01" }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(2)
    expect(response).to have_http_status(:ok)
    expect(json_body["candidates"]).to contain_exactly(
      { "patient_id" => match.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true },
      { "patient_id" => other_mother.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true }
    )
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "territory_registry")
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: "rita souza lima"
    expect(json_body["candidates"].pluck("patient_id")).to eq([ match.id ])
    # mãe que normaliza para nada conta como ausente
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: "--"
    expect(json_body["candidates"].size).to eq(2)
  end

  it "no máximo 10 candidatos" do
    11.times { twin! }
    sign_in_as(acs)
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01"
    expect(json_body["candidates"].size).to eq(10)
  end

  it "dados na query → 422 invalid_request; corpo sem nome ou data → 422; sem papel health_professional → 403; ACS de outra equipe consulta" do
    twin!
    sign_in_as(acs)
    post "/territory/patients/duplicates?full_name=Jos%C3%A9+Souza+Lima&birth_date=1960-02-01",
         params: { full_name: "José Souza Lima", birth_date: "1960-02-01" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_request")
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima"
    expect(json_body).to eq("error" => "invalid_request")
    sign_in_as(registry_acs!(care_unit!))
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01"
    expect(json_body["candidates"].size).to eq(1)
    sign_in_as(care_admin!)
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01"
    expect(response).to have_http_status(:forbidden)
  end

  # Revisão final (m3): o mesmo limite da busca por CPF (30 por minuto por usuário).
  it "limite de 30 por minuto por usuário" do
    calls = []
    allow(TerritoryRegistry::PersonLookupsController::RateLimitStore).to receive(:increment) do |key, *|
      calls << key
      31
    end
    sign_in_as(acs)
    json_post "/territory/patients/duplicates", full_name: "José Souza Lima", birth_date: "1960-02-01"
    expect([ response.status, json_body["error"] ]).to eq([ 429, "too_many_requests" ])
    expect(calls.sole).to include("territory_duplicates", acs.id)
  end
end
