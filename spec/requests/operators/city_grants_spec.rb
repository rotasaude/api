require "rails_helper"

# Console emite o grant de entrada numa cidade para o operador verificado
# (Plano 3B). A resposta é a URL da cidade com o grant; quem consome é a cidade.
RSpec.describe "Operator city grants on the platform console", type: :request do
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) } # registrada pelo before global de request specs

  def json = JSON.parse(response.body)

  def verified_login!
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  before { host! "admin.rotasaude.app" }

  it "issues an operator grant for an active city and answers the city URL carrying it" do
    verified_login!

    expect {
      post "/city_grants", params: { city_slug: city.slug }
    }.to change(CityGrant, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(json["expires_in"]).to eq(60)
    url = URI.parse(json["redirect_url"])
    expect("#{url.scheme}://#{url.host}:#{url.port}#{url.path}").to eq("http://#{city.slug}.localhost:5175/dashboard/")
    token = Rack::Utils.parse_query(url.query).fetch("grant")
    expect(CityGrant.order(:created_at).last).to have_attributes(city_id: city.id, kind: "operator", subject_id: operator.id)
    expect(CityGrants.redeem(token: token, city: city)).to be_present
  end

  it "honours CITY_PUBLIC_BASE_TEMPLATE" do
    verified_login!
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything).and_return("https://%{slug}.rotasaude.app")

    post "/city_grants", params: { city_slug: city.slug }

    expect(json["redirect_url"]).to start_with("https://#{city.slug}.rotasaude.app/dashboard/?grant=")
  end

  it "requires a verified operator session" do
    post "/city_grants", params: { city_slug: city.slug }

    expect(response).to have_http_status(:unauthorized)
    expect(CityGrant.count).to eq(0)
  end

  it "answers 404 for an unknown city, a suspended city and a non-string slug, issuing nothing" do
    verified_login!
    suspended = create(:city, status: "suspended")

    [ "naoexiste", suspended.slug ].each do |slug|
      post "/city_grants", params: { city_slug: slug }
      expect(response).to have_http_status(:not_found)
      expect(json).to eq("error" => "unknown_city")
    end
    post "/city_grants", params: { city_slug: [ city.slug ] }
    expect(response).to have_http_status(:not_found)
    expect(CityGrant.count).to eq(0)
  end

  it "is not served on a city host" do
    post "/city_grants", params: { city_slug: city.slug }, headers: { "HOST" => "#{city.slug}.rotasaude.app" }

    expect(response).to have_http_status(:not_found)
  end
end
