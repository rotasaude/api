require "rails_helper"

# Provisionamento pelo console de plataforma (spec banco-por-cidade §4, Plano 4).
RSpec.describe "City provisioning on the platform console", type: :request do
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let(:params) do
    { slug: "novacidade", name: "Nova Cidade", uf: "PR", ibge_code: "4113700",
      admin_email: "prefeita@novacidade.gov.br", alert_email: "alertas@novacidade.gov.br" }
  end

  def json = JSON.parse(response.body)

  def verified_login!
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  before { host! "admin.rotasaude.app" }

  it "registers the city as provisioning, enqueues phase two and answers only the id" do
    verified_login!

    expect { post "/cities", params: params }
      .to change(City, :count).by(1).and have_enqueued_job(ProvisionCityJob)

    expect(response).to have_http_status(:accepted)
    city = City.find_by!(slug: "novacidade")
    expect(json).to eq("id" => city.id)
    expect(city.status).to eq("provisioning")
  end

  it "does not serve the city while it is provisioning" do
    verified_login!
    post "/cities", params: params
    CityCatalog.reset_cache!

    host! "novacidade.rotasaude.app"
    get "/admin/api/overview"

    expect(response).to have_http_status(:not_found)
  end

  it "reports the provisioning status by id, and 404 for an unknown id" do
    verified_login!
    post "/cities", params: params
    id = json["id"]

    get "/cities/#{id}"
    expect(response).to have_http_status(:ok)
    expect(json).to eq("id" => id, "slug" => "novacidade", "status" => "provisioning", "schema_version" => nil)

    get "/cities/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
    get "/cities/nao-e-uuid"
    expect(response).to have_http_status(:not_found)
  end

  it "answers 409 for a slug of an active city and 422 for invalid input, enqueuing nothing" do
    verified_login!

    expect { post "/cities", params: params.merge(slug: TEST_CITY_A.slug) }.not_to have_enqueued_job
    expect(response).to have_http_status(:conflict)
    expect(json["error"]).to eq("city_exists")

    expect { post "/cities", params: params.merge(uf: "pr") }.not_to have_enqueued_job
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
  end

  it "requires a verified operator session" do
    expect { post "/cities", params: params }.not_to change(City, :count)
    expect(response).to have_http_status(:unauthorized)

    get "/cities/#{City.find_by!(slug: TEST_CITY_A.slug).id}"
    expect(response).to have_http_status(:unauthorized)
  end

  it "is not reachable on a city host, and POST /setup/municipalities is gone" do
    host! test_city_host

    post "/cities", params: params
    expect(response).to have_http_status(:not_found)

    post "/setup/municipalities", params: params
    expect(response).to have_http_status(:not_found)
    expect(City.where(slug: "novacidade")).to be_empty
  end
end
