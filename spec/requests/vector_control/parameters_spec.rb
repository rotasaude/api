require "rails_helper"

# Módulo 35a, Task 14 (contrato §11, §12; A-4, A-5; Q13(8)): GET /parameters
# para a coordenação e o agente de endemias (`VectorParameterVersion` do
# dashboard; sem gravação, versão 0 com created_at null); PUT `{ values,
# expected_version }` só a coordenação, com step-up, cria a versão seguinte.
# Q34: `expected_version` é a versão que a tela leu (0 = o padrão de fábrica);
# divergiu da vigente → 409 parameters_changed e nada gravado.
RSpec.describe "Vigilância ambiental — parâmetros técnicos", type: :request do
  let!(:city) { block_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:factory) { VectorControl::Parameters.defaults }

  def put_values(values, expected_version: VectorParameterVersion.maximum(:version).to_i)
    json_put("/vector_control/parameters", values: values, expected_version: expected_version)
  end

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
    json_put "/vector_control/parameters", expected_version: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values" } ])
    json_put "/vector_control/parameters", values: factory, expected_version: 0, version: 3
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "version" } ])
    json_put "/vector_control/parameters?x=1", values: factory, expected_version: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(VectorParameterVersion.count).to eq(0)
  end

  it "expected_version ausente → 422 expected_version_required; fora de inteiro >= 0 → 422 invalid_request; nada gravado" do
    stepped_up!(coordinator)
    json_put "/vector_control/parameters", values: factory
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    json_put "/vector_control/parameters", values: factory, expected_version: nil
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    [ -1, 1.5, 0.0, "0", "", true, [ 0 ], { "v" => 0 } ].each do |value|
      json_put "/vector_control/parameters", values: factory, expected_version: value
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "expected_version" } ]), value.inspect
    end
    expect(VectorParameterVersion.count).to eq(0)
  end

  it "cidade sem versão gravada: expected_version 0 grava a 1; 1 (versão que não existe) → 409" do
    stepped_up!(coordinator)
    put_values(factory, expected_version: 1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "parameters_changed" } ])
    expect(VectorParameterVersion.count).to eq(0)

    put_values(factory.merge("ovitrap_alert_eggs" => 120), expected_version: 0)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("version" => 1, "values" => factory.merge("ovitrap_alert_eggs" => 120))
  end

  it "dois PUTs com a mesma expected_version: o primeiro grava N+1, o segundo → 409 parameters_changed e nada grava" do
    stepped_up!(coordinator)
    put_values(factory.merge("default_days" => 45), expected_version: 0)
    expect(json_body["version"]).to eq(1)

    put_values(factory.merge("ovitrap_alert_eggs" => 120), expected_version: 1)
    expect([ response.status, json_body["version"] ]).to eq([ 200, 2 ])
    put_values(factory.merge("ovitrap_alert_eggs" => 150), expected_version: 1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "parameters_changed" } ])

    expect(VectorParameterVersion.count).to eq(2)
    expect(VectorControl::Parameters.current).to have_attributes(version: 2)
    expect(VectorControl::Parameters.current.values).to include("default_days" => 60, "ovitrap_alert_eggs" => 120)
    get "/vector_control/parameters"
    expect(json_body).to include("version" => 2, "values" => factory.merge("ovitrap_alert_eggs" => 120))
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
