require "rails_helper"

# F-01.5 (lado de leitura): o console de plataforma lista os phone_number_id
# que chegaram sem CityChannel (Whatsapp::Ingest → UnknownChannel.record!).
# Setup no idioma de spec/requests/operators/city_channels_spec.rb: operador
# criado na mão, login + desafio TOTP, host trocado com `host!`.
RSpec.describe "Operators::UnknownChannels", type: :request do
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  def json = JSON.parse(response.body)

  def verified_login!
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  def change_for(pnid, display: "+5541300000000")
    {
      "field" => "messages",
      "value" => {
        "messaging_product" => "whatsapp",
        "metadata" => { "phone_number_id" => pnid, "display_phone_number" => display }
      }
    }
  end

  before { host! "admin.rotasaude.app" }

  it "lists unknown channels newest-seen first, with only whitelisted keys" do
    older = UnknownChannel.record!(phone_number_id: "PNID-OLD", change: change_for("PNID-OLD"))
    older.update!(last_seen_at: 2.days.ago, first_seen_at: 3.days.ago)
    newer = UnknownChannel.record!(phone_number_id: "PNID-NEW", change: change_for("PNID-NEW", display: "+5541311111111"))
    UnknownChannel.record!(phone_number_id: "PNID-NEW", change: change_for("PNID-NEW", display: "+5541311111111"))
    UnknownChannel.create!(phone_number_id: "PNID-BARE", sample_change: {}, hits: 1,
                           first_seen_at: 5.days.ago, last_seen_at: 4.days.ago)
    verified_login!

    get "/unknown_channels"

    expect(response).to have_http_status(:ok)
    expect(json.keys).to eq(%w[unknown_channels])
    rows = json["unknown_channels"]
    expect(rows.map { |r| r["phone_number_id"] }).to eq(%w[PNID-NEW PNID-OLD PNID-BARE])
    rows.each do |row|
      expect(row.keys).to match_array(%w[phone_number_id display_phone_number hits first_seen_at last_seen_at])
    end
    expect(rows.first).to include("display_phone_number" => "+5541311111111", "hits" => 2,
                                  "last_seen_at" => newer.reload.last_seen_at.iso8601)
    expect(rows.last["display_phone_number"]).to be_nil
    # sample_change nunca sai inteiro
    expect(response.body).not_to include("messaging_product")
  end

  it "caps the list at 100 rows" do
    now = Time.current
    UnknownChannel.insert_all(Array.new(101) do |i|
      { phone_number_id: "PNID-#{i}", sample_change: {}, hits: 1, first_seen_at: now, last_seen_at: now - i.minutes }
    end)
    verified_login!

    get "/unknown_channels"

    expect(json["unknown_channels"].size).to eq(100)
    expect(json["unknown_channels"].map { |r| r["phone_number_id"] }).not_to include("PNID-100")
  end

  it "requires a verified operator session" do
    get "/unknown_channels"

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "unauthenticated")
  end

  it "is not reachable on a city host" do
    host! test_city_host

    get "/unknown_channels"

    expect(response).to have_http_status(:not_found)
  end
end
