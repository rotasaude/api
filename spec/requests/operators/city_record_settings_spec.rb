require "rails_helper"

# ADR 0028 (spec 2026-10-05 §3.2; contratos §4.1/§4.2): o operador define modo,
# endereço do PEC e IBGE. O IBGE grava no city_profile do banco da cidade; um
# corpo inválido não grava nada; um evento de auditoria só.
RSpec.describe "Console: modo de prontuário da cidade", type: :request do
  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let!(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  def json = JSON.parse(response.body)
  def patch_settings(body = {}, id: city.id, **rest) = patch("/cities/#{id}/record_settings", params: body.merge(rest), as: :json)
  def audits = PlatformEvent.where(name: "city.record_settings_changed")

  before do
    host! "admin.rotasaude.app"
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
  end

  it "grava os três, IBGE no city_profile, e audita uma vez com os nomes dos campos" do
    patch_settings(record_mode: "integrated", pec_url: "https://pec.cidade.gov.br", ibge_code: "4106902")

    expect(response).to have_http_status(:ok)
    expect(json["city"]).to include("record_mode" => "integrated", "pec_url" => "https://pec.cidade.gov.br",
                                    "ibge_code" => "4106902", "city_reachable" => true)
    expect(json["city"]["features"].map { |f| f["key"] }).to eq(%w[ledi_export cadsus_lookup clinical_record])
    expect(json["city"]["features"].first).to include("enabled" => false, "usable" => false,
                                                      "missing" => [ "credential_missing:ledi" ])
    expect(CityProfile.current.ibge_code).to eq("4106902")
    expect(audits.map(&:payload)).to eq([ { "city_id" => city.id, "fields" => %w[ibge_code pec_url record_mode] } ])
    expect(audits.first.payload.to_s).not_to include("pec.cidade")
  end

  it "null e \"\" limpam PEC e IBGE; nada mudou não audita" do
    patch_settings(pec_url: "https://pec.cidade.gov.br", ibge_code: "4106902")
    patch_settings(pec_url: "", ibge_code: nil)
    expect(json["city"]).to include("pec_url" => nil, "ibge_code" => nil)
    expect { patch_settings(pec_url: nil) }.not_to change(audits, :count)
  end

  # Review Focus 1: tabela de corpos inválidos não grava nada.
  [
    [ { record_mode: "parcial" }, "invalid_record_mode" ],
    [ { record_mode: nil }, "invalid_record_mode" ],
    [ { ibge_code: "410690" }, "invalid_ibge_code" ],
    [ { ibge_code: "41.069-02" }, "invalid_ibge_code" ],
    [ { ibge_code: 4_106_902 }, "invalid_ibge_code" ],
    [ { pec_url: "http://pec.cidade.gov.br" }, "invalid_pec_url" ],
    [ { pec_url: "https://admin:senha@pec.cidade.gov.br" }, "invalid_pec_url" ],
    [ { pec_url: "https://pec.cidade.gov.br/?x=1" }, "invalid_pec_url" ],
    [ { pec_url: " " }, "invalid_pec_url" ],
    [ { ibge_code: "4106902", pec_url: "http://pec" }, "invalid_pec_url" ]
  ].each do |body, error|
    it "#{body.inspect} → 422 #{error}, nada gravado" do
      patch_settings(body)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => error)
      expect(city.reload).to have_attributes(record_mode: "off", pec_url: nil)
      expect(CityProfile.current&.ibge_code).to be_nil
      expect(audits).to be_empty
    end
  end

  it "cidade inexistente: 404 not_found" do
    patch_settings({ record_mode: "record" }, id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    expect(json).to eq("error" => "not_found")
  end

  it "IBGE com a cidade fora do ar: 503 city_unreachable e a plataforma também não muda" do
    down = create(:city)
    allow(CityConnection).to receive(:with).and_call_original
    allow(CityConnection).to receive(:with).with(down).and_raise(ActiveRecord::ConnectionNotEstablished)
    patch_settings({ ibge_code: "4106902", record_mode: "record" }, id: down.id)
    expect(response).to have_http_status(:service_unavailable)
    expect(json).to eq("error" => "city_unreachable")
    expect(down.reload.record_mode).to eq("off")
  end

  it "linha da cidade inválida por outra regra: 422 invalid_city e o IBGE do banco da cidade não muda" do
    city.update_columns(name: "")
    patch_settings(ibge_code: "4106902", record_mode: "record")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid_city")
    expect(CityProfile.current&.ibge_code).to be_nil
    expect(city.reload.record_mode).to eq("off")
    expect(audits).to be_empty
  end

  it "cidade suspensa com ibge_code: 503 city_unreachable e nada gravado" do
    suspended = create(:city, status: "suspended")
    patch_settings({ ibge_code: "4106902", record_mode: "record" }, id: suspended.id)

    expect(response).to have_http_status(:service_unavailable)
    expect(json).to eq("error" => "city_unreachable")
    expect(suspended.reload.record_mode).to eq("off")
    expect(audits).to be_empty
  end

  it "lista e ficha trazem os mesmos campos; cidade inalcançável responde 200 com city_reachable false" do
    down = create(:city, name: "Fora do Ar")
    allow(CityConnection).to receive(:with).and_call_original
    allow(CityConnection).to receive(:with).with(down).and_raise(ActiveRecord::ConnectionNotEstablished)
    get "/cities"
    row = json["data"].find { |c| c["id"] == down.id }
    expect(row).to include("name" => "Fora do Ar", "ibge_code" => nil, "city_reachable" => false, "record_mode" => "off")
    expect(row["features"].first["missing"]).to eq([ "city_unreachable" ])

    get "/cities/#{down.id}"
    expect(response).to have_http_status(:ok)
    expect(json.keys).to match_array(row.keys)
  end
end
