require "rails_helper"

# Módulo 31 (ADR 0049; contrato §10, P18, P46): a fonte do CAPS
# (`psychosocial`, só na rota da equipe lotada, sempre recortada pelo CAPS da
# matrícula) e o marcador do vínculo (`psychosocial_link`, só na linha do
# tempo do profissional). Nenhum dos dois entra em Timeline::KINDS. A fonte
# traz ação não cancelada, versão do PTS, permanência noturna e documento do
# 19 da ação — sem evolução, CID, substância nem texto do PTS. O marcador é
# "Acompanhamento no CAPS", sem nome nem modalidade da unidade, com início e
# fim. Relógio fixo no meio de novembro.
RSpec.describe Timeline::Sources::PsychosocialSource do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(name: "CAPS AD III Centro Vida", modality: "caps_ad_iii") }
  let(:staff) { caps_staff!(caps, cbo: "225133") }
  let(:enrollment) do
    enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 3), cid: "F102").tap { |e| e.update!(substances: [ "02" ]) }
  end
  let(:patient) { enrollment.patient }
  let(:person) { Timeline::Person.for_patient(patient) }
  # Nada clínico sai em nenhuma entrada (CID, substância, evolução e texto do
  # PTS); o marcador também não leva o nome nem a modalidade do CAPS (P46). A
  # fonte do CAPS leva a unidade: só a equipe lotada a lê.
  let(:clinical) { [ "F102", "Crack", "crack", "Isolamento" ] }
  let(:hidden) { clinical + [ "Centro Vida", "AD III", "caps_ad_iii" ] }

  def entries(unit_id = caps.id, **opts)
    described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, health_unit_id: unit_id, **opts)
  end

  def action_at(at, **attrs)
    record_action!(caps, staff, performed_at: at, participants: [ { enrollment_id: enrollment.id } ], **attrs)
  end

  def care_plan!(at, version: 1)
    PsychosocialCarePlan.create!(psychosocial_enrollment: enrollment, version: version, needs: "Isolamento social e uso de crack",
                                 goals: [ "Reduzir o uso" ], intensity: "intensive", review_on: Date.current + 90, created_by_user: staff,
                                 created_at: at)
  end

  def night_stay!(from, to)
    PsychosocialNightStay.create!(psychosocial_bed: bed!(caps), health_unit: caps, psychosocial_enrollment: enrollment, patient: patient,
                                  started_at: from, expected_end_at: to, started_by_user: staff)
  end

  it "ação, PTS, permanência e documento do paciente no CAPS; nada clínico, sem resumo nem visão do cidadão" do
    action = action_at(Time.zone.local(2026, 11, 10, 10), notes: "Relata uso diário de crack")
    cancelled = action_at(Time.zone.local(2026, 11, 11, 10))
    Psychosocial::CancelAction.call(action: cancelled, reason: "Lançada em duplicidade", by: staff)
    plan = care_plan!(Time.zone.local(2026, 11, 9, 9))
    stay = night_stay!(Time.zone.local(2026, 11, 12, 19), Time.zone.local(2026, 11, 13, 8))
    document = caps_document!(action, kind: "sick_note", issued_at: Time.zone.local(2026, 11, 10, 11))
    other = record_action!(caps, staff, performed_at: Time.zone.local(2026, 11, 10, 9), participants: [ { enrollment_id: enrollment!(caps).id } ])

    found = entries
    expect(found.map { |entry| [ entry.detail_ref[:type], entry.source_id ] }).to eq(
      [ [ "psychosocial_night_stay", stay.id ], [ "clinical_document", document.id ], [ "psychosocial_action", action.id ],
        [ "psychosocial_care_plan", plan.id ] ]
    )
    expect(found.map(&:source_id)).not_to include(cancelled.id, other.id)
    expect(found).to all(have_attributes(kind: "psychosocial", summary: nil, citizen: nil, document: nil,
                                         unit: { id: caps.id, name: caps.name }))
    by_type = found.index_by { |entry| entry.detail_ref[:type] }
    expect(by_type["psychosocial_action"]).to have_attributes(
      occurred_at: action.performed_at, title: Billing::Labels.procedure("0301080208", "202611"), status: "recorded",
      professional: { name: staff.professional.professional_name, cbo_code: "225133" }
    )
    expect(by_type["psychosocial_care_plan"]).to have_attributes(occurred_at: plan.created_at, title: "PTS versão 1", status: "recorded")
    expect(by_type["psychosocial_night_stay"]).to have_attributes(occurred_at: stay.started_at, title: "Acolhimento noturno", status: "open")
    expect(by_type["clinical_document"]).to have_attributes(occurred_at: document.issued_at, title: "Atestado", status: "issued")
    shown = found.map { |entry| Timeline::Json.professional(entry) }.to_json
    clinical.each { |text| expect(shown).not_to include(text) }
  end

  it "recorte pelo CAPS: outro CAPS, ou nenhum, não devolve nada; sem paciente, vazio" do
    action_at(Time.zone.local(2026, 11, 10, 10))
    expect(entries.size).to eq(1)
    expect(entries(caps!.id)).to eq([])
    expect(entries(nil)).to eq([])
    empty = Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: true)
    expect(described_class.entries(person: empty, before: nil, limit: 10, from: nil, to: nil, health_unit_id: caps.id)).to eq([])
  end

  it "o cursor pagina pela chave total entre as quatro origens; janela de período" do
    action = action_at(Time.zone.local(2026, 11, 10, 10))
    plan = care_plan!(Time.zone.local(2026, 11, 10, 10)) # mesmo instante da ação: desempata pelo id
    stay = night_stay!(Time.zone.local(2026, 11, 12, 19), Time.zone.local(2026, 11, 13, 8))
    document = caps_document!(action, issued_at: Time.zone.local(2026, 11, 14, 9))
    expected = [ document.id, stay.id ] + [ action.id, plan.id ].sort

    seen = []
    before = nil
    4.times do
      page = Timeline::Query.call(person: person, kinds: Timeline::Query::CAPS_ONLY_KINDS, before: before, limit: 1, psychosocial_unit_id: caps.id)
      seen.concat(page.entries.map(&:source_id))
      break unless page.next_before

      before = Timeline::Cursor.decode(page.next_before)
    end
    expect(seen).to eq(expected)
    expect(entries(from: Time.zone.local(2026, 11, 12, 0)).map(&:source_id)).to eq([ document.id, stay.id ])
  end

  it "Query sem psychosocial_unit_id não traz a fonte do CAPS" do
    action_at(Time.zone.local(2026, 11, 10, 10))
    expect(Timeline::Query.call(person: person, kinds: Timeline::Query::CAPS_ONLY_KINDS).entries).to eq([])
  end

  describe Timeline::Sources::PsychosocialLinkSource do
    def links(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

    it "uma entrada por matrícula: 'Acompanhamento no CAPS' sem nome, com início e fim; nada clínico; detail_ref nulo" do
      past = enrollment!(caps!(name: "CAPS II Boa Vista"), patient: patient, started_on: Date.new(2026, 9, 2), cid: "F200")
      past.update_columns(closed_on: Date.new(2026, 9, 30), destination: "01", closed_by_user_id: past.reference_user_id)
      found = links
      expect(found.map(&:source_id)).to eq([ enrollment.id, past.id ])
      expect(found.first).to have_attributes(kind: "psychosocial_link", occurred_at: Date.new(2026, 11, 3).in_time_zone,
                                             title: "Acompanhamento no CAPS", summary: "Desde 03/11/2026", status: "open",
                                             unit: nil, professional: nil, detail_ref: nil, citizen: nil, document: nil)
      expect(found.last).to have_attributes(summary: "02/09/2026 a 30/09/2026", status: "closed")
      shown = found.map { |entry| Timeline::Json.professional(entry) }.to_json
      (hidden + [ "Boa Vista", "F200" ]).each { |text| expect(shown).not_to include(text) }
    end

    it "pagina com o cursor (o kind entra no cursor) e respeita a janela" do
      past = enrollment!(caps!, patient: patient, started_on: Date.new(2026, 9, 2))
      past.update_columns(closed_on: Date.new(2026, 9, 30), destination: "01", closed_by_user_id: past.reference_user_id)
      first = Timeline::Query.call(person: person, kinds: Timeline::Query::LINK_KINDS, limit: 1)
      expect(first.entries.map(&:source_id)).to eq([ enrollment.id ])
      rest = Timeline::Query.call(person: person, kinds: Timeline::Query::LINK_KINDS, limit: 1, before: Timeline::Cursor.decode(first.next_before))
      expect([ rest.entries.map(&:source_id), rest.next_before ]).to eq([ [ past.id ], nil ])
      expect(links(from: Time.zone.local(2026, 10, 1)).map(&:source_id)).to eq([ enrollment.id ])
      expect(links(to: Time.zone.local(2026, 11, 2, 23)).map(&:source_id)).to eq([ past.id ])
    end
  end
end
