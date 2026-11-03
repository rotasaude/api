require "rails_helper"

# Módulo 29, revisão final I3 (ruling da coordenação): `go_live_on` só entre
# hoje − 2 anos e hoje + 1 ano no dia da cidade; fora disso 422 out_of_range.
# Uma troca publica `vaccination.settings_changed` só com ids (nunca a data).
RSpec.describe Vaccination::SaveSettings do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:today) { Date.new(2026, 11, 2) }

  def save(value) = described_class.call(attrs: { "go_live_on" => value }, by: admin, today: today)
  def events = DomainEvent.where(name: "vaccination.settings_changed").order(:created_at, :id).map(&:payload)

  it "fora da faixa → out_of_range com o path; nada é gravado nem publicado" do
    [ "2024-11-01", "2027-11-03", "1990-01-01", "2207-11-02" ].each do |value|
      result = save(value)
      expect([ result.reason, result.details ]).to eq([ :out_of_range, { path: "go_live_on", problems: [ { path: "go_live_on", error: "out_of_range" } ] } ])
    end
    expect(VaccinationSetting.current.go_live_on).to be_nil
    expect(events).to be_empty
  end

  it "nas bordas e dentro grava e publica só com ids; repetir a mesma data não publica de novo" do
    %w[2024-11-02 2027-11-02 2026-10-01].each { |value| expect(save(value)).to be_ok }
    expect(VaccinationSetting.current.go_live_on).to eq(Date.new(2026, 10, 1))
    expect(save("2026-10-01")).to be_ok
    expect(events).to eq([ { "vaccination_setting_id" => 1, "user_id" => admin.id } ] * 3)
    expect(events.to_s).not_to include("2026-10-01")
  end

  it "nulo limpa e publica" do
    save("2026-10-01")
    expect(save(nil)).to be_ok
    expect(VaccinationSetting.current.go_live_on).to be_nil
    expect(events.size).to eq(2)
  end

  it "sem today, usa o dia da cidade" do
    expect(described_class.call(attrs: { "go_live_on" => Time.zone.today.iso8601 }, by: admin)).to be_ok
    expect(described_class.call(attrs: { "go_live_on" => (Time.zone.today >> 13).iso8601 }, by: admin).reason).to eq(:out_of_range)
  end
end
