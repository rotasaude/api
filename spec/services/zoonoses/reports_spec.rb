require "rails_helper"

# Módulo 35b, Task 15 (ADR 0054; contrato §8, Q5, Q19, Q25): os seis relatórios
# na forma { name, columns, rows, notes? }; SmallCount (1–4) só em demands e
# observations; rabies_weekly sem supressão, com as duas coberturas e a semana
# depois do fim previsto marcada; filtro inválido → invalid_request com path.
RSpec.describe Zoonoses::Reports, type: :model do
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let!(:uvz) { uvz_unit! }
  let!(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:period) { { from: (today - 30).iso8601, to: (today + 1).iso8601 } }

  def build(name, **filters)
    result = described_class.build(name, filters: filters.transform_keys(&:to_s))
    expect(result).to be_ok
    result.payload[:report]
  end

  def cell(report, key, where) = report[:rows].find { |row| where.all? { |k, v| row[k] == v } }&.fetch(key)

  it "demands com 3 escorpiões → célula suprimida; 6 → número" do
    3.times { zoonoses_demand!(subtype: "scorpion") }
    6.times { zoonoses_demand!(subtype: "bat") }
    report = build("demands", **period)

    expect(cell(report, "count", "subtype" => "Escorpião", "state" => "Aberta")).to eq(Admin::SmallCount::SUPPRESSED)
    expect(cell(report, "count", "subtype" => "Morcego", "state" => "Aberta")).to eq(6)
    expect(report[:columns].pluck(:key)).to eq(%w[subtype state color count])
    # Sem total: nenhuma linha some as células.
    expect(report[:rows].pluck("subtype")).not_to include("Total")
  end

  it "observations: 3 → suprimida; 5 não, por desfecho e espécie" do
    3.times { bite_observation!(species: "dog") }
    5.times { bite_observation!(species: "cat") }
    report = build("observations", **period)

    expect(cell(report, "count", "outcome" => "Em observação", "species" => "Cão")).to eq(Admin::SmallCount::SUPPRESSED)
    expect(cell(report, "count", "outcome" => "Em observação", "species" => "Gato")).to eq(5)
  end

  it "rabies_weekly sem supressão (2 doses aparecem 2) e com as duas coberturas" do
    campaign = RabiesCampaign.create!(name: "Campanha", year: today.year, starts_on: today - 3, ends_on: today + 20, goal_dogs: 8,
                                      goal_cats: 0, stage: "open")
    2.times { rabies_vaccination!(animal: animal!, campaign: campaign, modality: "fixed_post", vaccinated_on: today) }
    report = build("rabies_weekly", **period)

    row = report[:rows].last
    expect(row).to include("dogs" => 2, "dogs_total" => 2, "goal_dogs" => 8, "dog_coverage" => "25.0", "after_planned_end" => false)
    expect(row).to have_key("dog_coverage_estimate")
    expect(report[:columns].pluck(:key)).to include("dog_coverage", "dog_coverage_estimate")
  end

  it "rabies_weekly: campanha aberta com dose depois do fim → a semana extra é marcada no JSON e no CSV" do
    campaign = RabiesCampaign.create!(name: "Campanha", year: today.year, starts_on: today - 40, ends_on: today - 20, goal_dogs: 10,
                                      goal_cats: 0, stage: "open")
    rabies_vaccination!(animal: animal!, campaign: campaign, modality: "fixed_post", vaccinated_on: today)
    report = build("rabies_weekly", from: (today - 40).iso8601, to: today.iso8601)

    late = report[:rows].select { _1["after_planned_end"] }
    expect(late).not_to be_empty
    expect(late.last).to include("dogs" => 1, "remark" => "após o fim previsto da campanha")
    expect(report[:rows].first["after_planned_end"]).to be(false)
    expect(report[:notes].join).to include("após o fim previsto da campanha")
    csv = VectorControl::Csv.build(report)
    expect(csv).to include("Observação").and include("após o fim previsto da campanha")
  end

  it "rabies_modalities conta por modalidade e espécie, sem as anuladas" do
    animal = animal!
    rabies_vaccination!(animal: animal, vaccinated_on: today)
    rabies_vaccination!(animal: animal!(species: "cat"), vaccinated_on: today)
    cancelled = rabies_vaccination!(animal: animal!, vaccinated_on: today)
    cancelled.update_columns(cancelled_at: Time.current, cancel_reason: "Erro de digitação do registro")
    report = build("rabies_modalities", **period)

    expect(cell(report, "doses", "modality" => "Rotina", "species" => "Cão")).to eq(1)
    expect(cell(report, "doses", "modality" => "Rotina", "species" => "Gato")).to eq(1)
    expect(cell(report, "doses", "modality" => "Posto fixo", "species" => "Cão")).to eq(0)
  end

  it "shelter conta a lotação aberta e as eutanásias por motivo" do
    open_stay = shelter_stay!(animal: animal!, entered_on: today - 2)
    closed = shelter_stay!(animal: animal!, entered_on: today - 5)
    closed.update!(exited_on: today - 1, exit_kind: "adopted")
    euthanasia!(animal: animal!, reason: "leishmaniasis")
    euthanasia!(animal: animal!, reason: "untreatable_suffering")
    euthanasia!(animal: animal!, reason: "leishmaniasis")
    report = build("shelter", **period)

    expect(open_stay).to be_open
    expect(cell(report, "count", "section" => "Lotação atual")).to eq(1)
    expect(cell(report, "count", "section" => "Entradas", "kind" => "Recolhimento")).to eq(2)
    expect(cell(report, "count", "section" => "Saídas", "kind" => "Adoção")).to eq(1)
    expect(cell(report, "count", "section" => "Eutanásias", "kind" => "Leishmaniose visceral canina")).to eq(2)
    expect(cell(report, "count", "section" => "Eutanásias", "kind" => "Sofrimento irreversível, sem controle possível")).to eq(1)
  end

  it "leish traz a prevalência do Prevalence" do
    block = city_block!(neighborhood: Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual"), number: "1")
    survey = leish_survey!(blocks: [ block ])
    house = registry_household!.tap { |row| vector_profile!(row, block: block) }
    reactive = animal!(household: house)
    clean = animal!(household: house)
    untested = animal!(household: house)
    outside = animal!(household: registry_household!.tap { |row| vector_profile!(row, block: city_block!(neighborhood: block.neighborhood, number: "9")) })
    [ [ reactive, "reactive" ], [ clean, "non_reactive" ] ].each_with_index do |(dog, elisa), index|
      LeishTest.create!(animal: dog, leish_survey: survey, collected_on: today, label: "LV-#{today.year}-#{survey.id.delete('-')[0, 6].upcase}-000#{index + 1}",
                        dpp_result: "reactive", dpp_on: today, elisa_result: elisa, elisa_on: today)
    end
    collar!(animal: reactive, placed_on: today, due_on: today + 10)
    collar!(animal: untested, placed_on: today, due_on: today + 200)
    collar!(animal: outside, placed_on: today, due_on: today + 10)
    collar!(animal: clean, placed_on: survey.starts_on - 1, due_on: today + 5)
    report = build("leish", **period, survey_id: survey.id)

    row = report[:rows].sole
    expect(row).to include("examined" => 2, "reactive" => 1, "prevalence" => "50.0", "collars_placed" => 2, "collars_due" => 2)
    expect(row["prevalence"]).to eq(format("%.1f", Zoonoses::Prevalence.for(survey)[:prevalence]))
  end

  it "filtros: período ausente ou invertido → path from; id desconhecido → o próprio path" do
    [ {}, { to: today.iso8601 }, { from: today.iso8601, to: (today - 1).iso8601 }, { from: "x", to: today.iso8601 } ].each do |filters|
      result = described_class.build("shelter", filters: filters.transform_keys(&:to_s))
      expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: "from" } ])
    end
    expect(described_class.build("shelter", filters: { "from" => today.iso8601 }).details).to eq({ path: "to" })
    result = described_class.build("leish", filters: { "from" => today.iso8601, "to" => today.iso8601, "survey_id" => SecureRandom.uuid })
    expect(result.details).to eq({ path: "survey_id" })
    result = described_class.build("rabies_weekly", filters: { "from" => today.iso8601, "to" => today.iso8601, "campaign_id" => "x" })
    expect(result.details).to eq({ path: "campaign_id" })
  end
end
