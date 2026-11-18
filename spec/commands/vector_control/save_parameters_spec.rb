require "rails_helper"

# Módulo 35a, Task 14 (contrato §11; A-4, A-5, Q17): a coordenação grava os
# parâmetros técnicos por versão. As 20 chaves do defaults.yml, nenhuma a mais
# nem a menos, cada uma na faixa do A-5 (Q17: liraa_half_household_fraction
# como a liraa_household_fraction); recusa → invalid_parameter com o path
# values.<chave>, só o primeiro erro. Cada edição cria a versão seguinte (só
# acréscimo); o LIRAa sorteado antes guarda a versão do sorteio.
RSpec.describe VectorControl::SaveParameters, type: :model do
  let!(:city) { block_city! } # a lista de doenças da plataforma (block_diseases)
  let(:coordinator) { endemic_coordinator! }
  let(:factory) { VectorControl::Parameters.defaults }

  def save(**over) = save_values(factory.merge(over.stringify_keys))
  def save_values(values) = described_class.call(values: values, by: coordinator)

  def refused_path(result)
    expect(result).to be_failure
    expect(result.reason).to eq(:invalid_parameter)
    result.details[:path]
  end

  it "cada chave fora da faixa do A-5 → invalid_parameter path values.<chave>; nada gravado" do
    outside = {
      default_days: 6, strategic_point_days: 366, block_radius_rings: 6, block_grouping_days: 0, block_diseases: [],
      ubv_cycles_max: 6, ubv_cycle_days_min: 0, ubv_cycle_days_max: 16, ubv_cycle_interval_days: 31,
      ovitrap_collection_days_min: 0, ovitrap_collection_days_max: 31, ovitrap_alert_eggs: 10_000, ovitrap_radius_rings: -1,
      liraa_standard_min: 0, liraa_standard_max: 100_001, liraa_half_min: 0, liraa_base_sample: 10_001,
      liraa_household_fraction: 1.01, liraa_half_household_fraction: 0.005, iip_bands: [ 1.0, 100.5 ]
    }
    expect(outside.keys.map(&:to_s).sort).to eq(factory.keys.sort)
    outside.each do |key, value|
      expect(refused_path(save(key => value))).to eq("values.#{key}"), "#{key} = #{value.inspect}"
    end
    expect(VectorParameterVersion.count).to eq(0)
  end

  it "tipo errado → invalid_parameter path values.<chave>" do
    {
      default_days: "60", strategic_point_days: 15.0, block_radius_rings: true, ovitrap_alert_eggs: nil,
      liraa_household_fraction: "0.2", liraa_half_household_fraction: 0.255, iip_bands: [ 1.0 ],
      block_diseases: "dengue"
    }.each do |key, value|
      expect(refused_path(save(key => value))).to eq("values.#{key}"), "#{key} = #{value.inspect}"
    end
    expect(refused_path(save(iip_bands: [ 1.0, "4.0" ]))).to eq("values.iip_bands")
    expect(refused_path(save(iip_bands: [ 1.0, 2.0, 3.0 ]))).to eq("values.iip_bands")
    expect(refused_path(save(block_diseases: [ "dengue", 1 ]))).to eq("values.block_diseases")
  end

  it "chave a mais ou faltando → invalid_parameter; values que não é objeto → path values" do
    expect(refused_path(save(foo: 1))).to eq("values.foo")
    expect(refused_path(save_values(factory.except("liraa_half_household_fraction")))).to eq("values.liraa_half_household_fraction")
    expect(refused_path(save_values(factory.except("default_days")))).to eq("values.default_days")
    expect(refused_path(save_values([ factory ]))).to eq("values")
    expect(refused_path(save_values(nil))).to eq("values")
    expect(VectorParameterVersion.count).to eq(0)
  end

  it "desigualdades entre chaves: o path é a chave de baixo" do
    expect(refused_path(save(ubv_cycle_days_min: 6, ubv_cycle_days_max: 5))).to eq("values.ubv_cycle_days_min")
    expect(refused_path(save(ovitrap_collection_days_min: 11, ovitrap_collection_days_max: 10)))
      .to eq("values.ovitrap_collection_days_min")
    expect(refused_path(save(liraa_half_min: 8100, liraa_standard_min: 8100))).to eq("values.liraa_half_min")
    expect(refused_path(save(liraa_standard_min: 12_000, liraa_standard_max: 12_000))).to eq("values.liraa_standard_min")
    expect(refused_path(save(iip_bands: [ 4.0, 1.0 ]))).to eq("values.iip_bands")
    expect(refused_path(save(iip_bands: [ 2.0, 2.0 ]))).to eq("values.iip_bands")
    # a faixa da própria chave vem antes da desigualdade
    expect(refused_path(save(ubv_cycle_days_min: 6, ubv_cycle_days_max: 16))).to eq("values.ubv_cycle_days_max")
  end

  it "block_diseases: só códigos da lista de doenças, sem repetição" do
    expect(refused_path(save(block_diseases: %w[dengue gripe]))).to eq("values.block_diseases")
    expect(refused_path(save(block_diseases: %w[dengue dengue]))).to eq("values.block_diseases")
    expect(save(block_diseases: %w[dengue])).to be_ok
  end

  it "bordas aceitas: min = max, fração 1 vira 1.0, faixas nas pontas" do
    result = save(ubv_cycle_days_min: 5, ubv_cycle_days_max: 5, ubv_cycle_interval_days: 0, block_radius_rings: 0,
                  liraa_household_fraction: 1, liraa_half_household_fraction: 0.01, iip_bands: [ 0, 100 ],
                  liraa_half_min: 1, liraa_standard_min: 2, liraa_standard_max: 100_000)
    expect(result).to be_ok
    values = result.payload.fetch(:version).values
    expect(values).to include("liraa_household_fraction" => 1.0, "liraa_half_household_fraction" => 0.01, "iip_bands" => [ 0.0, 100.0 ])
    expect(values["liraa_household_fraction"]).to be_a(Float)
    expect(values.keys).to eq(factory.keys)
  end

  it "duas edições → versões 1 e 2 e um evento cada; o LIRAa sorteado antes guarda 0" do
    team = registry_team!
    agent = endemic_agent!(team: team)
    area = MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area
    block = city_block!(neighborhood: Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual"), number: "1")
    liraa_households!(block, 2, micro_area: area)
    survey = liraa_survey!([ { mode: "census", blocks: [ block ] } ])
    expect(VectorControl::Liraa::Draw.call(survey: survey, by: coordinator)).to be_ok
    expect(survey.reload.parameters_version).to eq(0)

    events = []
    allow(DomainEvents).to receive(:publish).and_wrap_original { |m, *args, **kw| events << [ args.first, kw ]; m.call(*args, **kw) }

    first = save(default_days: 45)
    second = save(default_days: 50, ovitrap_alert_eggs: 120)
    expect([ first, second ]).to all(be_ok)
    expect(VectorParameterVersion.order(:version).pluck(:version, :created_by_user_id)).to eq([ [ 1, coordinator.id ], [ 2, coordinator.id ] ])
    expect(VectorControl::Parameters.current).to have_attributes(version: 2)
    expect(VectorControl::Parameters.current.values).to include("default_days" => 50, "ovitrap_alert_eggs" => 120)
    expect(VectorControl::Parameters.at(1).values["default_days"]).to eq(45)
    expect(events).to eq([ [ "vector_parameters.changed", { version: 1, user_id: coordinator.id } ],
                           [ "vector_parameters.changed", { version: 2, user_id: coordinator.id } ] ])
    expect(survey.reload.parameters_version).to eq(0)
  end

  it "a validação roda depois do advisory lock, dentro da transação" do
    calls = []
    connection = VectorParameterVersion.connection
    allow(connection).to receive(:execute).and_wrap_original do |m, sql, *rest|
      calls << :lock if sql.to_s.include?("pg_advisory_xact_lock")
      m.call(sql, *rest)
    end
    allow(VectorControl::Parameters).to receive(:validate).and_wrap_original { |m, *args| calls << :validate; m.call(*args) }

    expect(save(default_days: 45)).to be_ok
    expect(refused_path(save(default_days: 1))).to eq("values.default_days")
    expect(calls).to eq(%i[lock validate lock validate])
    expect(VectorParameterVersion.pluck(:version)).to eq([ 1 ])
  end

  it "recusa não publica evento" do
    expect(DomainEvents).not_to receive(:publish)
    save(default_days: 1)
  end

  context "block_diseases contra a versão vigente (lista de doenças vazia)" do
    let!(:city) { vector_city! } # sem surveillance_city!: nenhuma lista em vigor

    it "PUT com block_diseases sem mudança passa; código novo fora da lista → path values.block_diseases" do
      expect(Surveillance::Diseases.all).to be_empty
      expect(save(default_days: 45)).to be_ok
      expect(refused_path(save(block_diseases: %w[dengue chikungunya zika febre_amarela]))).to eq("values.block_diseases")
      expect(save(block_diseases: %w[zika dengue])).to be_ok # tirar e reordenar não pede a lista
      expect(VectorParameterVersion.order(:version).pluck(:version)).to eq([ 1, 2 ])
    end

    it "código gravado que saiu da lista (inativo) continua aceito sem mudança" do
      VectorParameterVersion.create!(version: 1, values: factory.merge("block_diseases" => %w[dengue doenca_local_inativa]),
                                     created_by_user: coordinator)
      expect(Surveillance::Diseases.all.map(&:code)).not_to include("doenca_local_inativa")
      result = save(block_diseases: %w[dengue doenca_local_inativa], ovitrap_alert_eggs: 150)
      expect(result).to be_ok
      expect(result.payload.fetch(:version)).to have_attributes(version: 2)
      expect(refused_path(save(block_diseases: %w[dengue doenca_local_inativa outra]))).to eq("values.block_diseases")
    end
  end
end
