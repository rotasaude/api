require "rails_helper"

RSpec.describe "Operators::CityChannels", type: :request do
  # Idioma do spec vizinho (spec/requests/operators/cities_spec.rb): NÃO existe
  # factory de operator — o operador é criado na mão —, a sessão do console é
  # login + desafio TOTP, e o host se troca com `host!`, não com header.
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let!(:city) { create(:city, status: "active") }

  def json = JSON.parse(response.body)

  def verified_login!
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  def register(params)
    post "/cities/#{city.id}/channel", params: params
  end

  before do
    host! "admin.rotasaude.app"
    verified_login!
  end

  it "registers the channel of an active city" do
    register(phone_number_id: "PNID-1", waba_id: "WABA-1",
             display_phone_number: "+551133334444", access_token: "EAAtoken")

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include("phone_number_id" => "PNID-1")
    expect(CityChannel.find_by(city_id: city.id)).to be_present
  end

  # O token do canal é segredo: a resposta não pode devolvê-lo, nem o log
  # carregá-lo (ADR-0012/0013 e a Global Constraint deste plano).
  it "never echoes the access token back" do
    register(phone_number_id: "PNID-2", waba_id: "WABA-2",
             display_phone_number: "+551133334445", access_token: "EAAsegredo")

    expect(response.body.include?("EAAsegredo")).to be(false)
  end

  it "refuses a city that is not servable" do
    city.update!(status: "suspended")
    register(phone_number_id: "PNID-3", waba_id: "WABA-3",
             display_phone_number: "+551133334446", access_token: "EAAtoken")

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to eq("city_not_servable")
  end

  it "refuses an empty access token" do
    register(phone_number_id: "PNID-4", waba_id: "WABA-4",
             display_phone_number: "+551133334447", access_token: "")

    expect(response).to have_http_status(:unprocessable_content)
  end

  # phone_number_id é único na PLATAFORMA (índice único, app/models/city_channel.rb) —
  # não por cidade. O comando mapeia a violação para :invalid
  # (MunicipalityChannels::Register); este exemplo prova que o controller
  # devolve isso como 422 com error utilizável, não um 500.
  it "refuses a duplicate phone_number_id" do
    register(phone_number_id: "PNID-DUP", waba_id: "WABA-5",
             display_phone_number: "+551133334448", access_token: "EAAtoken")
    expect(response).to have_http_status(:created)

    other_city = create(:city, status: "active")
    post "/cities/#{other_city.id}/channel",
         params: { phone_number_id: "PNID-DUP", waba_id: "WABA-6",
                    display_phone_number: "+551133334449", access_token: "EAAtoken" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to eq("invalid")
  end

  it "404s for an unknown city" do
    post "/cities/00000000-0000-0000-0000-000000000000/channel",
         params: { phone_number_id: "x", waba_id: "y", display_phone_number: "+55", access_token: "z" }

    expect(response).to have_http_status(:not_found)
  end
end
