require "rails_helper"

# Contrato §10 com M1, M3, M7: catálogo-base da plataforma; o evento
# lab.template_changed só com ids.
RSpec.describe "Lab::Templates" do
  before { sigtap_release! }

  let(:exam_attrs) do
    { id: nil, sigtap_code: "0202010473", name: "Glicose", sector: "biochemistry", material: "Plasma",
      container: "Tubo cinza (fluoreto)", suggested_method: "Enzimático", preparation: "Jejum de 8 horas", active: true }
  end

  it "cria, edita e recusa com o caminho do campo" do
    created = Lab::Templates::SaveExam.call(exam_attrs)
    template = created.payload[:template]
    expect(template).to have_attributes(sigtap_code: "0202010473", sector: "biochemistry", active: true)
    expect(Lab::Templates::SaveExam.call(exam_attrs.merge(id: template.id, active: false)).payload[:template].active).to be(false)
    expect(Lab::Templates::SaveExam.call(exam_attrs).then { [ _1.reason, _1.details[:path] ] }).to eq([ :duplicate_sigtap, "sigtapCode" ])
    expect(Lab::Templates::SaveExam.call(exam_attrs.merge(sigtap_code: "0202999999")).reason).to eq(:sigtap_unknown)
    expect(Lab::Templates::SaveExam.call(exam_attrs.merge(sector: "hormones")).reason).to eq(:invalid_sector)
    expect(Lab::Templates::SaveExam.call(exam_attrs.merge(name: " ")).then { [ _1.reason, _1.details[:path] ] }).to eq([ :blank, "name" ])
    expect(Lab::Templates::SaveExam.call(exam_attrs.merge(id: SecureRandom.uuid)).reason).to eq(:not_found)
    payloads = PlatformEvent.where(name: "lab.template_changed").order(:created_at).map(&:payload)
    expect(payloads.size).to eq(2)
    expect(payloads.first.keys).to contain_exactly("lab_exam_template_id", "change")
  end

  it "componente: chave, tipo, lista, LOINC e faixas" do
    template = Lab::Templates::SaveExam.call(exam_attrs).payload[:template]
    ok = { id: nil, lab_exam_template_id: template.id, key: "glicose", name: "Glicose", loinc: "2345-7", unit: "mg/dL",
           value_type: "numeric", choices: [], decimals: 0, position: 1,
           reference_ranges: [ { sex: "any", age_min_days: 0, age_max_days: 43_800, low: 70, high: 99, text: nil } ] }
    analyte = Lab::Templates::SaveAnalyte.call(ok).payload[:analyte]
    expect(analyte.reference_ranges.first).to include("low" => 70.0, "high" => 99.0)
    expect(Lab::Templates::SaveAnalyte.call(ok).reason).to eq(:duplicate_analyte_key)
    expect(Lab::Templates::SaveAnalyte.call(ok.merge(id: analyte.id, name: "Glicemia")).payload[:analyte].name).to eq("Glicemia")
    { { key: "Glicose" } => :invalid_analyte_key, { key: "x2", value_type: "date" } => :invalid_value_type,
      { key: "x3", value_type: "choice", choices: [] } => :choices_required, { key: "x4", loinc: "abc" } => :invalid_loinc,
      { key: "x5", reference_ranges: [ { sex: "any", age_min_days: 10, age_max_days: 1, low: nil, high: nil, text: nil } ] } => :invalid_reference_ranges,
      { key: "x6", name: "" } => :blank, { key: "x7", lab_exam_template_id: SecureRandom.uuid } => :not_found }.each do |over, code|
      expect(Lab::Templates::SaveAnalyte.call(ok.merge(over)).reason).to eq(code), over.inspect
    end
  end

  it "carrega o catálogo-base do YAML uma vez (idempotente, nunca sobrescreve)" do
    sigtap_release!.tap { |r| Lab::Templates::Load.sigtap_codes.each { |c| SigtapProcedure.find_or_create_by!(release: r, code: c) { |p| p.name = "EXAME #{c}" } } }
    expect(Lab::Templates::Load.call[:created]).to eq(16)
    LabExamTemplate.find_by!(sigtap_code: "0202020380").update!(name: "Hemograma (editado)")
    expect(Lab::Templates::Load.call[:created]).to eq(0)
    expect(LabExamTemplate.find_by!(sigtap_code: "0202020380").name).to eq("Hemograma (editado)")
    hb = LabAnalyteTemplate.joins(:lab_exam_template).find_by!(lab_exam_templates: { sigtap_code: "0202020380" }, key: "hemoglobina")
    expect(hb.reference_ranges.map { |r| r["sex"] }).to eq(%w[male female])
    expect(LabExamTemplate.distinct.pluck(:sector)).to all(be_in(LabExamTemplate::SECTORS))
  end
end
