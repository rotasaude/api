require "rails_helper"

RSpec.describe Timeline::Cursor do
  let(:at) { Time.utc(2026, 10, 11, 12, 0, 0, 123_456) }
  let(:entry) do
    Timeline::Entry.new(kind: "attendance", source_id: "0b5f8f4e-8f69-4f3e-9d2c-6f3c2c1f0a11", occurred_at: at,
                        unit: nil, professional: nil, title: "t", summary: nil, status: nil,
                        detail_ref: { type: "attendance", id: "x" }, citizen: { title: "t", summary: nil, status: nil, professional_name: nil },
                        document: nil)
  end

  it "ida e volta com microssegundos, kind e id" do
    cursor = described_class.decode(described_class.encode(entry))
    expect([ cursor.at, cursor.kind, cursor.id ]).to eq([ at, "attendance", entry.source_id ])
    expect(cursor.at.usec).to eq(123_456)
  end

  it "vazio é nil; lixo, kind desconhecido e id que não é uuid levantam Invalid" do
    expect(described_class.decode(nil)).to be_nil
    expect(described_class.decode("")).to be_nil
    bad = [ "%%%", Base64.urlsafe_encode64("2026-10-11T12:00:00.000000Z|exam|#{entry.source_id}", padding: false),
            Base64.urlsafe_encode64("2026-10-11T12:00:00.000000Z|triage|1; DROP", padding: false),
            Base64.urlsafe_encode64("ontem|triage|#{entry.source_id}", padding: false), [ "x" ] ]
    bad.each { |raw| expect { described_class.decode(raw) }.to raise_error(Timeline::Cursor::Invalid), raw.inspect }
  end

  it "sort_key ordena por data decrescente, kind e id" do
    later = entry.with(occurred_at: at + 1)
    same_time_other_kind = entry.with(kind: "appointment")
    expect([ entry, later, same_time_other_kind ].sort_by(&:sort_key)).to eq([ later, same_time_other_kind, entry ])
  end
end
