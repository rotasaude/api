require "rails_helper"
require "json_schemer"

# Contrato §8: o JSON canônico do laudo, fechado, sem CPF, válido no esquema
# da tag lab-v1.0.0 (cópia presa por SHA-256).
RSpec.describe Lab::ReportContent do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, council: "CRBM", lead: true) }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }
  let(:contracts) { Rails.root.join("spec/fixtures/lab_report") } # exemplos da tag lab-v1.0.0

  def build(item, partial: false, kind: "advanced", **extra)
    described_class.build(requisition: item.lab_requisition, items: [ item ], released_by: lead, lead: lead, partial: partial,
                          signature_kind: kind, issued_at: Time.utc(2026, 10, 15, 18, 30), **extra)
  end

  it "monta, valida e é determinístico; sem CPF" do
    item = type!(req.items.first, { glicose: "98" })
    built = build(item)
    doc = built.document
    expect(doc).to include("schema" => "rotasaude.lab_report.v1", "requisition_number" => req.number, "partial" => false,
                           "issued_at" => "2026-10-15T18:30:00Z", "support_laboratory" => nil)
    expect(doc["laboratory"]).to include("cnes" => provider.cnes, "phone" => "4133501200")
    expect(doc["technical_lead"]).to include("council" => "CRBM", "council_uf" => "PR")
    component = doc["exams"].sole["components"].sole
    expect(component).to eq("key" => "glicose", "name" => "Glicose", "value" => "98", "unit" => "mg/dL", "flag" => "normal",
                            "reference_text" => "70 a 99 mg/dL", "loinc" => "2345-7")
    expect(built.json).not_to include(req.patient.cpf)
    expect(JSONSchemer.schema(JSON.parse(File.read(described_class::SCHEMA_PATH))).valid?(doc)).to be(true)
    expect(build(item).sha256).to eq(built.sha256)
  end

  it "esquema preso ao arquivo da tag" do
    expect(Digest::SHA256.file(described_class::SCHEMA_PATH).hexdigest).to eq(described_class::SCHEMA_SHA256)
    expect(described_class::SCHEMA_SHA256).to eq("81ff762db67509b10ebcddc285874ab19a15b449964be46bfbf28d8c4fac7fb5")
  end

  it "laboratório sem CNES, endereço ou telefone não está pronto" do
    expect(described_class.laboratory_ready?(provider)).to be(true)
    provider.update!(phone: nil)
    expect(described_class.laboratory_ready?(provider)).to be(false)
  end

  it "B30: só a linha que vale entra no laudo; a anterior fica como história" do
    item = type!(req.items.first, { glicose: "98" })
    item = type!(item, { glicose: "120" })
    expect(item.results.where(analyte_key: "glicose").count).to eq(2)
    component = build(item).document["exams"].sole["components"].sole
    expect(component).to include("value" => "120", "flag" => "high")
  end

  it "valor com as casas do componente (BigDecimal, nunca Float)" do
    analytes = LabHelpers::GLUCOSE.map { |a| a.merge("decimals" => 2) }
    item = received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider, sigtap_code: "0202010503", name: "Glicose 2", analytes: analytes, instrument_test_code: "GL2") ]).items.first
    item = type!(item, { glicose: "98" })
    expect(build(item).document["exams"].sole["components"].sole["value"]).to eq("98.00")
  end

  it "calculado vem como calculado; sem valor, fica ausente; nunca valor velho" do
    exam = lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Lipidograma", analytes: LabHelpers::LIPIDS, instrument_test_code: "LIP")
    item = received_requisition!(provider: provider, exams: [ exam ]).items.first
    item = type!(item, { ct: "200", hdl: "50", tg: "100" })
    keys = build(item).document["exams"].sole["components"].map { |c| c["key"] }
    expect(keys).to eq(%w[ct hdl tg ldl])
    expect(build(item).document["exams"].sole["components"].last["value"]).to eq("130")
    # linhas são append-only: sem a linha do calculado (entrada parcial admitida)
    allow(Lab::Effective).to receive(:rows).and_wrap_original { |m, i| m.call(i).except("ldl") }
    expect(build(item.reload).document["exams"].sole["components"].map { |c| c["key"] }).to eq(%w[ct hdl tg])
  end

  it "componente digitável sem valor não vira laudo (só ponteiros)" do
    exam = lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Lipidograma", analytes: LabHelpers::LIPIDS, instrument_test_code: "LIP")
    item = received_requisition!(provider: provider, exams: [ exam ]).items.first
    item = type!(item, { ct: "200" })
    expect { build(item) }.to raise_error(described_class::Invalid) { |e| expect(e.message).not_to include("200") }
  end

  it "os exemplos do contrato valem no esquema; o inválido falha só com ponteiros" do
    schema = JSONSchemer.schema(JSON.parse(File.read(described_class::SCHEMA_PATH)))
    %w[lab-report-advanced lab-report-icp lab-report-rectified lab-report-support-laboratory].each do |name|
      expect(schema.valid?(JSON.parse(File.read(contracts.join("#{name}.json"))))).to be(true), name
    end
    invalid = JSON.parse(File.read(contracts.join("invalid-lab-report-without-lead.json")))
    expect { described_class.validate!(invalid) }.to raise_error(described_class::Invalid) do |e|
      expect(e.message).to include("technical_lead")
      expect(e.message).not_to include(invalid.dig("patient", "name"))
    end
  end
end
