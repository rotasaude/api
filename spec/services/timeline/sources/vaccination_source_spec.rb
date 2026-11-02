require "rails_helper"

# Módulo 29 (ADR 0047; contrato §10; §15 V10/V11, D11/W4): a vacina na linha do
# tempo. Profissional: título do contrato, unidade, vacinador com CBO, situação
# active/cancelled e detail_ref immunization. Cidadão: só doses ativas, sem
# vacinador/resumo/situação/documento e unidade nula na transcrição.
RSpec.describe Timeline::Sources::VaccinationSource do
  include ActiveSupport::Testing::TimeHelpers

  before { vaccination_city! }

  let(:room) { vaccine_room! }
  let(:patient) { vaccine_patient!(birth_date: Time.zone.today - 400) }
  let(:person) { Timeline::Person.for_patient(patient) }
  let(:title) { "#{Vaccination::Immunobiologicals.find('42').name} — #{Vaccination::Terminologies.name('dose', '1')}" }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

  it "uma entrada por dose com o título e o detail_ref do contrato" do
    dose = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-20 09:00:00"))
    entry = entries.sole
    expect(entry).to have_attributes(kind: "vaccination", source_id: dose.id, occurred_at: dose.applied_at, title: title, summary: nil, status: "active",
                                     unit: { id: room.health_unit.id, name: room.health_unit.name }, document: nil,
                                     detail_ref: { type: "immunization", id: dose.id })
    expect(entry.professional).to eq(name: dose.vaccinator_user.professional.professional_name, cbo_code: "322205")
    shown = Timeline::Json.professional(entry)
    expect(shown).to include(id: "vaccination:#{dose.id}", kind: "vaccination", detail_ref: { type: "immunization", id: dose.id })
  end

  it "profissional vê a cancelada com status cancelled; cidadão não" do
    create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-20 09:00:00"))
    gone = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-21 09:00:00"), cancelled_at: Time.current,
                                      cancelled_by_user: room_member!(room), cancel_reason: "Pessoa errada")
    expect(entries.map(&:status)).to eq(%w[cancelled active])
    expect(entries(active_only: true).map(&:source_id)).not_to include(gone.id)
    expect(entries(active_only: true).size).to eq(1)
  end

  it "visão do cidadão: occurred_at, unidade, e professional_name/status/summary/document nulos; transcrição sem unidade" do
    applied = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-20 09:00:00"))
    transcribed = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-05-02 09:00:00"), transcription: true, stock_lot: nil,
                                             lot_number_text: "LOTE-SECRETO-1", place_text: "UBS antiga")
    shown = entries(active_only: true).map { |entry| Timeline::Json.citizen(entry) }
    expect(shown.map { |s| s[:id] }).to eq([ "vaccination:#{applied.id}", "vaccination:#{transcribed.id}" ])
    expect(shown[0]).to include(kind: "vaccination", occurred_at: applied.applied_at.iso8601, unit: { name: room.health_unit.name }, title: title,
                                professional_name: nil, summary: nil, status: nil, document: nil)
    expect(shown[1]).to include(unit: nil, professional_name: nil, summary: nil, status: nil, document: nil)
    expect(shown.to_s).not_to include("LOTE-SECRETO", "UBS antiga")
  end

  it "vazia sem paciente; não consulta o interruptor (registro retido)" do
    create_immunization!(room, patient: patient, applied_at: Time.current)
    Platform::Features.set!(city: Current.city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
    expect(entries.size).to eq(1)
    expect(described_class.entries(person: Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: true), before: nil, limit: 5, from: nil, to: nil)).to eq([])
  end

  it "ordem com outras entradas, janela e cursor" do
    old = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-03-01 09:00:00"))
    newer = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-01 09:00:00"))
    page = Timeline::Query.call(person: person, kinds: %w[vaccination], limit: 1)
    expect(page.entries.map(&:source_id)).to eq([ newer.id ])
    rest = Timeline::Query.call(person: person, kinds: %w[vaccination], limit: 1, before: Timeline::Cursor.decode(page.next_before))
    expect(rest.entries.map(&:source_id)).to eq([ old.id ])
    windowed = entries(from: Time.zone.parse("2026-09-01"), to: Time.zone.parse("2026-11-01"))
    expect(windowed.map(&:source_id)).to eq([ newer.id ])
  end

  it "Query: vaccination é kind conhecido e entra no citizen_kinds de quem é validado, não do declarado" do
    expect(Timeline::KINDS).to include("vaccination")
    expect(Timeline::Query.citizen_kinds(verified: true, documents: false)).to include("vaccination")
    expect(Timeline::Query.citizen_kinds(verified: true, documents: true)).to include("vaccination")
    expect(Timeline::Query.citizen_kinds(verified: false, documents: true)).not_to include("vaccination")
  end

  it "Query com citizen: true corta a cancelada; sem, mantém" do
    create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-20 09:00:00"), cancelled_at: Time.current,
                               cancelled_by_user: room_member!(room), cancel_reason: "Pessoa errada")
    expect(Timeline::Query.call(person: person, kinds: %w[vaccination]).entries.size).to eq(1)
    expect(Timeline::Query.call(person: person, kinds: %w[vaccination], citizen: true).entries).to eq([])
  end
end
