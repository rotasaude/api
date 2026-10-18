require "rails_helper"

# Contrato §4 e C12 do dashboard (F-21.31): rodada do programa externo com
# itens por analito (enviado, alvo, faixa aceitável, adequação, ação
# obrigatória no inadequado), relatório anual em PDF (envio e leitura no
# próprio /lab/eqa); adequação por analito no ano; liberador ligado, RT ou admin.
RSpec.describe "CEQ — rodadas", type: :request do
  before { qc_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:pdf) { Base64.strict_encode64("%PDF-1.4\n% relatório anual\n%%EOF") }

  def item(adequacy: "adequate", action: nil, submitted: "98.5")
    { analyte_key: "glicose", lab_exam_id: exam.id, submitted: submitted, target: "100", acceptable_low: "90", acceptable_high: "110",
      adequacy: adequacy, action: action }
  end

  def round(code, items, date: "2026-03-10", upload_id: nil)
    json_post "/lab/eqa/rounds", provider_id: provider.id, program: "PNCQ", round_code: code, round_date: date, items: items,
                                 annual_report_upload_id: upload_id
  end

  it "registra rodadas, anexa e lê o relatório anual e resume a adequação do ano" do
    stepped_up!(lead)
    json_post "/lab/eqa/uploads", content_type: "application/pdf", data: pdf
    expect(response).to have_http_status(:created)
    round("2026-01", [ item(adequacy: "inadequate", action: "Recalibração e nova dosagem") ], upload_id: json_body["upload_id"])
    expect(response).to have_http_status(:created)
    created = json_body
    expect(created).to include("program" => "PNCQ", "round_code" => "2026-01", "round_date" => "2026-03-10",
                               "annual_report_upload_id" => be_present,
                                 "annual_report_url" => "/lab/eqa/rounds/#{created['id']}/annual_report.pdf")
    expect(created["items"].sole).to include("submitted" => "98.5", "target" => "100", "acceptable_low" => "90", "adequacy" => "inadequate")
    get "/lab/eqa/rounds/#{created['id']}/annual_report.pdf"
    expect([ response.media_type, response.body.b[0, 5] ]).to eq([ "application/pdf", "%PDF-" ])
    round("2026-02", [ item ], date: "2026-06-10")
    expect(json_body).to include("annual_report_upload_id" => nil, "annual_report_url" => nil)
    get "/lab/eqa/summary", params: { provider_id: provider.id, year: 2026 }
    expect(json_body).to eq("year" => 2026, "rows" => [ { "analyte_key" => "glicose", "lab_exam_id" => exam.id, "rounds" => 2, "adequate" => 1,
                                                        "inadequate" => 1 } ])
    get "/lab/eqa/rounds", params: { provider_id: provider.id, year: 2026 }
    expect(json_body["rounds"].map { |r| r["round_code"] }).to eq(%w[2026-02 2026-01])
    get "/lab/eqa/rounds", params: { provider_id: provider.id, year: 2025 }
    expect(json_body["rounds"]).to eq([])
    expect(DomainEvent.where(name: "lab_eqa_round.recorded").map { |e| e.payload.keys }.uniq).to eq([ [ "lab_eqa_round_id" ] ])
  end

  it "recusas: ação no inadequado, vírgula, analito repetido, rodada repetida, data futura, arquivo que não é PDF ou já usado" do
    stepped_up!(lead)
    round("R1", [ item(adequacy: "inadequate") ])
    expect(json_body["error"]).to eq("action_required")
    round("R1", [ item(submitted: "98,5") ])
    expect(json_body["error"]).to eq("invalid_value")
    round("R1", [ item.merge(analyte_key: "ureia") ])
    expect(json_body["error"]).to eq("invalid_items")
    round("R1", [ item, item ])
    expect(json_body["error"]).to eq("invalid_items")
    round("R1", [ item ], date: (Time.zone.today + 1).iso8601)
    expect(json_body["error"]).to eq("invalid_round_date")
    round("R1", [ item ])
    round("R1", [ item ])
    expect(json_body["error"]).to eq("duplicate_round")
    json_post "/lab/eqa/uploads", content_type: "image/png", data: Base64.strict_encode64("\x89PNG\r\n\x1A\nimagem".b)
    expect(json_body["error"]).to eq("invalid_file")
    json_post "/lab/eqa/uploads", content_type: "application/pdf", data: pdf
    used = json_body["upload_id"]
    round("R3", [ item ], upload_id: used)
    round("R4", [ item ], upload_id: used)
    expect(json_body["error"]).to eq("invalid_file")
  end

  it "técnica não registra nem lê; CEQ desligado com lab_quality_control" do
    stepped_up!(lab_staff!)
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    json_post "/lab/eqa/uploads", content_type: "application/pdf", data: pdf
    expect(response).to have_http_status(:forbidden)
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    stepped_up!(lead)
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(json_body["feature"]).to eq("lab_quality_control")
  end
end
