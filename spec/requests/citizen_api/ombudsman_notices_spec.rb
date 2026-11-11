require "rails_helper"

# Módulo 33, Task 7 (contrato §9; Q16): o aviso da ouvidoria é a quarta fonte
# da caixa do wpda — `kind: "ombudsman"`, só protocolo e tipo, com cpf_masked.
RSpec.describe "Avisos da ouvidoria na caixa do cidadão", type: :request do
  def body = JSON.parse(response.body)

  let!(:city) { ombudsman_city! }
  let(:citizen) { web_citizen! }
  let(:manifestation) { manifestation!(citizen: citizen) }

  before { Ombudsman::Notify.call(manifestation: manifestation, kind: "final_response") }

  it "lista o aviso com as chaves exatas, conta no unread_count e a leitura baixa a contagem" do
    notice = OmbudsmanNotice.sole
    sign_in_citizen(citizen.phone)

    get "/citizen/notices"
    expect(response).to have_http_status(:ok)
    item = body["notices"].find { |n| n["kind"] == "ombudsman" }
    expect(item.keys).to match_array(%w[kind id event protocol created_at read cpf_masked])
    expect(item).to include("id" => notice.id, "event" => "final_response", "protocol" => manifestation.protocol,
                            "read" => false, "cpf_masked" => nil)
    expect(item["created_at"]).to eq(notice.created_at.iso8601)
    expect(body["unread_count"]).to eq(1)

    json_post "/citizen/notices/#{notice.id}/read"
    expect(body).to eq("ok" => true)
    expect(notice.reload.read_at).to be_present

    get "/citizen/notices"
    expect(body["unread_count"]).to eq(0)
    expect(body["notices"].find { |n| n["kind"] == "ombudsman" }["read"]).to be(true)
  end

  it "quem silenciou os avisos não conta no unread_count, mas o aviso continua na lista" do
    CitizenContactPreference.create!(citizen_id: citizen.id, notices_muted: true)
    sign_in_citizen(citizen.phone)
    get "/citizen/notices"
    expect(body["notices"].map { |n| n["kind"] }).to eq([ "ombudsman" ])
    expect(body["unread_count"]).to eq(0)
  end

  it "com mais de um cidadão no telefone, o aviso leva o cpf_masked" do
    Citizen.create!(cpf: ombudsman_cpf!, phone: citizen.phone)
    sign_in_citizen(citizen.phone)
    get "/citizen/notices"
    item = body["notices"].find { |n| n["kind"] == "ombudsman" }
    expect(item["cpf_masked"]).to eq(citizen.cpf_masked)
  end

  it "aviso de outro telefone: 404 na leitura e nada muda" do
    notice = OmbudsmanNotice.sole
    sign_in_citizen("+5541990009999")
    json_post "/citizen/notices/#{notice.id}/read"
    expect(response).to have_http_status(:not_found)
    expect(notice.reload.read_at).to be_nil
  end
end
