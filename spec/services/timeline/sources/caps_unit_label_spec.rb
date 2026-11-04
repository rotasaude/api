require "rails_helper"

# Módulo 31, fix round 1 da Task 14 (P51, G2, opção i): o nome e a modalidade
# de uma unidade `caps` nunca saem nas fontes gerais da linha do tempo
# (profissional da UBS, cidadão e PEC externo) nem no cartão de vacina do
# cidadão. A unidade aparece como "Centro de Atenção Psicossocial" (a forma do
# P48), pelo ponto comum Timeline::Sources::Labels.unit. A linha manual de BPA
# lançada no CAPS fica fora do procedimento e das boas práticas do 23.
RSpec.describe "Fontes gerais — unidade CAPS com rótulo genérico" do
  let(:caps_name) { "CAPS AD III Centro Vida" }
  let(:hidden) { [ "Centro Vida", "AD III", "caps_ad_iii" ] }
  let(:label) { "Centro de Atenção Psicossocial" }
  let(:caps) do
    HealthUnit.create!(name: caps_name, kind: "caps", caps_modality: "caps_ad_iii", service_classification: "001", cnes: "7654321")
  end
  let(:person) { Timeline::Person.for_patient(patient) }

  def entries_of(source, **opts) = source.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

  # Profissional, cidadão (quando a fonte tem visão do cidadão) e o HTML do PEC.
  def bodies(entries)
    professional = entries.map { |entry| Timeline::Json.professional(entry) }.to_json
    citizen = entries.select(&:citizen).map { |entry| Timeline::Json.citizen(entry) }.to_json
    [ professional, citizen, PecExternal::Page.items(entries) ]
  end

  def expect_generic(entries)
    expect(entries).not_to be_empty
    bodies(entries).each { |body| hidden.each { |text| expect(body).not_to include(text) } }
    expect(entries.map { |entry| entry.unit[:name] }.uniq).to eq([ label ])
  end

  describe "exame aberto no CAPS" do
    before { exam_city! }

    let(:patient) { exam_patient!(exam_seq!).first }

    it "a unidade do pedido sai genérica no profissional, no cidadão e no PEC" do
      exam_order!(patient: patient, unit: caps, requester: doctor!(caps))
      expect_generic(entries_of(Timeline::Sources::ExamSource))
    end
  end

  describe "linha manual de BPA lançada no CAPS" do
    before { billing_city! }

    let(:patient) { billing_patient! }

    it "fica fora do procedimento e das boas práticas; a da UPA continua" do
      doctor = doctor!(caps)
      raw_procedure!(unit: caps, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil)
      upa = upa!
      own = raw_procedure!(unit: upa, patient: patient, professional: doctor!(upa), sigtap_code: "0301040095", cid10: nil)
      entries = entries_of(Timeline::Sources::ProcedureSource)
      expect(entries.map(&:source_id)).to eq([ own.id ])
      bodies(entries).each { |body| hidden.each { |text| expect(body).not_to include(text) } }
      events = CareLines::Sources.load(patient_ids: [ patient.id ], sources: [ "procedure:0301040095" ], since: Time.zone.today - 1)
      expect(events.fetch(patient.id).fetch("procedure:0301040095").size).to eq(1)
    end
  end

  describe "vacina em sala do CAPS" do
    before { vaccination_city! }

    let(:patient) { vaccine_patient!(birth_date: Time.zone.today - 400) }
    let(:room) do
      location = StockLocation.create!(kind: "vaccine_room", name: "Sala 1", health_unit: caps, updated_by_user: pharmacy_admin!)
      VaccineRoom.create!(health_unit: caps, stock_location: location, name: "Sala 1", updated_by_user: pharmacy_admin!)
    end

    it "a unidade sai genérica na linha do tempo (UBS, cidadão, PEC) e no cartão de vacina do cidadão" do
      create_immunization!(room, patient: patient)
      entries = entries_of(Timeline::Sources::VaccinationSource)
      expect_generic(entries)
      expect(entries.sole.citizen[:unit]).to eq(id: caps.id, name: label)
      card = Vaccination::CitizenView.call(patient_id: patient.id)
      expect(card[:items].map { |item| item[:place_name] }).to eq([ label ])
      hidden.each { |text| expect(card.to_json).not_to include(text) }
    end
  end

  describe "dispensação na farmácia do CAPS" do
    before do
      pharmacy_city!
      ciap2_release!
      cid10_release!
      sigtap_release!
    end

    let(:ubs) { create_unit("UBS Jardim das Flores") }
    let(:consultation) { finalized_consultation!(unit: ubs, doctor: doctor!(ubs), citizen: verified_citizen!(7)) }
    let(:patient) { consultation.patient }

    it "a unidade da farmácia sai genérica na linha do tempo do profissional" do
      farmacia = unit_location!(caps)
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      document = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana } ])
      dispensation = Dispensation.create!(stock_location: farmacia, patient: patient, clinical_document: document, dispensed_by_user: pharmacist,
                                          dispensed_by_role: "pharmacist", dispensed_at: Time.current)
      DispensationItem.create!(dispensation: dispensation, prescription_item: document.prescription_items.first,
                               stock_lot: stocked_lot!(farmacia, item: losartana, quantity: "100"), catalog_item_id: losartana.id, quantity: 30)
      expect_generic(entries_of(Timeline::Sources::DispensationSource))
    end
  end

  it "Labels.unit: CAPS genérico (unidade ou estabelecimento do BPA); demais pelo nome" do
    Current.city = TEST_CITY_A
    ubs = HealthUnit.create!(name: "UBS Centro", kind: "ubs")
    expect(Timeline::Sources::Labels.unit(caps)).to eq(id: caps.id, name: label)
    expect(Timeline::Sources::Labels.unit(Billing::Establishment.for_unit(caps))).to eq(id: caps.id, name: label)
    expect(Timeline::Sources::Labels.unit(ubs)).to eq(id: ubs.id, name: "UBS Centro")
  ensure
    Current.reset
  end
end
