require "rails_helper"
require "pdf/reader"

# RDC 978 art. 167 (I–XIV, menos XI que não se aplica): o PDF traz cada item.
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
end
