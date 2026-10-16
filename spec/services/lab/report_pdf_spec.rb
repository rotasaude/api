require "rails_helper"
require "pdf/reader"

# RDC 978 art. 167: o PDF traz cada item.
RSpec.describe Lab::ReportPdf do
  before { lab_city! }

  let(:provider) { lab_provider!(name: "Laboratório Municipal Central") }
  let(:lead) { lab_releaser!(provider, council: "CRBM", lead: true) }
  let(:releaser) { lab_releaser!(provider, council: "CRF") }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }

  def report_for(item, partial: false, kind: "advanced")
    built = Lab::ReportContent.build(requisition: item.lab_requisition, items: [ item ], released_by: releaser, lead: lead, partial: partial,
                                     signature_kind: kind, issued_at: Time.current)
    LabReport.new(lab_requisition: item.lab_requisition, exam_provider: provider, version: 1, partial: partial, signature_kind: kind,
                  released_by_user: releaser, content: built.json, content_sha256: built.sha256,
                  verification_token: ClinicalDocuments::Codes.token, short_code: "ABCDE23456", created_at: Time.current)
  end

  def text_of(pdf) = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n").gsub(/\s+/, " ")

  it "os 14 itens do art. 167 e a conferência por QR" do
    req.samples.first.then { |s| s.update_columns(status: "accepted_with_restriction", restriction_note: "Lipemia discreta") }
    item = type!(req.items.first, { glicose: "120" })
    text = text_of(described_class.call(report_for(item, partial: true)))
    expected = [ "Laboratório Municipal Central", "CNES #{provider.cnes}", "Rua do Laboratório, 100", "(41) 3350-1200",
                 "Responsável técnico: #{lead.professional.professional_name}", "CRBM-PR #{lead.professional.registration_number}",
                 "Liberado por: #{releaser.professional.professional_name}", "CRF-PR",
                 req.patient.display_name, "Registro #{req.number}", "Coleta:", "Glicose", "Material: Plasma", "Método: Enzimático",
                 "120 mg/dL", "70 a 99 mg/dL", "ALTO", "Amostra aceita com restrição: Lipemia discreta", "Emitido em",
                 "LAUDO PARCIAL", "assinatura eletrônica avançada", "ABCDE-23456" ]
    expected.each { |fragment| expect(text).to include(fragment), fragment }
    expect(text).not_to include(req.patient.cpf)
  end

  it "nome de 80 caracteres e acentos não estouram a página" do
    name = "Dosagem de Imunoglobulina Específica Anti-Treponema Pallidum — Triagem Ampliada Ç"
    expect(name.length).to be >= 80
    analytes = LabHelpers::GLUCOSE.map { |a| a.merge("name" => name) }
    exam = lab_exam!(provider: provider, sigtap_code: "0202010503", name: name, analytes: analytes, instrument_test_code: "LNG",
                     material: "Soro com anticoagulante especial de transporte refrigerado")
    item = type!(received_requisition!(provider: provider, exams: [ exam ]).items.first, { glicose: "98" })
    pdf = described_class.call(report_for(item))
    reader = PDF::Reader.new(StringIO.new(pdf))
    expect(reader.page_count).to eq(1)
    text = text_of(pdf)
    expect(text).to include("Imunoglobulina Específica Anti-Treponema Pallidum", "98 mg/dL", "especial de transporte refrigerado")
  end

  it "assinatura ICP sem rodapé avisa que está pendente" do
    item = type!(req.items.first, { glicose: "98" })
    expect(text_of(described_class.call(report_for(item, kind: "icp")))).to include("ICP-Brasil pendente")
  end

  it "valor numérico com vírgula decimal, como as referências" do
    analytes = LabHelpers::GLUCOSE.map { |a| a.merge("decimals" => 3, "reference_ranges" => [ a["reference_ranges"].first.merge("low" => 0.4, "high" => 4.0) ]) }
    exam = lab_exam!(provider: provider, sigtap_code: "0202010503", name: "TSH", analytes: analytes, instrument_test_code: "TSH")
    item = type!(received_requisition!(provider: provider, exams: [ exam ]).items.first, { glicose: "15" })
    report = report_for(item)
    text = text_of(described_class.call(report))
    expect(text).to include("15,000 mg/dL", "0,400 a 4,000 mg/dL")
    expect(text).not_to include("15.000")
    expect(JSON.parse(report.content)["exams"].sole["components"].sole["value"]).to eq("15.000")
  end

  it "toda página traz paciente, requisição e Página n de N" do
    analytes = (1..55).map { |n| LabHelpers::GLUCOSE.first.merge("key" => "c#{n}", "name" => "Componente #{n}", "reference_ranges" => [], "critical_low" => nil, "critical_high" => nil) }
    exam = lab_exam!(provider: provider, sigtap_code: "0202010503", name: "Painel", analytes: analytes, instrument_test_code: "PNL")
    item = type!(received_requisition!(provider: provider, exams: [ exam ]).items.first, analytes.to_h { |a| [ a["key"], "50" ] })
    reader = PDF::Reader.new(StringIO.new(described_class.call(report_for(item))))
    expect(reader.page_count).to be >= 2
    reader.pages.each_with_index do |page, i|
      text = page.text.gsub(/\s+/, " ")
      expect(text).to include(item.lab_requisition.patient.display_name, "Requisição #{item.lab_requisition.number}", "Página #{i + 1} de #{reader.page_count}")
    end
  end

  def report_from(doc, base)
    json = Signatures::Jcs.dump(doc)
    LabReport.new(lab_requisition: base.lab_requisition, exam_provider: provider, version: 2, partial: false, signature_kind: "advanced",
                  released_by_user: releaser, content: json, content_sha256: Digest::SHA256.hexdigest(json),
                  verification_token: ClinicalDocuments::Codes.token, short_code: "ABCDE23456", created_at: Time.current)
  end

  it "retificação identifica o laudo substituído e o motivo; apoio aparece com nome e CNES" do
    item = type!(req.items.first, { glicose: "98" })
    old = LabReport.create!(lab_requisition: req, exam_provider: provider, version: 1, status: "pending_signature", signature_kind: "advanced",
                            released_by_user: releaser, content: "{}", content_sha256: "0" * 64, verification_token: ClinicalDocuments::Codes.token,
                            short_code: "FGHJK23456", released_at: Time.utc(2026, 10, 14, 12))
    built = Lab::ReportContent.build(requisition: req, items: [ item ], released_by: releaser, lead: lead, partial: false, signature_kind: "advanced",
                                     issued_at: Time.current, replaces: old, reason: "Valor digitado errado")
    doc = built.document.merge("support_laboratory" => { "name" => "Laboratório de Apoio Sul", "cnes" => "7654321" })
    text = text_of(described_class.call(report_from(doc, item)))
    expect(text).to include("substitui o laudo anterior (versão 1, liberado em 14/10/2026, código FGHJK-23456)", "Motivo: Valor digitado errado",
                            "Exames de apoio realizados por: Laboratório de Apoio Sul — CNES 7654321")
  end

  it "exames saem em ordem de nome" do
    exams = [ lab_exam!(provider: provider, sigtap_code: "0202010503", name: "Beta exame", instrument_test_code: "BET"),
              lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Alfa exame", instrument_test_code: "ALF") ]
    items = received_requisition!(provider: provider, exams: exams).items.map { |i| type!(i, { glicose: "98" }) }
    built = Lab::ReportContent.build(requisition: items.first.lab_requisition, items: items, released_by: releaser, lead: lead, partial: false,
                                     signature_kind: "advanced", issued_at: Time.current)
    text = text_of(described_class.call(report_from(built.document, items.first)))
    expect(text.index("Alfa exame")).to be < text.index("Beta exame")
  end

  it "o título do exame nunca fica sozinho no fim da página" do
    comp = ->(n, name) { { "key" => "k#{n}", "name" => name, "value" => "5", "unit" => "u", "flag" => "normal", "reference_text" => "1 a 9 u", "loinc" => nil } }
    exam = lambda do |name, count, first|
      { "sigtap_code" => "0202010473", "name" => name, "material" => "Soro", "method" => "M", "version" => 1,
        "collected_at" => "2026-10-15T10:00:00Z", "restriction_note" => nil,
        "components" => Array.new(count) { |i| comp.call(i, i.zero? ? first : "Linha #{i}") } }
    end
    base = type!(req.items.first, { glicose: "98" })
    built = Lab::ReportContent.build(requisition: req, items: [ base ], released_by: releaser, lead: lead, partial: false,
                                     signature_kind: "advanced", issued_at: Time.current)
    (30..60).each do |count|
      doc = built.document.merge("exams" => [ exam.call("Primeiro", count, "Alfa"), exam.call("Segundo exame", 3, "Primeira linha do segundo") ])
      reader = PDF::Reader.new(StringIO.new(described_class.call(report_from(doc, base))))
      page = reader.pages.find { |pg| pg.text.include?("Segundo exame") }
      expect(page.text).to include("Primeira linha do segundo"), "count=#{count}"
    end
  end
end
