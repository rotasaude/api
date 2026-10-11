require "rails_helper"

# ADR 0035 (spec §4; contrato §2–§3): junta os fornecedores, ordena por
# occurred_at DESC, kind, id; corta em limit; next_before é o cursor da
# última entrada quando há mais. Review Focus 1.
RSpec.describe Timeline::Query do
  include ActiveSupport::Testing::TimeHelpers
  before do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    ensure_appointment_types!
  end

  let(:unit) { create_unit }
  let(:citizen) { verified_citizen!(81) }
  let(:person) { Timeline::Person.for_cpf(citizen.cpf) }
  let(:at) { Time.zone.parse("2026-09-15 08:00:00.123456") }
  # walk_in_attendance! cria também a triagem de origem (agora): o recorte de
  # kinds deixa o exemplo sobre os empates que ele monta.
  let(:kinds) { %w[attendance campaign] }

  def walk(n, at:) = Array.new(n) { walk_in_attendance!(unit, citizen: citizen, checked_in_at: at) }

  # campaign_recipients só aceita mudar a leitura e o SMS (trigger): o
  # instante vem do relógio, com microssegundos.
  def campaign_at(at)
    travel_to(at, with_usec: true) { recipient!(sent_campaign!(title: "Campanha #{SecureRandom.hex(2)}"), citizen) }
  end

  def drain(**opts)
    seen = []
    before = nil
    loop do
      page = described_class.call(person: person, before: before, limit: 2, **{ kinds: kinds }.merge(opts))
      seen.concat(page.entries.map { |e| "#{e.kind}:#{e.source_id}" })
      break unless page.next_before

      before = Timeline::Cursor.decode(page.next_before)
    end
    seen
  end

  it "percorre tudo com empates de horário entre kinds e no mesmo kind, sem repetir nem perder (Review Focus 1)" do
    walk(3, at: at)
    2.times { campaign_at(at) }
    walk(1, at: at - 1.day)
    campaign_at(at + 1.day)
    all = described_class.call(person: person, kinds: kinds, limit: 100).entries
    expect(all.size).to eq(7)
    expect(all.map(&:sort_key)).to eq(all.map(&:sort_key).sort)
    expect(drain).to eq(all.map { |e| "#{e.kind}:#{e.source_id}" })
    expect(drain(kinds: %w[attendance]).size).to eq(4)
    expect(drain(from: at.beginning_of_day, to: at.end_of_day).size).to eq(5)
  end

  it "limit corta e só a última página tem next_before nulo" do
    walk(3, at: at)
    first = described_class.call(person: person, kinds: kinds, limit: 2)
    expect(first.entries.size).to eq(2)
    expect(first.next_before).to be_present
    last = described_class.call(person: person, kinds: kinds, limit: 2, before: Timeline::Cursor.decode(first.next_before))
    expect([ last.entries.size, last.next_before ]).to eq([ 1, nil ])
  end

  it "limit: padrão 50, teto 100, lixo vira padrão" do
    expect([ nil, "", "abc", "0", "-3", 7, "7", "150" ].map { |raw| described_class.limit(raw) }).to eq([ 50, 50, 50, 50, 50, 7, 7, 100 ])
  end

  it "kinds do cidadão: declarado só triage e appointment; documentos só com o interruptor" do
    expect(described_class.citizen_kinds(verified: false, documents: true)).to eq(%w[triage appointment])
    expect(described_class.citizen_kinds(verified: true, documents: false)).not_to include("clinical_document", "controlled_notification")
    expect(described_class.citizen_kinds(verified: true, documents: true)).to eq(Timeline::KINDS)
  end

  it "formas JSON do profissional e do cidadão" do
    walk(1, at: at)
    entry = described_class.call(person: person, kinds: %w[attendance]).entries.sole
    expect(Timeline::Json.professional(entry).keys)
      .to eq(%i[id kind occurred_at unit professional title summary status detail_ref])
    expect(Timeline::Json.professional(entry)[:id]).to eq("attendance:#{entry.source_id}")
    expect(Timeline::Json.citizen(entry).keys).to eq(%i[id kind occurred_at unit professional_name title summary status document])
    expect(Timeline::Json.citizen(entry)[:document]).to be_nil
    expect(Timeline::Json.citizen(entry)[:unit]).to eq(name: unit.name)
  end

  it "trilha só com ids, acesso da lista e person_ref" do
    Timeline::Trail.viewed!(person: person, access: "citizen")
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to eq("patient_id" => nil, "user_id" => nil, "access" => "citizen", "reason_code" => nil,
             "person_ref" => "citizen:#{citizen.id}")
    expect { Timeline::Trail.viewed!(person: person, access: "outro") }.to raise_error(ArgumentError)
  end
end
