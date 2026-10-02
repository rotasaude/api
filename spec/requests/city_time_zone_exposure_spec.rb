require "rails_helper"

# api#27: as telas formatam hora no fuso da cidade, então o api entrega esse
# fuso onde a tela já lê a sessão; o console escolhe o fuso ao provisionar.
RSpec.describe "Fuso da cidade nas respostas", type: :request do
  before do
    City.find_by!(slug: TEST_CITY_A.slug).update!(time_zone: "America/Manaus")
    CityCatalog.reset_cache!
  end

  it "GET /session traz o fuso da cidade do host" do
    sign_in_as(User.create!(email_address: "admin@cidade.gov.br", password: "senha-segura-123"))
    get "/session"
    expect(JSON.parse(response.body)["time_zone"]).to eq("America/Manaus")
  end

  it "a sessão do cidadão traz o fuso da cidade" do
    OtpSender::Test.reset!
    Rails.cache.clear
    json_post "/citizen/otp", phone: "(41) 99876-5432"
    json_post "/citizen/session", phone: "(41) 99876-5432", code: OtpSender::Test.deliveries.last[:code]
    expect(JSON.parse(response.body)["time_zone"]).to eq("America/Manaus")
    get "/citizen/session"
    expect(JSON.parse(response.body)["time_zone"]).to eq("America/Manaus")
  end

  describe "console da plataforma" do
    let(:password) { "s3nha-forte-1" }
    let!(:operator) do
      Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled: true)
    end
    let(:params) do
      { slug: "riobranco", name: "Rio Branco", uf: "AC", ibge_code: "1200401",
        admin_email: "prefeita@riobranco.ac.gov.br", alert_email: "alertas@riobranco.ac.gov.br" }
    end

    def json = JSON.parse(response.body)

    before do
      host! "admin.rotasaude.app"
      post "/session", params: { email_address: operator.email_address, password: password }
      post "/session/challenge", params: { session_id: json["session_id"],
                                           code: ROTP::TOTP.new(operator.otp_secret).now }
    end

    it "provisiona com o fuso escolhido e o lista" do
      on_platform_queue { post "/cities", params: params.merge(time_zone: "America/Rio_Branco") }
      expect(response).to have_http_status(:accepted)
      expect(City.find_by!(slug: "riobranco").time_zone).to eq("America/Rio_Branco")

      get "/cities"
      row = json["data"].find { |c| c["slug"] == "riobranco" }
      expect(row["time_zone"]).to eq("America/Rio_Branco")
    end

    it "sem fuso, nasce em America/Sao_Paulo; fuso de fora do Brasil é 422" do
      on_platform_queue { post "/cities", params: params }
      expect(City.find_by!(slug: "riobranco").time_zone).to eq("America/Sao_Paulo")

      expect { on_platform_queue { post "/cities", params: params.merge(slug: "outra", time_zone: "Europe/Lisbon") } }
        .not_to change(City, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["message"]).to include("time_zone")
    end
  end
end
