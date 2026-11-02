require "rails_helper"

RSpec.describe Rnds::Bundle do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room!(create_unit("UBS Vacina", cnes: "7654321")) }
  let(:dose) do
    create_immunization!(room, immunobiological_code: "42", dose_code: "1", strategy: "1", care_group: "121", route: "3", site: "18",
                               maternal_condition: "1", applied_at: Time.zone.parse("2026-11-03 09:15"))
  end
  let(:transcribed_attrs) { { transcription: true, vaccine_room: nil, stock_lot: nil, care_group: nil, route: nil, site: nil } }
  let(:now) { Time.zone.parse("2026-11-03 09:20") }

  def build(immunization = dose, **over)
    described_class.build(immunization: immunization, kind: "application", cnes: "1234567", now: now, **over)
  end

  it "documento com Composition primeiro e Immunization referenciada; códigos sem tradução" do
    bundle = described_class.build(immunization: dose, kind: "application", cnes: "1234567", now: Time.zone.parse("2026-11-03 09:20"))
    expect(bundle["type"]).to eq("document")
    composition, immunization = bundle["entry"].map { |e| e["resource"] }
    expect(composition["resourceType"]).to eq("Composition")
    expect(composition["section"].first["entry"].first["reference"]).to eq(bundle["entry"].last["fullUrl"])
    expect(immunization.dig("vaccineCode", "coding", 0)).to eq("system" => Rnds::Profile.current.code_systems[:immunobiological], "code" => "42")
    expect(immunization["occurrenceDateTime"]).to eq("2026-11-03T09:15:00-03:00")
    expect(immunization["lotNumber"]).to eq(dose.stock_lot.lot_number)
    expect(immunization["primarySource"]).to be(true)
    expect(Rnds::Skeleton.problems(bundle)).to eq([])
  end

  it "transcrição: primarySource false, flag de transcrição, lote opcional" do
    transcribed = create_immunization!(room, **transcribed_attrs, lot_number_text: nil)
    bundle = described_class.build(immunization: transcribed, kind: "application", cnes: "1234567", now: Time.current)
    immunization = bundle["entry"].last["resource"]
    expect(immunization).to include("primarySource" => false)
    expect(immunization).not_to have_key("lotNumber")
    flag = immunization["extension"].find { |e| e["url"] == Rnds::Profile.current.extensions[:transcription] }
    expect(flag["valueBoolean"]).to be(true)
    expect(Rnds::Skeleton.problems(bundle)).to eq([])
  end

  it "executante = CNES da unidade da dose; custodiante = CNES solicitante; transcrição cai no solicitante" do
    composition, immunization = build["entry"].map { |e| e["resource"] }
    expect(composition.dig("custodian", "identifier", "value")).to eq("1234567")
    expect(immunization.dig("performer", 0, "actor", "identifier", "value")).to eq("7654321")
    transcribed = create_immunization!(room, **transcribed_attrs, lot_number_text: nil)
    bundle = build(transcribed)
    expect(bundle["entry"].last["resource"].dig("performer", 0, "actor", "identifier", "value")).to eq("1234567")
    expect(Rnds::Skeleton.problems(bundle)).to eq([])
  end

  it "transcrição com lote e fabricante em texto manda o lote" do
    transcribed = create_immunization!(room, **transcribed_attrs, lot_number_text: "ABC123", manufacturer_text: "Serum")
    immunization = build(transcribed)["entry"].last["resource"]
    expect(immunization["lotNumber"]).to eq("ABC123")
  end

  it "paciente sem CPF vai com o CNS; cancelamento substitui o documento aceito" do
    patient = vaccine_patient!(birth_date: Time.zone.today - 61, cpf: false)
    no_cpf = create_immunization!(room, patient: patient)
    ids = build(no_cpf)["entry"].first["resource"].dig("subject", "identifier")
    expect(ids).to eq("system" => Rnds::Profile.current.identifiers[:cns], "value" => patient.cns)

    bundle = described_class.build(immunization: dose, kind: "cancellation", original_rnds_id: "abc-123", cnes: "1234567", now: Time.current)
    expect(bundle["entry"].first["resource"]["relatesTo"]).to eq([ { "code" => "replaces", "targetIdentifier" => { "value" => "abc-123" } } ])
    expect(bundle["entry"].last["resource"]["status"]).to eq("entered-in-error")
    expect(Rnds::Skeleton.problems(bundle)).to eq([])
  end

  it "cancelamento sem o rnds_id do original recusa" do
    expect { described_class.build(immunization: dose, kind: "cancellation", cnes: "1234567", now: now) }.to raise_error(ArgumentError)
  end

  it "via, local e grupo vão com o código RNDS; estratégia e dose com o código do catálogo" do
    immunization = build["entry"].last["resource"]
    profile = Rnds::Profile.current
    expect(immunization.dig("route", "coding", 0)).to eq("system" => profile.code_systems[:route], "code" => Vaccination::Terminologies.rnds_code("route", "3"))
    expect(immunization.dig("site", "coding", 0)).to eq("system" => profile.code_systems[:site], "code" => "3")
    group = immunization["extension"].find { |e| e["url"] == profile.extensions[:care_group] }
    expect(group.dig("valueCoding", "code")).to eq("000210")
  end

  describe "dose (enum do LEDI, nunca ordinal)" do
    def dose_coding(immunization)
      url = Rnds::Profile.current.extensions[:dose]
      build(immunization)["entry"].last["resource"]["extension"].find { |e| e["url"] == url }["valueCoding"]
    end

    it "dose única (9) e 1º reforço (6) vão como coding no CodeSystem de dose" do
      system = Rnds::Profile.current.code_systems[:dose]
      expect(dose_coding(create_immunization!(room, dose_code: "9"))).to eq("system" => system, "code" => "9")
      expect(dose_coding(create_immunization!(room, dose_code: "6"))).to eq("system" => system, "code" => "6")
      expect(build["entry"].last["resource"]).not_to have_key("protocolApplied")
    end

    it "o Skeleton acusa a dose ausente" do
      bundle = build
      bundle["entry"].last["resource"]["extension"].reject! { |e| e["url"] == Rnds::Profile.current.extensions[:dose] }
      expect(Rnds::Skeleton.problems(bundle)).to eq([ "Immunization.extension.dose" ])
    end
  end

  describe "condição materna" do
    def maternal(bundle)
      url = Rnds::Profile.current.extensions[:maternal_condition]
      bundle["entry"].last["resource"]["extension"].find { |e| e["url"] == url }&.dig("valueCoding", "code")
    end

    it "aplicação com condição nula manda 1 (Nenhuma)" do
      expect(maternal(build(create_immunization!(room, maternal_condition: nil)))).to eq("1")
    end

    it "aplicação com condição registrada manda a registrada" do
      expect(maternal(build(create_immunization!(room, maternal_condition: "2")))).to eq("2")
    end

    it "transcrição com condição nula não manda a condição" do
      bundle = build(create_immunization!(room, **transcribed_attrs, maternal_condition: nil))
      expect(maternal(bundle)).to be_nil
      expect(Rnds::Skeleton.problems(bundle)).to eq([])
    end
  end

  describe "perfil não confirmado" do
    it "marca as hipóteses por chave" do
      expect(Rnds::Profile.current.hypotheses).to include("extensions.transcription", "identifiers.cpf", "document_type_code")
      expect(Rnds::Profile.current.hypotheses).not_to include("code_systems.route")
    end

    it "com o perfil em revisão, o catálogo está em revisão (mesmo com os YAML limpos)" do
      allow(Vaccination::YamlFiles).to receive(:review?).and_return(false)
      expect(Rnds::Profile.current.review).to be(true)
      expect(Vaccination::Catalog.under_review?).to be(true)
      allow(Rnds::Profile).to receive(:current).and_return(Rnds::Profile.current.with(review: false))
      expect(Vaccination::Catalog.under_review?).to be(false)
    end
  end

  describe "fabricante (V19)" do
    let(:product) { Vaccination::Immunobiologicals.find("42") }
    let(:manufacturer) { product.manufacturers.first }

    def with_lot(key)
      lot = vaccine_lot!(room, code: "42", manufacturer_key: key)
      create_immunization!(room, stock_lot: lot)
    end

    it "resolve o código pelo catálogo na hora de montar" do
      coded = Vaccination::Immunobiologicals::Manufacturer.new(code: "FAB-9", key: manufacturer.key, name: manufacturer.name,
                                                               validity_after_opening_hours: 6, review: false)
      allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
      allow(Vaccination::Immunobiologicals).to receive(:find).with("42").and_return(product.with(manufacturers: [ coded ]))
      immunization = build(with_lot(manufacturer.key))["entry"].last["resource"]
      expect(immunization["manufacturer"]).to eq("identifier" => { "system" => Rnds::Profile.current.code_systems[:manufacturer], "value" => "FAB-9" })
    end

    it "com código nulo no catálogo, sai sem o fabricante" do
      expect(manufacturer.code).to be_nil
      bundle = build(with_lot(manufacturer.key))
      expect(bundle["entry"].last["resource"]).not_to have_key("manufacturer")
      expect(Rnds::Skeleton.problems(bundle)).to eq([])
    end

    it "lote sem manufacturer_key sai sem o fabricante" do
      expect(build(with_lot(nil))["entry"].last["resource"]).not_to have_key("manufacturer")
    end
  end

  describe "dado sensível" do
    it "o Skeleton lista só caminhos, nunca valores" do
      bundle = build
      bundle["entry"].last["resource"].delete("occurrenceDateTime")
      bundle["entry"].last["resource"]["subject"] = {}
      problems = Rnds::Skeleton.problems(bundle)
      expect(problems).to contain_exactly("Immunization.occurrenceDateTime", "Immunization.subject.identifier.value")
    end

    it "o perfil não carrega dado de paciente" do
      expect(Rnds::Profile.current.inspect).not_to include(dose.patient.cpf)
    end
  end

  it "caso fixo bate com a fixture do perfil" do
    patient = dose.patient
    bundle = build
    actual = JSON.generate(bundle)
    ids = { composition: bundle["entry"][0]["fullUrl"], immunization: bundle["entry"][1]["fullUrl"] }
    {
      ids[:composition] => "urn:uuid:COMPOSITION", ids[:immunization] => "urn:uuid:IMMUNIZATION",
      bundle["identifier"]["value"] => "BUNDLE-ID", patient.cpf => "CPF", patient.cns => "CNS",
      dose.stock_lot.lot_number => "LOT", dose.vaccinator_user.professional.cns => "PRACTITIONER-CNS",
      dose.created_at.in_time_zone.iso8601 => "RECORDED-AT"
    }.each { |value, token| actual = actual.gsub(value, token) }
    expected = Rails.root.join("spec/fixtures/rnds/ria_r_application.json").read
    expect(JSON.parse(actual)).to eq(JSON.parse(expected))
  end
end
