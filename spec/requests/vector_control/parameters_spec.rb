require "rails_helper"

# Módulo 35a, Task 14 (contrato §11, §12; A-4, A-5; Q13(8)): GET /parameters
# para a coordenação e o agente de endemias (`VectorParameterVersion` do
# dashboard; sem gravação, versão 0 com created_at null); PUT `{ values }` só
# a coordenação, com step-up, cria a versão seguinte.
RSpec.describe "Vigilância ambiental — parâmetros técnicos", type: :request do
  let!(:city) { block_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:factory) { VectorControl::Parameters.defaults }

  def put_values(values) = json_put("/vector_control/parameters", values: values)

  it "GET do agente → 200; sem versão → version 0, o padrão de fábrica e created_at null" do
    sign_in_as(endemic_agent!)
    get "/vector_control/parameters"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("version" => 0, "values" => factory, "created_at" => nil)
  end

  it "PUT sem step-up → 401 mfa_required; com → 200 e a versão 1; o GET a lê" do
    sign_in_as(coordinator)
    put_values(factory.merge("ovitrap_alert_eggs" => 120))
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(VectorParameterVersion.count).to eq(0)

    stepped_up!(coordinator)
    put_values(factory.merge("ovitrap_alert_eggs" => 120))
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body).to include("version" => 1, "values" => factory.merge("ovitrap_alert_eggs" => 120))
    expect(Time.iso8601(body.fetch("created_at"))).to be_within(1.minute).of(Time.current)

    get "/vector_control/parameters"
    expect(json_body).to eq(body)

    put_values(factory)
    expect(json_body["version"]).to eq(2)
  end

  it "valor fora da faixa → 422 invalid_parameter com o path da chave, só error e path" do
    stepped_up!(coordinator)
    put_values(factory.merge("ovitrap_alert_eggs" => 0))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values.ovitrap_alert_eggs" } ])
    put_values(factory.except("iip_bands"))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values.iip_bands" } ])
    json_put "/vector_control/parameters", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values" } ])
    json_put "/vector_control/parameters", values: factory, version: 3
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "version" } ])
    json_put "/vector_control/parameters?x=1", values: factory
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(VectorParameterVersion.count).to eq(0)
  end

  it "agente → 403 no PUT; laboratório e ACS → 403 também no GET" do
    agent = endemic_agent!
    stepped_up!(agent)
    put_values(factory)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    [ vector_lab!, field_agent! ].each do |user|
      sign_in_as(user)
      get "/vector_control/parameters"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
    expect(VectorParameterVersion.count).to eq(0)
  end
end
