require "rails_helper"

# Spec §3.2: pré-visualização sem gravar, com faixas efetivas e vagas de cada
# faixa agendável cujo tipo serve o CBO da amostra.
RSpec.describe Scheduling::TemplatePreview do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:day) { Time.zone.today + 3 }
  let(:blocks) do
    [ { "starts" => "07:00", "ends" => "09:00", "kind" => "walk_in" },
      { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica" },
      { "starts" => "10:00", "ends" => "10:30", "kind" => "bookable", "appointment_type_key" => "consulta_enfermagem" },
      { "starts" => "11:00", "ends" => "12:00", "kind" => "blocked" } ]
  end
  let(:sample) { { "starts_at" => day.in_time_zone.change(hour: 7).iso8601, "ends_at" => day.in_time_zone.change(hour: 13).iso8601, "cbo_code" => "225125" } }

  it "vagas só do tipo que o CBO atende; faixas na forma do contrato; nada gravado" do
    result = described_class.call(blocks: blocks, fit_in_limit: 2, sample: sample)
    expect(result.payload[:slots].map { |s| [ Time.zone.parse(s[:starts_at]).strftime("%H:%M"), s[:appointment_type_key] ] })
      .to eq([ [ "09:00", "consulta_medica" ], [ "09:20", "consulta_medica" ], [ "09:40", "consulta_medica" ] ])
    expect(result.payload[:blocks]).to eq([
      { starts: "07:00", ends: "09:00", kind: "walk_in" },
      { starts: "09:00", ends: "10:00", kind: "bookable", appointment_type_key: "consulta_medica", appointment_type_name: "Consulta médica" },
      { starts: "10:00", ends: "10:30", kind: "bookable", appointment_type_key: "consulta_enfermagem", appointment_type_name: "Consulta de enfermagem" },
      { starts: "11:00", ends: "12:00", kind: "blocked" }
    ])
    expect(ScheduleTemplate.count).to eq(0)
  end

  it "recusa faixas, limite e amostra inválidos" do
    expect(described_class.call(blocks: [], fit_in_limit: 2, sample: sample).details).to eq(detail: "empty")
    expect(described_class.call(blocks: blocks, fit_in_limit: -1, sample: sample).reason).to eq(:invalid_fit_in_limit)
    expect(described_class.call(blocks: blocks, fit_in_limit: 2, sample: sample.merge("ends_at" => sample["starts_at"])).reason).to eq(:invalid)
    expect(described_class.call(blocks: blocks, fit_in_limit: 2, sample: sample.merge("cbo_code" => "x")).reason).to eq(:invalid)
  end
end
