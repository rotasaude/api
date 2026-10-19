require "rails_helper"

# Brasão salvo, servido ao operador no host do console (prévia no admin).
RSpec.describe "Console: brasão da cidade", type: :request do
  include CoatOfArmsHelpers

  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let!(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:bytes) { coat_png(512, 512) }

  def json = JSON.parse(response.body)

  def login
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
  end

  def attach_coat
    UpdateCityIdentity.call(city: city, health_department_name: :keep, coat_of_arms: coat_upload(bytes),
                            remove_coat_of_arms: false)
  end

  before { host! "admin.rotasaude.app" }

  it "sem sessão de operador: 401" do
    get "/cities/#{city.id}/coat_of_arms"
    expect(response).to have_http_status(:unauthorized)
  end

  context "com sessão" do
    before { login }

    it "id desconhecido: 404" do
      get "/cities/#{SecureRandom.uuid}/coat_of_arms"
      expect(response).to have_http_status(:not_found)
    end

    it "cidade sem brasão: 404" do
      get "/cities/#{city.id}/coat_of_arms"
      expect(response).to have_http_status(:not_found)
    end

    it "com brasão: 200, bytes, e cabeçalhos privados" do
      attach_coat
      get "/cities/#{city.id}/coat_of_arms"

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(bytes)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"].split(/,\s*/)).to contain_exactly("private", "max-age=31536000", "immutable")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "serve também cidade em provisionamento" do
      attach_coat
      city.update_columns(status: "provisioning")
      get "/cities/#{city.id}/coat_of_arms"
      expect(response).to have_http_status(:ok)
    end

    it "arquivo sumido do storage: 404, não 500" do
      attach_coat
      allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_raise(ActiveStorage::FileNotFoundError)
      get "/cities/#{city.id}/coat_of_arms"
      expect(response).to have_http_status(:not_found)
    end
  end
end
