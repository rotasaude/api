require "rails_helper"

# Módulo 31 (ADR 0049; contrato §8, §10, P45; rulings da dispensação): o que o
# CAPS grava fora das tabelas dele não chega à UBS nem ao cidadão.
# - A linha do BPA (`performed_procedures.source = "psychosocial"`) fica fora
#   da linha do tempo geral (ProcedureSource) e das boas práticas do 23
#   (CareLines::Sources).
# - A dispensação da receita do CAPS (`clinical_documents.psychosocial_action_id`)
#   fica fora da linha do tempo geral (DispensationSource) e da "última
#   retirada" da lista de medicamentos da UBS (Pharmacy::Dispensed.last_on). A
#   farmácia continua vendo a receita (dispensar precisa).
# Relógio fixo no meio de novembro.
RSpec.describe "CAPS — sigilo fora das tabelas do módulo" do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city!(billing: true) }
  let(:caps) { caps!(name: "CAPS AD III Centro Vida", modality: "caps_ad_iii") }
  let(:staff) { caps_staff!(caps, cbo: "225133") }
  let(:enrollment) { enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 3), cid: "F102") }
  let(:patient) { enrollment.patient }
  let(:person) { Timeline::Person.for_patient(patient) }

  def bpa_i_line!
    reception = record_action!(caps, staff, sigtap_code: "0301080232", performed_at: Time.zone.local(2026, 11, 3, 9),
                                            participants: [ { patient_id: patient.id } ])
    line = Billing::FromPsychosocial.call(reception)
    raise "linha BPA-I não gerada" unless line&.patient_id == patient.id && line.source == "psychosocial"

    line
  end

  it "ProcedureSource: a linha BPA-I do CAPS não entra; a da UBS, sim" do
    line = bpa_i_line!
    ubs = upa!
    doctor = doctor!(ubs)
    own = recorded_procedure!(unit: ubs, professional: doctor, patient: patient)
    entries = Timeline::Sources::ProcedureSource.entries(person: person, before: nil, limit: 10, from: nil, to: nil)
    expect(entries.map(&:source_id)).to eq([ own.id ])
    expect(entries.map(&:source_id)).not_to include(line.id)
  end

  it "CareLines::Sources: o procedimento do CAPS não conta como fonte de boa prática" do
    line = bpa_i_line!
    loaded = CareLines::Sources.load(patient_ids: [ patient.id ], sources: [ "procedure:#{line.sigtap_code}" ], since: Date.new(2026, 1, 1))
    expect(loaded).to eq(patient.id => {})
  end

  describe "dispensação da receita do CAPS" do
    before do
      Platform::Features.set!(city: city, key: "clinical_documents", enabled: true, maintainer: ledi_maintainer!)
      import_test_catalog!
      Platform::Features.set!(city: city, key: "pharmacy", enabled: true, maintainer: ledi_maintainer!)
      PharmacySetting.ensure_defaults!
      CityCatalog.reset_cache!
    end

    let(:farmacia) { unit_location!(create_unit("UBS Boa Vista")) }
    let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }

    def dispensed!(document, item)
      dispensation = Dispensation.create!(stock_location: farmacia, patient_id: patient.id, clinical_document: document, dispensed_by_user: pharmacist,
                                          dispensed_by_role: "pharmacist", dispensed_at: Time.current)
      lot = stocked_lot!(farmacia, item: item, quantity: "100")
      DispensationItem.create!(dispensation: dispensation, prescription_item: document.prescription_items.first, stock_lot: lot,
                               catalog_item_id: item.id, quantity: 30)
      dispensation
    end

    it "fica fora da linha do tempo geral e da última retirada da UBS; a da receita da UBS aparece" do
      action = record_action!(caps, staff, performed_at: Time.zone.local(2026, 11, 10, 10), participants: [ { enrollment_id: enrollment.id } ])
      prescription = caps_document!(action, kind: "prescription", items: [ losartana ], issued_at: Time.zone.local(2026, 11, 10, 11))
      dispensation = dispensed!(prescription, losartana)
      # Controle positivo: receita do 19 da UBS (sem psychosocial_action_id), do mesmo paciente.
      ubs = create_unit("UBS Centro")
      consultation = started_consultation!(unit: ubs, doctor: doctor!(ubs), citizen: Citizen.find_by!(patient_id: patient.id))
      ubs_prescription = pharmacy_prescription!(consultation: consultation, items: [ { catalog: amoxicilina } ])
      ubs_dispensation = dispensed!(ubs_prescription, amoxicilina)

      entries = Timeline::Sources::DispensationSource.entries(person: person, before: nil, limit: 10, from: nil, to: nil)
      expect(entries.map(&:source_id)).to eq([ ubs_dispensation.id ])
      expect(entries.map(&:source_id)).not_to include(dispensation.id)
      expect(Pharmacy::Dispensed.last_on(patient.id)).to eq(amoxicilina.id => Date.new(2026, 11, 18))
      expect(Dispensation.where(clinical_document_id: prescription.id).count).to eq(1)
    end
  end
end
