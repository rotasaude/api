require "rails_helper"

# Módulo 27a, Task 13 (ADR 0045; contrato H7): a dispensação na linha do tempo
# do PROFISSIONAL. Uma entrada por dispensação, com os rótulos do catálogo e
# sem lote nem quantidade; `detail_ref: null`; continua visível com o
# interruptor `pharmacy` desligado (registro clínico retido); vazia sem
# paciente; nunca entra na visão do cidadão.
RSpec.describe Timeline::Sources::DispensationSource do
  include ActiveSupport::Testing::TimeHelpers

  before do
    pharmacy_city!
    ciap2_release!
    cid10_release!
    sigtap_release!
  end

  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(7, full_name: "Maria Aparecida 7")) }
  let(:patient) { consultation.patient }
  let(:person) { Timeline::Person.for_patient(patient) }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

  # Dispensação gravada direto (como o spec do lookup): a fonte só lê.
  def dispensed!(items, at: Time.current, lot_number: "LOTE-SECRETO-77")
    document = pharmacy_prescription!(consultation: consultation, items: items.map { |catalog| { catalog: catalog } })
    dispensation = Dispensation.create!(stock_location: farmacia, patient: patient, clinical_document: document, dispensed_by_user: pharmacist,
                                        dispensed_by_role: "pharmacist", dispensed_at: at)
    document.prescription_items.order(:position).each_with_index do |row, index|
      lot = stocked_lot!(farmacia, item: items[index], quantity: "100", lot_number: "#{lot_number}-#{index}")
      DispensationItem.create!(dispensation: dispensation, prescription_item: row, stock_lot: lot, catalog_item_id: items[index].id, quantity: 30)
    end
    dispensation
  end

  it "uma entrada por dispensação: rótulos do catálogo, sem lote nem quantidade; detail_ref nulo" do
    dispensation = dispensed!([ losartana, amoxicilina ])
    entry = entries.sole
    expect(entry).to have_attributes(kind: "dispensation", source_id: dispensation.id, occurred_at: dispensation.dispensed_at,
                                     unit: { id: unit.id, name: unit.name },
                                     professional: { name: pharmacist.professional.professional_name, cbo_code: nil },
                                     title: "Dispensação de medicamentos", status: "dispensed", detail_ref: nil, citizen: nil, document: nil)
    expect(entry.summary).to eq([ losartana.label, amoxicilina.label ].join("; "))
    shown = Timeline::Json.professional(entry)
    expect(shown).to include(id: "dispensation:#{dispensation.id}", kind: "dispensation", status: "dispensed", detail_ref: nil)
    expect(shown.to_s).not_to include("LOTE-SECRETO")
  end

  it "ordem com outras entradas pela chave total; janela e cursor" do
    consultation_at = consultation.reload.finalized_at
    newer = dispensed!([ losartana ], at: Time.current + 1.hour)
    older = dispensed!([ amoxicilina ], at: consultation_at - 3.days)
    page = Timeline::Query.call(person: person, kinds: %w[consultation dispensation])
    expect(page.entries.map { |entry| [ entry.kind, entry.source_id ] })
      .to eq([ [ "dispensation", newer.id ], [ "consultation", consultation.id ], [ "dispensation", older.id ] ])
    first = Timeline::Query.call(person: person, kinds: %w[dispensation], limit: 1)
    expect([ first.entries.map(&:source_id), first.next_before.present? ]).to eq([ [ newer.id ], true ])
    rest = Timeline::Query.call(person: person, kinds: %w[dispensation], limit: 1, before: Timeline::Cursor.decode(first.next_before))
    expect([ rest.entries.map(&:source_id), rest.next_before ]).to eq([ [ older.id ], nil ])
    expect(entries(from: consultation_at - 1.day).map(&:source_id)).to eq([ newer.id ])
  end

  it "interruptor desligado depois: a entrada continua (registro clínico retido)" do
    dispensation = dispensed!([ losartana ])
    Platform::Features.set!(city: Current.city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
    expect(Pharmacy::Gate.usable?(Current.city)).to be(false)
    expect(entries.map(&:source_id)).to eq([ dispensation.id ])
  end

  it "sem paciente, vazio; dispensação de outro paciente não entra" do
    dispensed!([ losartana ])
    expect(described_class.entries(person: Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: true), before: nil, limit: 10,
                                   from: nil, to: nil)).to eq([])
    other = Timeline::Person.for_patient(pharmacy_consultation!.patient)
    expect(described_class.entries(person: other, before: nil, limit: 10, from: nil, to: nil)).to eq([])
  end

  it "o catálogo é lido uma vez para a página" do
    dispensed!([ losartana, amoxicilina ], at: 2.days.ago)
    dispensed!([ losartana ], at: 1.day.ago)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/FROM "medication_catalog_items"/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { expect(entries.size).to eq(2) }
    expect(queries.size).to eq(1)
  end
end
