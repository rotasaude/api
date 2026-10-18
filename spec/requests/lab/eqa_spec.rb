require "rails_helper"

# Contrato §4, C12 do dashboard e C-E24 (F-21.31): rodada do programa externo com
# itens por analito; relatório anual do PROGRAMA no ANO (PDF em /lab/eqa); adequação
# por analito no ano; liberador ligado, RT ou admin. Recusa não grava nada.
RSpec.describe "CEQ — rodadas e relatório anual", type: :request do
  before { qc_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:pdf_bytes) { "%PDF-1.4\n% relatório anual\n%%EOF" }
  let(:pdf) { Base64.strict_encode64(pdf_bytes) }

  def item(adequacy: "adequate", action: nil, **over)
    { analyte_key: "glicose", lab_exam_id: exam.id, submitted: "98.5", target: "100", acceptable_low: "90", acceptable_high: "110",
      adequacy: adequacy, action: action }.merge(over)
  end

  def round(code, items, date: "2026-03-10", program: "PNCQ", prov: provider)
    json_post "/lab/eqa/rounds", provider_id: prov.id, program: program, round_code: code, round_date: date, items: items
  end

  def upload!(data: pdf, content_type: "application/pdf")
    json_post "/lab/eqa/uploads", content_type: content_type, data: data
  end

  def report(upload_id, year: 2026, program: "PNCQ", prov: provider)
    json_post "/lab/eqa/annual_reports", provider_id: prov.id, program: program, year: year, upload_id: upload_id
  end

  def counts = [ LabEqaRound.count, LabEqaAnnualReport.count, DomainEvent.count ]

  # status + código + nada gravado
  def refuses(status, error)
    before = counts
    yield
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(counts).to eq(before)
  end

  it "registra rodadas, guarda e lê o relatório anual do programa no ano e resume a adequação" do
    stepped_up!(lead)
    round("2026-01", [ item(adequacy: "inadequate", action: "Recalibração e nova dosagem") ])
    expect(response).to have_http_status(:created)
    created = json_body
    expect(created).to include("program" => "PNCQ", "round_code" => "2026-01", "round_date" => "2026-03-10", "provider_id" => provider.id)
    expect(created.keys).not_to include("annual_report_upload_id", "annual_report_url")
    expect(created["items"].sole).to include("submitted" => "98.5", "target" => "100", "acceptable_low" => "90", "adequacy" => "inadequate")
    round("2026-02", [ item ], date: "2026-06-10")
    upload!
    expect(response).to have_http_status(:created)
    up = json_body["upload_id"]
    expect(ExamFile.find(up).consumed_at).to be_nil
    report(up)
    expect(response).to have_http_status(:created)
    annual = json_body
    expect(annual).to include("program" => "PNCQ", "year" => 2026, "url" => "/lab/eqa/annual_reports/#{annual['id']}/pdf")
    expect(ExamFile.find(up).consumed_at).to be_present
    get annual["url"]
    expect([ response.media_type, response.body.b ]).to eq([ "application/pdf", pdf_bytes.b ])
    get "/lab/eqa/annual_reports", params: { provider_id: provider.id, year: 2026 }
    expect(json_body["annual_reports"].map { |r| r["id"] }).to eq([ annual["id"] ])
    get "/lab/eqa/annual_reports", params: { provider_id: provider.id, year: 2025 }
    expect(json_body["annual_reports"]).to eq([])
    get "/lab/eqa/summary", params: { provider_id: provider.id, year: 2026 }
    expect(json_body).to eq("year" => 2026, "rows" => [ { "analyte_key" => "glicose", "lab_exam_id" => exam.id, "rounds" => 2, "adequate" => 1,
                                                        "inadequate" => 1 } ],
                            "programs" => [ { "program" => "PNCQ", "annual_report" => true, "annual_report_id" => annual["id"] } ])
    get "/lab/eqa/rounds", params: { provider_id: provider.id, year: 2026 }
    expect(json_body["rounds"].map { |r| r["round_code"] }).to eq(%w[2026-02 2026-01])
    get "/lab/eqa/rounds", params: { provider_id: provider.id, year: 2025 }
    expect(json_body["rounds"]).to eq([])
    get "/lab/eqa/rounds/#{created['id']}"
    expect(json_body["round_code"]).to eq("2026-01")
    expect(DomainEvent.where(name: "lab_eqa_round.recorded").map { |e| e.payload.keys }.uniq).to eq([ [ "lab_eqa_round_id" ] ])
    expect(DomainEvent.where(name: "lab_eqa_annual_report.recorded").map { |e| e.payload.keys }.uniq).to eq([ [ "lab_eqa_annual_report_id" ] ])
  end

  it "resume: ano padrão, outro ano e sem rodadas de outros laboratórios; programa sem relatório" do
    other = lab_provider!
    other_exam = lab_exam!(provider: other)
    stepped_up!(lead)
    round("A", [ item ], date: Time.zone.today.iso8601)
    round("B", [ item ], date: "2025-05-05", program: "Controllab")
    get "/lab/eqa/summary", params: { provider_id: provider.id }
    expect(json_body["year"]).to eq(Time.zone.today.year)
    expect(json_body["rows"].sole).to include("rounds" => 1)
    expect(json_body["programs"]).to eq([ { "program" => "PNCQ", "annual_report" => false, "annual_report_id" => nil } ])
    get "/lab/eqa/summary", params: { provider_id: provider.id, year: 2025 }
    expect(json_body["programs"].map { |p| p["program"] }).to eq([ "Controllab" ])
    stepped_up!(lab_admin!)
    round("C", [ item(lab_exam_id: other_exam.id) ], prov: other, date: "2025-05-06")
    expect(response).to have_http_status(:created)
    get "/lab/eqa/summary", params: { provider_id: provider.id, year: 2025 }
    expect(json_body["rows"].sole).to include("lab_exam_id" => exam.id, "rounds" => 1)
  end

  # C-E40: year malformado nas LEITURAS → 422 invalid_year (mesma regra do POST).
  %w[/lab/eqa/summary /lab/eqa/rounds /lab/eqa/annual_reports].each do |path|
    it "#{path}: year malformado ou fora da faixa é 422 invalid_year; ausente segue o padrão" do
      stepped_up!(lead)
      [ "abc", "20x6", "26", "1999", "2101", (Time.zone.today.year + 1).to_s, "", "2026.5", " 2026" ].each do |bad|
        get path, params: { provider_id: provider.id, year: bad }
        expect(response).to have_http_status(422), "year=#{bad.inspect}"
        expect(json_body["error"]).to eq("invalid_year")
      end
      get path, params: { provider_id: provider.id, year: [ "2026" ] }
      expect(json_body["error"]).to eq("invalid_year")
      get path, params: { provider_id: provider.id }
      expect(response).to have_http_status(:ok)
      get path, params: { provider_id: provider.id, year: Time.zone.today.year }
      expect(response).to have_http_status(:ok)
    end
  end

  it "recusas da rodada: nada gravado, em cada uma" do
    stepped_up!(lead)
    refuses(422, "action_required") { round("R1", [ item(adequacy: "inadequate") ]) }
    refuses(422, "action_required") { round("R1", [ item(adequacy: "inadequate", action: "  ") ]) }
    refuses(422, "invalid_items") { round("R1", [ item(adequacy: "maybe") ]) }
    refuses(422, "invalid_value") { round("R1", [ item(submitted: "98,5") ]) }
    refuses(422, "invalid_items") { round("R1", [ item(analyte_key: "ureia") ]) }
    refuses(422, "invalid_items") { round("R1", [ item, item ]) }
    refuses(422, "invalid_round_date") { round("R1", [ item ], date: (Time.zone.today + 1).iso8601) }
    refuses(422, "invalid_round_date") { round("R1", [ item ], date: "10/03/2026") }
    refuses(422, "invalid_value") { round("R1", [ item(acceptable_low: "120", acceptable_high: "110") ]) }
    round("R1", [ item ])
    expect(response).to have_http_status(:created)
    refuses(422, "duplicate_round") { round("R1", [ item ]) }
    round("R1", [ item ], program: "Controllab")
    expect(response).to have_http_status(:created)
  end

  it "limites: itens 0/61, programa 0/61, código 0/41, ação 500/501" do
    stepped_up!(lead)
    refuses(422, "invalid_items") { round("L", []) }
    items61 = Array.new(61) { |n| item(analyte_key: "a#{n}") }
    refuses(422, "invalid_items") { round("L", items61) }
    refuses(422, "invalid_program") { round("L", [ item ], program: "") }
    refuses(422, "invalid_program") { round("L", [ item ], program: "p" * 61) }
    refuses(422, "invalid_round_code") { round("", [ item ]) }
    refuses(422, "invalid_round_code") { round("c" * 41, [ item ]) }
    refuses(422, "invalid_items") { round("L", [ item(adequacy: "inadequate", action: "a" * 501) ]) }
    round("c" * 40, [ item(adequacy: "inadequate", action: "a" * 500) ], program: "p" * 60)
    expect(response).to have_http_status(:created)
  end

  it "decimais: 9 inteiros e 4 casas passam; 10 inteiros, 5 casas, vazio, texto e faixa invertida não" do
    stepped_up!(lead)
    round("D1", [ item(submitted: "123456789.1234", target: "-1.5") ])
    expect(response).to have_http_status(:created)
    expect(json_body["items"].sole).to include("submitted" => "123456789.1234", "target" => "-1.5")
    refuses(422, "invalid_value") { round("D2", [ item(submitted: "1234567890") ]) }
    refuses(422, "invalid_value") { round("D2", [ item(submitted: "1.12345") ]) }
    refuses(422, "invalid_value") { round("D2", [ item(submitted: "") ]) }
    refuses(422, "invalid_value") { round("D2", [ item(submitted: "abc") ]) }
    refuses(422, "invalid_value") { round("D2", [ item(submitted: 98.5) ]) }
    refuses(422, "invalid_value") { round("D2", [ item(target: nil) ]) }
    refuses(422, "invalid_value") { round("D2", [ item(acceptable_low: "x") ]) }
    refuses(422, "invalid_value") { round("D2", [ item(acceptable_low: "120", acceptable_high: "110") ]) }
    round("D3", [ item(acceptable_low: nil, acceptable_high: nil) ])
    expect(json_body["items"].sole).to include("acceptable_low" => nil, "acceptable_high" => nil)
  end

  it "analito não numérico e exame de outro laboratório" do
    text_exam = lab_exam!(provider: provider, sigtap_code: "0202010503", name: "Obs",
                          analytes: LabHelpers::GLUCOSE.map { |a| a.merge("key" => "obs", "value_type" => "text", "unit" => nil, "reference_ranges" => []) })
    foreign = lab_exam!(provider: lab_provider!)
    stepped_up!(lead)
    refuses(422, "invalid_items") { round("N", [ item(analyte_key: "obs", lab_exam_id: text_exam.id) ]) }
    refuses(422, "invalid_items") { round("N", [ item(lab_exam_id: foreign.id) ]) }
    refuses(422, "invalid_items") { round("N", [ item(lab_exam_id: "nope") ]) }
    refuses(422, "invalid_items") { round("N", "x") }
  end

  it "envio: PDF só, base64 válido, até 10 MB, bytes de PDF e content_type informado" do
    stepped_up!(lead)
    before = ExamFile.count
    [ [ "application/pdf", "###" ], [ "application/pdf", Base64.strict_encode64("texto simples") ], [ nil, pdf ], [ "image/png", pdf ],
      [ "image/png", Base64.strict_encode64("\x89PNG\r\n\x1A\nimagem".b) ],
      [ "application/pdf", Base64.strict_encode64("%PDF-" + ("a" * (10 * 1024 * 1024))) ] ].each do |type, data|
      upload!(data: data, content_type: type)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("invalid_file")
    end
    expect(ExamFile.count).to eq(before)
    upload!(data: Base64.strict_encode64("%PDF-" + ("a" * ((10 * 1024 * 1024) - 5))))
    expect(response).to have_http_status(:created)
  end

  it "relatório anual: recusas deixam o upload sem uso e nada gravado" do
    stepped_up!(lead)
    upload!
    up = json_body["upload_id"]
    refuses(422, "invalid_program") { report(up, program: "") }
    refuses(422, "invalid_year") { report(up, year: 1999) }
    refuses(422, "invalid_year") { report(up, year: "2026") }
    refuses(422, "invalid_year") { report(up, year: Time.zone.today.year + 1) }
    refuses(422, "invalid_file") { report("nope") }
    refuses(422, "invalid_file") { report(SecureRandom.uuid) }
    expect(ExamFile.find(up).consumed_at).to be_nil
    # upload do 21a (sem a finalidade do CEQ) não serve
    plain = Exams::Files.store(bytes: pdf_bytes, content_type: "application/pdf", user: lead).payload[:file]
    refuses(422, "invalid_file") { report(plain.id) }
    expect(plain.reload.consumed_at).to be_nil
    report(up)
    expect(response).to have_http_status(:created)
    upload!
    again = json_body["upload_id"]
    refuses(409, "already_recorded") { report(again) }
    expect(ExamFile.find(again).consumed_at).to be_nil
    refuses(422, "invalid_file") { report(up, year: 2025) } # já consumido
    report(again, year: 2025)
    expect(response).to have_http_status(:created)
    upload!
    report(json_body["upload_id"], program: "Controllab")
    expect(response).to have_http_status(:created)
  end

  it "o upload de outro usuário não serve" do
    stepped_up!(lead)
    upload!
    up = json_body["upload_id"]
    stepped_up!(lab_admin!)
    refuses(422, "invalid_file") { report(up) }
    expect(ExamFile.find(up).consumed_at).to be_nil
  end

  it "papéis: RT, liberador sem chefia e admin registram; técnica e não-membro não" do
    plain = lab_releaser!(provider)
    stepped_up!(plain)
    round("P1", [ item ])
    expect(response).to have_http_status(:created)
    stepped_up!(lead)
    round("P2", [ item ])
    expect(response).to have_http_status(:created)
    stepped_up!(lab_admin!)
    round("P3", [ item ])
    expect(response).to have_http_status(:created)
    id = json_body["id"]
    upload!
    report(json_body["upload_id"])
    expect(response).to have_http_status(:created)
    report_url = json_body["url"]

    stepped_up!(lab_staff!)
    refuses(403, "missing_role") { round("P4", [ item ]) }
    refuses(403, "missing_role") { upload! }
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    get "/lab/eqa/annual_reports", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    get "/lab/eqa/summary", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)

    outsider = lab_releaser!(lab_provider!, lead: true)
    stepped_up!(outsider)
    refuses(403, "missing_role") { round("P5", [ item ]) }
    refuses(403, "missing_role") { report("x") }
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    get "/lab/eqa/annual_reports", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    # C-E25: rodada ou relatório de outro laboratório responde 404
    get "/lab/eqa/rounds/#{id}"
    expect(response).to have_http_status(:not_found)
    expect(json_body["error"]).to eq("not_found")
    get report_url
    expect(response).to have_http_status(:not_found)
    expect(json_body["error"]).to eq("not_found")
  end

  it "ids e laboratório inválidos" do
    stepped_up!(lead)
    get "/lab/eqa/rounds/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
    get "/lab/eqa/rounds/nope"
    expect(response).to have_http_status(:not_found)
    get "/lab/eqa/annual_reports/#{SecureRandom.uuid}/pdf"
    expect(response).to have_http_status(:not_found)
    get "/lab/eqa/annual_reports/nope/pdf"
    expect(response).to have_http_status(:not_found)
    [ "/lab/eqa/rounds", "/lab/eqa/annual_reports", "/lab/eqa/summary" ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
      get path, params: { provider_id: "nope" }
      expect(response).to have_http_status(:not_found)
    end
    refuses(422, "invalid_provider") { json_post "/lab/eqa/rounds", program: "PNCQ", round_code: "X", round_date: "2026-01-01", items: [ item ] }
    refuses(422, "invalid_provider") { json_post "/lab/eqa/annual_reports", provider_id: "nope", program: "PNCQ", year: 2026 }
  end

  it "sem step-up: criar rodada, enviar e registrar relatório pedem mfa_required" do
    sign_in_as(step_up_enrolled!(lead))
    refuses(401, "mfa_required") { round("S1", [ item ]) }
    refuses(401, "mfa_required") { upload! }
    refuses(401, "mfa_required") { report("x") }
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok)
  end

  it "CEQ desligado com lab_quality_control" do
    stepped_up!(lead)
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    stepped_up!(lead)
    get "/lab/eqa/rounds", params: { provider_id: provider.id }
    expect(json_body["feature"]).to eq("lab_quality_control")
    get "/lab/eqa/annual_reports", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
  end
end
