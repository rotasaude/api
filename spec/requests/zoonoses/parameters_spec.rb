require "rails_helper"

# Módulo 35b, Task 16 (contrato §9, §10, Q18, Q32, Q34; molde do 35a): GET
# /zoonoses/parameters para reader? (versão 0 = defaults.yml, created_at null);
# PUT `{ values, expected_version }` só a coordenação, com step-up, cria a
# versão seguinte. Divergiu da vigente → 409 parameters_changed.
RSpec.describe "Zoonoses — parâmetros técnicos", type: :request do
  let!(:city) { zoonoses_city! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:factory) { Zoonoses::Parameters.defaults }

  def put_values(values, expected_version: ZoonosesParameterVersion.maximum(:version).to_i)
    json_put("/zoonoses/parameters", values: values, expected_version: expected_version)
  end

  it "GET da equipe e do municipal_admin → 200; sem versão → version 0, o padrão de fábrica e created_at null" do
    [ zoonoses_team!, zoonoses_admin ].each do |user|
      sign_in_as(user)
      get "/zoonoses/parameters"
      expect([ response.status, json_body ]).to eq([ 200, { "version" => 0, "values" => factory, "created_at" => nil } ])
    end
    sign_in_as(staff_with("almox-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/parameters"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "zoonoses_team PUT → 403; lê → 200; gate desligado → 403 feature_disabled" do
    team = zoonoses_team!
    stepped_up!(team)
    put_values(factory)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "/zoonoses/parameters"
    expect(response).to have_http_status(:ok)
    expect(ZoonosesParameterVersion.count).to eq(0)

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/zoonoses/parameters"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  it "PUT sem step-up → 401 mfa_required; com → 200 e a versão 1, evento só com ids; o GET a lê" do
    sign_in_as(coordinator)
    put_values(factory.merge("observation_days" => 14))
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(ZoonosesParameterVersion.count).to eq(0)

    stepped_up!(coordinator)
    put_values(factory.merge("observation_days" => 14, "rabies_coverage_target" => 1, "dog_population_estimate" => 1200))
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body).to include("version" => 1)
    expect(body["values"]).to eq(factory.merge("observation_days" => 14, "rabies_coverage_target" => 1.0, "dog_population_estimate" => 1200))
    expect(Time.iso8601(body.fetch("created_at"))).to be_within(1.minute).of(Time.current)
    row = ZoonosesParameterVersion.sole
    expect(DomainEvent.where(name: "zoonoses_parameters.changed").sole.payload)
      .to eq("zoonoses_parameter_version_id" => row.id, "user_id" => coordinator.id)

    get "/zoonoses/parameters"
    expect(json_body).to eq(body)
    put_values(factory)
    expect(json_body["version"]).to eq(2)
  end

  it "observation_days 9 → 422 path values.observation_days; 31 → idem" do
    stepped_up!(coordinator)
    [ 9, 31, "10", nil ].each do |days|
      put_values(factory.merge("observation_days" => days))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values.observation_days" } ])
    end
    expect(ZoonosesParameterVersion.count).to eq(0)
    put_values(factory.merge("observation_days" => 10))
    expect(response).to have_http_status(:ok)
    put_values(factory.merge("observation_days" => 30))
    expect(response).to have_http_status(:ok)
  end

  it "as outras faixas e as chaves exatas, só o primeiro erro" do
    stepped_up!(coordinator)
    {
      "collar_months" => [ 0, 13 ], "leish_focus_min_dogs" => [ 9, 1001 ], "dogs_per_block" => [ 0, 101 ],
      "rabies_coverage_target" => [ 0.09, 1.01 ], "dog_population_estimate" => [ -1, 1.5, "7" ],
      "cat_population_estimate" => [ -1 ]
    }.each do |key, bad_values|
      bad_values.each do |value|
        put_values(factory.merge(key => value))
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values.#{key}" } ]), "#{key}=#{value.inspect}"
      end
    end
    put_values(factory.except("dogs_per_block"))
    expect(json_body).to eq("error" => "invalid_parameter", "path" => "values.dogs_per_block")
    put_values(factory.merge("leish_expected_prevalence" => 2))
    expect(json_body).to eq("error" => "invalid_parameter", "path" => "values.leish_expected_prevalence")
    json_put "/zoonoses/parameters", expected_version: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values" } ])
    json_put "/zoonoses/parameters", values: factory, expected_version: 0, version: 3
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "version" } ])
    json_put "/zoonoses/parameters?x=1", values: factory, expected_version: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    put_values(factory.merge("cat_population_estimate" => nil, "dog_population_estimate" => 0))
    expect(response).to have_http_status(:ok)
    expect(ZoonosesParameterVersion.count).to eq(1)
    [ [ "collar_months", 1 ], [ "collar_months", 12 ], [ "leish_focus_min_dogs", 10 ], [ "leish_focus_min_dogs", 1000 ],
      [ "dogs_per_block", 1 ], [ "dogs_per_block", 100 ], [ "rabies_coverage_target", 0.1 ], [ "rabies_coverage_target", 1 ] ].each do |key, value|
      put_values(factory.merge(key => value))
      expect(response).to have_http_status(:ok), "#{key}=#{value}"
    end
    expect(ZoonosesParameterVersion.count).to eq(9)
  end

  it "tabela da amostra: o padrão de fábrica passa; população decrescente, amostra maior e linha torta → path leish_sample_table" do
    stepped_up!(coordinator)
    table = factory.fetch("leish_sample_table")
    expect(table.first).to include("min_population" => 500)
    expect(table.last).to include("a_conferir" => true)
    put_values(factory)
    expect(response).to have_http_status(:ok)
    expect(json_body["values"]["leish_sample_table"]).to eq(table)

    bad = {
      "decrescente" => [ { "population" => 700, "sample" => 300 }, { "population" => 600, "sample" => 200 } ],
      "igual" => [ { "population" => 700, "sample" => 300 }, { "population" => 700, "sample" => 301 } ],
      "amostra maior" => [ { "population" => 100, "sample" => 101 } ],
      "vazia" => [],
      "não é lista" => { "population" => 100, "sample" => 50 },
      "linha não é objeto" => [ 100 ],
      "decimal" => [ { "population" => 100.5, "sample" => 50 } ],
      "chave a mais" => [ { "population" => 100, "sample" => 50, "x" => 1 } ],
      "falta amostra" => [ { "population" => 100 } ],
      "a_conferir texto" => [ { "population" => 100, "sample" => 50, "a_conferir" => "true" } ],
      "min_population acima da população" => [ { "population" => 100, "sample" => 50, "min_population" => 101 } ],
      "min_population zero" => [ { "population" => 100, "sample" => 50, "min_population" => 0 } ],
      "min_population na segunda linha" => [ { "population" => 100, "sample" => 50 },
                                             { "population" => 200, "sample" => 80, "min_population" => 150 } ]
    }
    bad.each do |name, rows|
      put_values(factory.merge("leish_sample_table" => rows))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_parameter", "path" => "values.leish_sample_table" } ]), name
    end
    put_values(factory.merge("leish_sample_table" => [ { "population" => 100, "sample" => 100, "min_population" => 100, "a_conferir" => false } ]))
    expect(response).to have_http_status(:ok)
  end

  it "expected_version ausente → 422 expected_version_required; fora de inteiro >= 0 → invalid_request; versão velha → 409 parameters_changed" do
    stepped_up!(coordinator)
    json_put "/zoonoses/parameters", values: factory
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    [ -1, 1.5, "0", true ].each do |value|
      json_put "/zoonoses/parameters", values: factory, expected_version: value
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "expected_version" } ])
    end

    put_values(factory.merge("collar_months" => 5), expected_version: 0)
    expect(json_body["version"]).to eq(1)
    put_values(factory.merge("collar_months" => 4), expected_version: 0)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "parameters_changed" } ])
    expect(ZoonosesParameterVersion.pluck(:version)).to eq([ 1 ])
    expect(DomainEvent.where(name: "zoonoses_parameters.changed").count).to eq(1)
  end

  # A versão nova vale para o que nasce depois dela: a observação guarda o
  # ends_on da abertura (Task 12).
  it "a versão nova muda o ends_on das observações abertas depois dela, não das já abertas" do
    Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
    officer = surveillance_officer!
    exposure = Time.zone.today - 2
    form = { "animal_species" => "dog", "animal_condition" => "healthy", "animal_observable" => "true", "exposure_on" => exposure.iso8601,
             "animal_tutor_name" => "Tutor Marcado Mordida", "animal_tutor_phone" => "41999990000", "animal_address" => "Rua das Palmeiras, 45" }
    open_observation = lambda do
      notification = notification!(patient: tutor!, disease_code: Zoonoses::Catalog::OBSERVATION_DISEASE)
      saved = Surveillance::SaveForm.call(notification: notification.reload, form: notification.form.merge(form),
                                          version: notification.version, by: officer)
      expect(saved).to be_ok
      CityConnection.with(city) { Zoonoses::OpenObservation.call(notification: notification.reload, parameters: Zoonoses::Parameters.current.values) }
      BiteObservation.find_by!(disease_notification_id: notification.id)
    end

    before_put = open_observation.call
    expect(before_put.ends_on).to eq(exposure + 10)

    stepped_up!(coordinator)
    put_values(factory.merge("observation_days" => 20))
    expect(response).to have_http_status(:ok)

    after_put = open_observation.call
    expect(after_put.ends_on).to eq(exposure + 20)
    expect(before_put.reload.ends_on).to eq(exposure + 10)
  end
end
