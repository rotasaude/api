require "rails_helper"

# Módulo 24b, Task 17 (ADR 0052; contrato §12): a atividade coletiva na linha
# do tempo, só do profissional (Timeline::Query::PROFESSIONAL_ONLY_KINDS). Uma
# entrada por participação do paciente; título = rótulo do tipo; resumo
# "Participou" (e "avaliação alterada"), sem temas, públicos nem práticas; a
# marcada por engano some. Sem visão do cidadão (fail-closed).
RSpec.describe Timeline::Sources::CollectiveActivitySource do
  let!(:city) { home_visit_city!(collective: true) }
  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:patient) { registry_patient! }
  let(:person) { Timeline::Person.for_patient(patient) }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)
  def noon(on) = Time.zone.parse("#{on.iso8601} 12:00")

  def activity!(held_on: Date.current - 1, activity_type: 5, **over)
    CollectiveActivity.create!({ client_uuid: SecureRandom.uuid, team: team, health_unit: team.health_unit, professional: agent.professional,
                                 cbo: "322255", recorded_by_user: agent, held_on: held_on, shift: 1, activity_type: activity_type,
                                 place_text: "Salão MARCADOR-LOCAL", participants_count: 10, altered_count: 0, origin: "dashboard",
                                 health_topics: [ 1 ], health_practices: [ 22 ] }.merge(over))
  end

  def participant!(activity, patient: self.patient, **over)
    CollectiveActivityParticipant.create!({ collective_activity: activity, patient: patient }.merge(over))
  end

  it "uma entrada por participação: rótulo do tipo, 'Participou' (e avaliação alterada), sem temas" do
    group = activity!(held_on: Date.current - 1, altered_count: 1)
    mine = participant!(group, altered_evaluation: true, measurements: { "weight_kg" => 80 })
    participant!(group, patient: registry_patient!)
    education = activity!(held_on: Date.current - 3, activity_type: 4)
    plain = participant!(education, altered_evaluation: false)

    rows = entries
    expect(rows.map(&:source_id)).to eq([ mine.id, plain.id ])
    expect(rows.first).to have_attributes(kind: "collective_activity", occurred_at: noon(Date.current - 1), title: "Atendimento em grupo",
                                          summary: "Participou · avaliação alterada", status: "recorded",
                                          professional: { name: agent.professional.professional_name, cbo_code: "322255" },
                                          unit: { id: team.health_unit.id, name: team.health_unit.name }, detail_ref: nil, document: nil,
                                          citizen: nil)
    expect(rows.last).to have_attributes(title: "Educação em saúde", summary: "Participou")
    expect(rows.map { |entry| Timeline::Json.professional(entry) }.to_json).not_to include("MARCADOR")
  end

  it "atividade por engano some" do
    kept = participant!(activity!(held_on: Date.current - 1))
    wrong = activity!(held_on: Date.current - 2)
    participant!(wrong)
    wrong.update!(mistaken_at: Time.current, mistaken_by_user: agent, mistaken_reason: "lançada na equipe errada")

    expect(entries.map(&:source_id)).to eq([ kept.id ])
  end

  it "collective_activity nunca na visão do cidadão" do
    participant!(activity!)
    expect(Timeline::Query::PROFESSIONAL_ONLY_KINDS).to include("collective_activity")
    [ true, false ].product([ true, false ]).each do |verified, documents|
      expect(Timeline::Query.citizen_kinds(verified: verified, documents: documents)).not_to include("collective_activity")
    end
    expect(entries.map { |entry| Timeline::Json.citizen(entry) }).to eq([ nil ])
  end

  it "página: ordem e cursor pelo meio-dia do held_on; sem paciente, vazio" do
    newer = participant!(activity!(held_on: Date.current - 1))
    same_day = [ participant!(activity!(held_on: Date.current - 2)), participant!(activity!(held_on: Date.current - 2)) ].sort_by(&:id)

    expect(entries.map(&:source_id)).to eq([ newer.id, *same_day.map(&:id) ])
    first = Timeline::Query.call(person: person, kinds: %w[collective_activity], limit: 2)
    rest = Timeline::Query.call(person: person, kinds: %w[collective_activity], limit: 2, before: Timeline::Cursor.decode(first.next_before))
    expect(first.entries.map(&:source_id) + rest.entries.map(&:source_id)).to eq([ newer.id, *same_day.map(&:id) ])

    nobody = Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: false)
    expect(described_class.entries(person: nobody, before: nil, limit: 10, from: nil, to: nil)).to eq([])
  end
end
