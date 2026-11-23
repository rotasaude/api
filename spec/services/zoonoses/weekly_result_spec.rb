require "rails_helper"

# Módulo 35b, Task 7 (ADR 0054; contrato §3, Q5, Q19): o resultado semanal da
# campanha antirrábica, por semana epidemiológica (Surveillance::EpiWeek), da
# semana de starts_on à mais tardia entre a de min(ends_on, hoje) e a da última
# dose: a dose vale de starts_on a hoje, sem o limite de ends_on (contrato §3,
# Q20), e a campanha aberta depois do fim não perde dose. Cães e gatos da semana e o acumulado, sem as
# doses anuladas; a cobertura sobre a meta (nil com meta 0) e sobre a
# estimativa de população (só quando houver estimativa), uma casa decimal.
# Nenhuma contagem é suprimida (Q5).
RSpec.describe Zoonoses::WeeklyResult, type: :model do
  let!(:city) { zoonoses_city! }
  let(:vaccine) { zoonoses_product! }
  # 2026-09-06 é domingo (início da SE 36 de 2026); quatro semanas, até sábado 2026-10-03.
  let(:starts_on) { Date.new(2026, 9, 6) }
  let(:today) { Date.new(2026, 11, 23) }

  def campaign!(goal_dogs: 30, goal_cats: 20, starts_on: self.starts_on, ends_on: self.starts_on + 27, stage: "open")
    RabiesCampaign.create!(name: "Campanha #{SecureRandom.hex(3)}", year: starts_on.year, starts_on: starts_on, ends_on: ends_on,
                           goal_dogs: goal_dogs, goal_cats: goal_cats, stage: stage)
  end

  def doses!(campaign, on:, count:, species: "dog", **over)
    Array.new(count) do
      rabies_vaccination!(animal: nil, species: species, modality: "fixed_post", campaign: campaign, vaccinated_on: on,
                          product: vaccine, **over)
    end
  end

  def estimate!(dogs: nil, cats: nil)
    ZoonosesParameterVersion.create!(version: 1, values: { "dog_population_estimate" => dogs, "cat_population_estimate" => cats },
                                     created_by_user: zoonoses_coordinator!)
  end

  def weekly(campaign, today: self.today) = described_class.for(campaign: campaign, today: today)

  it "campanha de 4 semanas, 10 cães na 1ª e 5 na 2ª, meta 30 → acumulado 10 e 15, cobertura 33.3 e 50.0" do
    campaign = campaign!
    doses!(campaign, on: starts_on + 2, count: 10)
    doses!(campaign, on: starts_on + 9, count: 5)
    doses!(campaign, on: starts_on + 10, count: 2, species: "cat")

    rows = weekly(campaign)
    expect(rows.pluck(:epi_week)).to eq(%w[2026-36 2026-37 2026-38 2026-39])
    expect(rows.map { _1.values_at(:dogs, :dogs_total, :dog_coverage) }).to eq([ [ 10, 10, 33.3 ], [ 5, 15, 50.0 ], [ 0, 15, 50.0 ], [ 0, 15, 50.0 ] ])
    expect(rows.map { _1.values_at(:cats, :cats_total, :cat_coverage) }).to eq([ [ 0, 0, 0.0 ], [ 2, 2, 10.0 ], [ 0, 2, 10.0 ], [ 0, 2, 10.0 ] ])
    expect(rows.first).to include(goal_dogs: 30, goal_cats: 20, dog_coverage_estimate: nil, cat_coverage_estimate: nil)
    expect(rows.first.keys).to eq(%i[epi_week dogs cats dogs_total cats_total goal_dogs goal_cats dog_coverage cat_coverage
                                     dog_coverage_estimate cat_coverage_estimate])
  end

  it "dose anulada não conta; dose de outra campanha e de rotina também não" do
    campaign = campaign!
    kept, cancelled = doses!(campaign, on: starts_on, count: 2)
    cancelled.update!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado")
    doses!(campaign!(starts_on: starts_on - 60, ends_on: starts_on - 40, stage: "closed"), on: starts_on, count: 3)
    rabies_vaccination!(vaccinated_on: starts_on, product: vaccine)

    expect(kept).to be_present
    expect(weekly(campaign).first).to include(dogs: 1, dogs_total: 1)
  end

  it "meta 0 → cobertura nil; nenhuma contagem suprimida (Q5)" do
    campaign = campaign!(goal_dogs: 0, goal_cats: 0)
    doses!(campaign, on: starts_on, count: 1)
    expect(weekly(campaign).first).to include(dogs: 1, dog_coverage: nil, cat_coverage: nil)
  end

  it "estimativa de 100 cães e 15 doses → dog_coverage_estimate 15.0; sem estimativa → nil" do
    campaign = campaign!
    doses!(campaign, on: starts_on, count: 15)
    expect(weekly(campaign).first).to include(dog_coverage_estimate: nil, cat_coverage_estimate: nil)

    estimate!(dogs: 100)
    expect(weekly(campaign).first).to include(dogs_total: 15, dog_coverage: 50.0, dog_coverage_estimate: 15.0, cat_coverage_estimate: nil)
  end

  it "dose em 2026-01-01 cai em 2025-53" do
    campaign = campaign!(starts_on: Date.new(2025, 12, 28), ends_on: Date.new(2026, 1, 10))
    doses!(campaign, on: Date.new(2026, 1, 1), count: 1)
    rows = weekly(campaign, today: Date.new(2026, 2, 1))
    expect(rows.map { _1.values_at(:epi_week, :dogs, :dogs_total) }).to eq([ [ "2025-53", 1, 1 ], [ "2026-01", 0, 1 ] ])
  end

  it "campanha aberta depois de ends_on com dose depois do fim: as linhas vão até a semana da dose e o acumulado a inclui" do
    campaign = campaign!
    doses!(campaign, on: starts_on + 2, count: 3)
    doses!(campaign, on: starts_on + 27 + 10, count: 2) # terça-feira da SE 41 (2026-10-13), depois do fim (sábado da SE 39)

    rows = weekly(campaign)
    expect(rows.pluck(:epi_week)).to eq(%w[2026-36 2026-37 2026-38 2026-39 2026-40 2026-41])
    expect(rows.last).to include(dogs: 2, dogs_total: 5, dog_coverage: 16.7)
    expect(rows[3]).to include(dogs: 0, dogs_total: 3)
  end

  it "campanha em curso para na semana de hoje; ainda não começada → []" do
    campaign = campaign!
    doses!(campaign, on: starts_on + 8, count: 4)
    expect(weekly(campaign, today: starts_on + 8).pluck(:epi_week, :dogs_total)).to eq([ [ "2026-36", 0 ], [ "2026-37", 4 ] ])
    expect(weekly(campaign, today: starts_on - 1)).to eq([])
  end
end
