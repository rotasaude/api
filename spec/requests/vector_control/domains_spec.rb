require "rails_helper"

# Módulo 35a, Task 14 (contrato §13; Q7(3), Q8, Q15, Q16(f)): GET
# /vector_control/domains devolve exatamente VectorControl::Json.domains, o
# mesmo serializador do `vector_control_domains` da referência do app (Task
# 15). O esquema é o reference-response-v1.json do contracts v1.3.0 (commit
# 2b1c24c), copiado em spec/fixtures/field_sync/v1.3.0/ (o container do
# bin/test só monta apps/api); a Task 15 passa a cópia para config/field_sync/.
RSpec.describe "Vigilância ambiental — domínios", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:contracts) { Rails.root.join("spec/fixtures/field_sync/v1.3.0") }
  let(:labels) { YAML.load_file(Rails.root.join("config/vector_control/domains.yml")) }
  let(:lists) { %w[activities work_types situations deposit_groups measure_methods risk_classes] }

  it "limits = Q7(3); só produtos ativos, carga em texto; cadências e os quatro parâmetros vigentes" do
    active = vector_product!(code: "PYR", name: "Pyriproxyfen 0,5% G", unit: "g", charge_size: "12.50")
    vector_product!(code: "OLD").update!(active: false)
    VectorCadence.create!(days: 50)
    liraa_parameters!(default_days: 45, ovitrap_collection_days_max: 12)
    sign_in_as(coordinator)

    get "/vector_control/domains"
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body["limits"]).to eq("deposit_count_max" => 999, "charges_max" => 999, "samples_max" => 99,
                                 "larvae_collected_max" => 10, "measures_max" => 20)
    expect(body["products"]).to eq([ { "id" => active.id, "code" => "PYR", "name" => "Pyriproxyfen 0,5% G", "unit" => "g",
                                       "charge_size" => "12.50", "uses" => active.uses } ])
    expect(body["cadences"]).to eq([ { "neighborhood_id" => nil, "risk_class" => nil, "strategic_point" => false, "days" => 50 } ])
    expect(body["parameters"]).to eq("default_days" => 45, "strategic_point_days" => 15, "ovitrap_collection_days_min" => 3,
                                     "ovitrap_collection_days_max" => 12)
    expect(body.slice(*lists)).to eq(labels.slice(*lists))
    expect(body).to eq(JSON.parse(VectorControl::Json.domains.to_json))
  end

  it "VectorControl::Json.domains valida contra $defs/vector_control_domains do contracts v1.3.0" do
    vector_product!(charge_size: "1.00")
    VectorCadence.create!(days: 30, risk_class: "red")
    raw = File.binread(contracts.join("reference-response-v1.json"))
    expect(Digest::SHA256.hexdigest(raw)).to eq("d2db3e6ebe806210d15f872ee2012db2db7902acaee25ee25bf028b33d26890e")
    schemer = JSONSchemer.schema(JSON.parse(raw)).ref("#/$defs/vector_control_domains")

    payload = JSON.parse(VectorControl::Json.domains.to_json)
    expect(schemer.validate(payload).map { |error| error.fetch("error") }).to eq([])
    expect(payload["products"]).not_to be_empty
  end

  it "os rótulos do domains.yml são os do domains-v1.json (vector_control) do contracts, com o B do manual (Q16(f))" do
    raw = File.binread(contracts.join("domains-v1.json"))
    expect(Digest::SHA256.hexdigest(raw)).to eq("d8b92593e29c72c36c96b64ade69d9e8f8663456bc7f5328cf4c20a9263d6038")
    vector = JSON.parse(raw).fetch("vector_control")
    expect(labels.slice(*lists)).to eq(vector.slice(*lists))
    expect(labels["deposit_groups"]).to include("code" => "B", "label" => "B — Depósito móvel")
    expect(VectorControl::Json.domains[:limits]).to eq(vector.fetch("limits").symbolize_keys)
    expect(labels.transform_values { |rows| rows.map { _1["code"] } }).to eq(
      "activities" => VectorControl::Catalog::ACTIVITIES, "work_types" => VectorControl::Catalog::WORK_TYPES,
      "situations" => VectorControl::Catalog::SITUATIONS, "deposit_groups" => VectorControl::Catalog::DEPOSIT_GROUPS,
      "measure_methods" => VectorControl::Catalog::METHODS, "risk_classes" => VectorControl::Catalog::RISK_CLASSES
    )
  end

  it "o agente de endemias e os leitores do 35a leem; o ACS → 403 missing_role" do
    [ endemic_agent!, vector_lab!, municipal_admin! ].each do |user|
      sign_in_as(user)
      get "/vector_control/domains"
      expect(response).to have_http_status(:ok)
    end
    sign_in_as(field_agent!)
    get "/vector_control/domains"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(coordinator)
    get "/vector_control/domains?x=1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end
end
