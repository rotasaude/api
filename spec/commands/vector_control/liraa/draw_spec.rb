require "rails_helper"

# Módulo 35a (contrato §7; Q16, Q17, Q18; A-4): o sorteio do LIRAa. Faixas e
# amostra pequenas por parâmetros gravados (a aritmética do tamanho real está
# no sample_spec); `random` fixo.
RSpec.describe VectorControl::Liraa::Draw, type: :model do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:area) { registry_micro_area!(code: "07") }

  def neighborhood!(name) = Neighborhood.create!(name: "#{name} #{SecureRandom.hex(3)}", source: "manual")
  def draw(survey, start: 1) = described_class.call(survey: survey, by: coordinator, random: fixed_random(start))
  def items_of(survey) = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id })
  def drawn_numbers(survey) = LiraaStratumBlock.where(liraa_survey_id: survey.id, drawn: true).includes(:city_block)
                                               .map { |row| row.city_block.number }

  it "r = 3 e k = 3 → 3º, 6º e 9º quarteirões, em (bairro, número natural; Q18): 5 < 10 e Alto antes de Batel" do
    # 9 quarteirões × 5 imóveis: N = 45; base 3 → n = ⌈3 ÷ (1 + 3 ÷ 45)⌉ = ⌈2,8⌉ = 3;
    # h = ⌈0,2 · 45 ÷ 9⌉ = 1; b = 3; k = ⌊9 ÷ 3⌋ = 3. Ordem: Alto 5 6 7 8 10, Batel 1 2 3 4.
    version = liraa_parameters!(liraa_standard_min: 20, liraa_standard_max: 100, liraa_half_min: 10, liraa_base_sample: 3)
    batel = neighborhood!("Batel")
    alto = neighborhood!("Alto")
    blocks = %w[1 2 3 4].map { |number| city_block!(neighborhood: batel, number: number) } +
             %w[10 5 6 7 8].map { |number| city_block!(neighborhood: alto, number: number) }
    blocks.each { |block| liraa_households!(block, 5, micro_area: area) }
    strategic = liraa_households!(blocks.first, 2, micro_area: area, property_type: "4") # PE fora de N (Q16(d))
    survey = liraa_survey!([ { mode: "standard", blocks: blocks } ])
    events = []
    allow(DomainEvents).to receive(:publish).and_wrap_original { |m, *args, **kw| events << [ args.first, kw ]; m.call(*args, **kw) }

    result = draw(survey, start: 3)

    expect(result).to be_ok
    expect(survey.reload).to have_attributes(status: "drawn", parameters_version: version.version, version: 2)
    expect(survey.drawn_at).to be_present
    expect(survey.strata.sole).to have_attributes(households_count: 45, sample_target: 3, block_interval: 3, random_start: 3)
    expect(drawn_numbers(survey)).to contain_exactly("7", "1", "4")
    expect(LiraaStratumBlock.where(liraa_survey_id: survey.id, drawn: true).pluck(:household_start)).to eq([ 1, 1, 1 ])
    base = described_class.base(blocks.map(&:id))
    LiraaStratumBlock.where(liraa_survey_id: survey.id).find_each do |row| # Q25: a base do sorteio, só no sorteado
      expect(row.base_household_ids).to eq(row.drawn ? base.fetch(row.city_block_id) : nil)
    end
    expect(items_of(survey).pluck(:position)).to eq([ 1, 1, 1 ]) # ⌈0,2 · 5⌉ = 1, o 1º
    expect(items_of(survey).pluck(:household_id) & strategic.map(&:id)).to be_empty
    expect(events).to include([ "liraa_survey.drawn", { liraa_survey_id: survey.id, user_id: coordinator.id } ])
  end

  it "quarteirão com 12 imóveis: standard → 1, 6, 11; half (Q17) → 1, 3, 5, 7, 9, 11; census → todos" do
    neighborhood = neighborhood!("Centro")
    block = city_block!(neighborhood: neighborhood, number: "1")
    homes = liraa_households!(block, 12, micro_area: area)
    order = Household.where(id: homes.map(&:id)).order(:registered_at, :id).pluck(:id)
    by_position = ->(survey) { items_of(survey).order(:position).pluck(:position, :household_id) }

    # N = 12; n = ⌈450 ÷ (1 + 450 ÷ 12)⌉ = 12; h = ⌈0,2 · 12⌉ = 3; b = 4; k = 1.
    liraa_parameters!(liraa_standard_min: 10, liraa_standard_max: 100, liraa_half_min: 5)
    standard = liraa_survey!([ { mode: "standard", blocks: [ block ] } ])
    expect(draw(standard, start: 9)).to be_ok # k = 1: o início é 1, sem sorteio
    expect(standard.strata.sole).to have_attributes(sample_target: 12, block_interval: 1, random_start: 1)
    expect(by_position.call(standard)).to eq([ 1, 6, 11 ].map { |at| [ at, order[at - 1] ] })

    # half: 5 ≤ 12 < 20; h = ⌈0,5 · 12⌉ = 6; ⌈0,5 · 12⌉ = 6 imóveis, intervalo round(1 ÷ 0,5) = 2.
    liraa_parameters!(liraa_standard_min: 20, liraa_standard_max: 100, liraa_half_min: 5)
    half = liraa_survey!([ { mode: "half", blocks: [ block ] } ])
    expect(draw(half)).to be_ok
    expect(by_position.call(half).map(&:first)).to eq([ 1, 3, 5, 7, 9, 11 ])

    liraa_parameters!(liraa_standard_min: 20, liraa_standard_max: 100, liraa_half_min: 13)
    census = liraa_survey!([ { mode: "census", blocks: [ block ] } ])
    expect(draw(census)).to be_ok
    expect(by_position.call(census).map(&:first)).to eq((1..12).to_a)
    expect(census.strata.sole).to have_attributes(households_count: 12, sample_target: 12, block_interval: 1, random_start: 1)
  end

  it "A-4: sem parâmetros gravados → parameters_version 0 (o padrão de fábrica)" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "3")
    liraa_households!(block, 3, micro_area: area)
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] } ])

    expect(draw(survey)).to be_ok
    expect(survey.reload).to have_attributes(status: "drawn", parameters_version: 0)
    expect(items_of(survey).count).to eq(3)
  end

  it "estrato fora da faixa → stratum_out_of_range path strata[1], nada gravado" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "1")
    other = city_block!(neighborhood: block.neighborhood, number: "2")
    liraa_households!(block, 3, micro_area: area)
    liraa_households!(other, 3, micro_area: area)
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] }, { mode: "standard", blocks: [ other ] } ])

    result = draw(survey)

    expect([ result.reason, result.details ]).to eq([ :stratum_out_of_range, { path: "strata[1]" } ])
    expect(survey.reload).to have_attributes(status: "draft", parameters_version: nil, version: 1)
    expect(survey.strata.order(:created_at).pluck(:households_count, :sample_target)).to eq([ [ 3, nil ], [ 3, nil ] ]) # N do rascunho (Q24)
    expect(LiraaStratumBlock.where(liraa_survey_id: survey.id, drawn: true)).to be_empty
    expect(items_of(survey)).to be_empty
  end

  it "segundo sorteio → survey_not_draft; nada muda" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "1")
    liraa_households!(block, 2, micro_area: area)
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] } ])
    expect(draw(survey)).to be_ok

    again = draw(LiraaSurvey.find(survey.id))
    expect(again.reason).to eq(:survey_not_draft)
    expect(items_of(survey).count).to eq(2)
    expect(survey.reload.version).to eq(2)
  end

  it "inativo, sem perfil ou de outro quarteirão fica fora da base" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "1")
    homes = liraa_households!(block, 2, micro_area: area)
    registry_household_rows!(area, neighborhood_id: block.neighborhood_id) # sem perfil
    elsewhere = city_block!(neighborhood: block.neighborhood, number: "2")
    liraa_households!(elsewhere, 1, micro_area: area)
    Household.where(id: homes.last.id).update_all(status: "inactive")
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] } ])

    expect(draw(survey)).to be_ok
    expect(items_of(survey).pluck(:household_id)).to eq([ homes.first.id ])
  end

  it "Q24: estrato de 2.010 imóveis com 20 PE → N 1.990 no rascunho, e o sorteio recusa (half exige N ≥ 2.000)" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "1")
    ids = liraa_bulk_households!(block, 1990, micro_area: area)
    strategic = liraa_bulk_households!(block, 20, micro_area: area, property_type: "4")
    expect(HouseholdVersion.find_by!(household_id: ids.last).address).to eq(HouseholdVersion.find_by!(household_id: ids.first).address)
    expect(VectorControl::Json.blocks([ block.reload ]).sole[:households_count]).to eq(2010) # CityBlock.households_count conta PE
    survey = liraa_survey!([ { mode: "half", blocks: [ block ] } ])

    expect(survey.strata.sole.households_count).to eq(1990)
    expect(VectorControl::Json.liraa_survey(survey)[:strata].sole[:households_count]).to eq(1990)
    expect(described_class.base([ block.id ]).fetch(block.id).size).to eq(1990)
    expect(described_class.base([ block.id ]).fetch(block.id) & strategic).to be_empty

    result = draw(survey)
    expect([ result.reason, result.details ]).to eq([ :stratum_out_of_range, { path: "strata[0]" } ])
    expect(survey.reload.status).to eq("draft")
    expect(survey.strata.sole.households_count).to eq(1990)
  end

  it "quarteirão desativado depois da gravação → invalid_request path strata[i], nada gravado" do
    block = city_block!(neighborhood: neighborhood!("Centro"), number: "1")
    other = city_block!(neighborhood: block.neighborhood, number: "2")
    liraa_households!(block, 2, micro_area: area)
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] }, { mode: "census", blocks: [ other ] } ])
    other.update!(active: false, version: other.version + 1)

    result = draw(survey)

    expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: "strata[1]" } ])
    expect(survey.reload).to have_attributes(status: "draft", version: 1)
    expect(items_of(survey)).to be_empty
  end
end
