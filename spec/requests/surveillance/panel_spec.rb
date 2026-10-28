require "rails_helper"

# Módulo 25, Task 16 (contrato §8, K7): o painel por bairro e semana. Papéis
# surveillance e analyst; agregado, sem trilha.
RSpec.describe "Vigilância — painel", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { surveillance_city! }
  let(:analyst) { staff_with("analista-#{SecureRandom.hex(2)}@cidade.gov.br", "analyst") }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let(:week) { Surveillance::EpiWeek.parse("2026-40") }

  def panel(**query) = get("/surveillance/panel", params: query)
  def trail_events = DomainEvent.where(name: "clinical_record.viewed")

  it "analyst lê 200, com o painel e sem trilha; o corpo não traz pessoa nem total" do
    5.times { panel_case!(neighborhood: centro, symptoms_on: week.starts_on, suspected_on: week.starts_on + 1) }
    panel_case!(neighborhood: nil, symptoms_on: week.starts_on, suspected_on: week.starts_on + 1)
    sign_in_as(analyst)

    # Sem casos nas 4 anteriores a média é 0: 5 casos já passam do dobro (sinal para avaliar).
    expect { panel(from_week: "2026-40", to_week: "2026-40") }.not_to change { [ trail_events.count, DomainEvent.count ] }

    expect(response).to have_http_status(:ok)
    expect(json_body).to eq(
      "weeks" => [ "2026-40" ],
      "rows" => [
        { "neighborhood" => { "id" => centro.id, "name" => "Centro" }, "counts" => [ 5 ], "signal" => [ true ] },
        { "neighborhood" => { "id" => nil, "name" => "Não informado" }, "counts" => [ nil ], "signal" => [ false ] }
      ],
      "suppressed" => true
    )
  end

  it "surveillance também lê; padrão: as 12 semanas até a anterior à corrente" do
    sign_in_as(surveillance_officer!)
    # Quarta-feira 2026-11-04 (SE 2026-44): a anterior é 2026-43; 12 semanas = 2026-32..2026-43.
    travel_to(Time.zone.local(2026, 11, 4, 10)) { panel }

    expect(response).to have_http_status(:ok)
    expect(json_body["weeks"].first).to eq("2026-32")
    expect(json_body["weeks"].last).to eq("2026-43")
    expect(json_body["weeks"].size).to eq(12)
    expect(json_body["rows"]).to eq([])
  end

  it "só to_week: 12 semanas até ela; só from_week: até a anterior à corrente" do
    sign_in_as(analyst)
    panel(to_week: "2026-12")
    expect([ json_body["weeks"].first, json_body["weeks"].last ]).to eq(%w[2026-01 2026-12])

    travel_to(Time.zone.local(2026, 11, 4, 10)) { panel(from_week: "2026-40") }
    expect(json_body["weeks"]).to eq(%w[2026-40 2026-41 2026-42 2026-43])
  end

  it "aceita 53 semanas e filtra por doença conhecida" do
    sign_in_as(analyst)
    panel(from_week: "2025-53", to_week: "2026-52", disease: "dengue")
    expect(response).to have_http_status(:ok)
    expect(json_body["weeks"].size).to eq(53)
  end

  it "health_professional → 403 missing_role; sem sessão → 401" do
    sign_in_as(doctor!(create_unit("UBS Vigia")))
    panel
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "sem sessão não lê" do
    panel
    expect(response).to have_http_status(:unauthorized)
  end

  it "intervalo invertido ou de mais de 53 semanas → 422 invalid_range" do
    sign_in_as(analyst)
    [ { from_week: "2026-01", to_week: "2027-02" }, { from_week: "2026-10", to_week: "2026-09" },
      { from_week: "2025-52", to_week: "2026-52" } ].each do |query|
      panel(**query)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_range" } ]), query.inspect
    end
  end

  it "semana malformada ou inexistente → 422 invalid_week" do
    sign_in_as(analyst)
    [ { from_week: "2026-53" }, { to_week: "26-01" }, { from_week: "" }, { to_week: "2026-00" },
      { from_week: [ "2026-01" ] } ].each do |query|
      panel(**query)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_week" } ]), query.inspect
    end
  end

  it "doença desconhecida → 422 invalid_disease" do
    sign_in_as(analyst)
    [ "febre-do-nada", "", "Dengue" ].each do |code|
      panel(from_week: "2026-40", to_week: "2026-40", disease: code)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_disease" } ]), code.inspect
    end
  end

  it "outra chave de query → 422 invalid_request" do
    sign_in_as(analyst)
    panel(from_week: "2026-40", to_week: "2026-40", cpf: "12345678909")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end
end
