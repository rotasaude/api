# spec/requests/operators/city_analytics_spec.rb
require "rails_helper"

# Contratos §2 (ADR 0025): o console do operador lê só city_analytics_indicators
# e o catálogo de cidades — cidades × semanas × indicadores —, nunca o banco de
# uma cidade.
RSpec.describe "GET /city_analytics (console do operador)", type: :request do
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let(:today) { Time.zone.today }
  let(:last_week) { today.beginning_of_week - 7 }
  let!(:curitiba) { create(:city, name: "Curitiba", uf: "PR") }
  let!(:maringa) { create(:city, name: "Maringá", uf: "PR") }
  let!(:archived) { create(:city, name: "Arquivada", status: "archived") }

  def json = JSON.parse(response.body)

  def verified_login!
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  def indicator!(city, week, indicator, value, suppressed: false)
    CityAnalyticsIndicator.create!(city: city, week_start: week, indicator: indicator, value: value,
                                   suppressed: suppressed, published_at: Time.current)
  end

  def city_json(city) = json["data"]["cities"].find { |row| row["slug"] == city.slug }

  before { host! "admin.rotasaude.app" }

  it "sem from/to: as 12 semanas que terminam na anterior à atual; só cidades ativas, por nome; valores alinhados" do
    verified_login!
    indicator!(curitiba, last_week, "triages_started", 128)
    indicator!(curitiba, last_week, "no_show_pct", 12.5)
    indicator!(curitiba, last_week - 7, "triages_started", nil, suppressed: true)
    indicator!(curitiba, last_week - 7 * 20, "triages_started", 99) # fora das 12 semanas
    indicator!(maringa, last_week, "wait_within_30_pct", 70)

    get "/city_analytics"

    expect(response).to have_http_status(:ok)
    data = json["data"]
    expect(data["weeks"]).to eq(((last_week - 77)..last_week).step(7).map(&:iso8601))
    expect(data["indicators"]).to eq(CityAnalyticsIndicator::INDICATORS)
    slugs = data["cities"].map { |row| row["slug"] }
    expect(slugs).to include(curitiba.slug, maringa.slug)
    expect(slugs).not_to include(archived.slug)
    expect(slugs.index(curitiba.slug)).to be < slugs.index(maringa.slug)
    expect(city_json(curitiba)).to include("id" => curitiba.id, "name" => "Curitiba", "uf" => "PR")
    expect(city_json(curitiba)["values"].keys).to eq(CityAnalyticsIndicator::INDICATORS)
    expect(city_json(curitiba)["values"]["triages_started"]).to eq([ nil ] * 10 + [ { "suppressed" => true }, 128 ])
    expect(city_json(curitiba)["values"]["no_show_pct"].last).to eq(12.5)
    expect(city_json(curitiba)["last_published_at"]).to match(/\A\d{4}-\d{2}-\d{2}T.*Z\z/)
    expect(city_json(maringa)["values"]["wait_within_30_pct"].last).to eq(70.0)
    expect(city_json(maringa)["values"]["triages_started"]).to all(be_nil)
  end

  it "from/to escolhem as semanas pela segunda-feira; até 104; inválido é 422 invalid_range" do
    verified_login!

    get "/city_analytics", params: { from: (last_week + 2).iso8601, to: (last_week + 3).iso8601 }
    expect(json["data"]["weeks"]).to eq([ last_week.iso8601 ])

    [
      { from: last_week.iso8601 },
      { from: "2026-02-30", to: last_week.iso8601 },
      { from: last_week.iso8601, to: (last_week - 7).iso8601 },
      { from: (last_week - 7 * 104).iso8601, to: last_week.iso8601 }
    ].each do |params|
      get "/city_analytics", params: params
      expect(response).to have_http_status(:unprocessable_entity), params.inspect
      expect(json).to eq("error" => "invalid_range")
    end
  end

  it "exatamente 104 semanas: aceito" do
    verified_login!

    get "/city_analytics", params: { from: (last_week - 7 * 103).iso8601, to: last_week.iso8601 }

    expect(response).to have_http_status(:ok)
    expect(json["data"]["weeks"].size).to eq(104)
    expect(json["data"]["weeks"].values_at(0, -1)).to eq([ (last_week - 7 * 103).iso8601, last_week.iso8601 ])
  end

  it "sem sessão de operador: 401; no host de uma cidade: 404" do
    get "/city_analytics"
    expect(response).to have_http_status(:unauthorized)

    host! test_city_host
    get "/city_analytics"
    expect(response).to have_http_status(:not_found)
  end

  it "nunca abre o banco de uma cidade" do
    verified_login!
    indicator!(curitiba, last_week, "triages_started", 128)
    allow(CityConnection).to receive(:with).and_call_original

    get "/city_analytics"

    expect(response).to have_http_status(:ok)
    expect(CityConnection).not_to have_received(:with)
  end
end
