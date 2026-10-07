require "rails_helper"
require Rails.root.join("lib/ledi_crew").to_s

# Spec §10 (parte de produção): a semente de dev dá ao painel uma competência
# com todos os estados, sem dado real e sem enviar nada.
RSpec.describe LediCrew do
  before { CityProfile.create!(name: "Maringá", ibge_code: "4115200") }

  it "semeia a competência corrente com todos os estados, uma vez" do
    expect(described_class.seed_current_city(slug: "maringa")).to eq(created: 12)
    expect(described_class.seed_current_city(slug: "maringa")).to eq(created: 0)

    competence = Ledi::Deadline.current(Time.zone.today)
    expect(LediOutboxEntry.for_competence(competence).group(:status).count)
      .to eq("accepted" => 6, "rejected" => 3, "pending" => 2, "failed" => 1)
    expect(LediOutboxEntry.where(status: "accepted").where.not(payload: nil)).to be_empty
    expect(LediOutboxEntry.where(status: "rejected").distinct.pluck(:last_error_codes).size).to eq(2)
    expect(LediOutboxEntry.pluck(:source_type).uniq).to eq([ "synthetic" ])
  end
end
