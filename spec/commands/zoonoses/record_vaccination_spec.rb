require "rails_helper"

# Módulo 35b, Task 7 (ADR 0054; contrato §1, §3, Q4, Q19, Q20): o registro da
# dose antirrábica nas três modalidades. Casa a casa com o gate de campo
# (lido fora), animal active do domicílio e campanha open; posto fixo com
# campanha open e animal opcional (sem animal, só a espécie: Q4); rotina sem
# campanha, com animal. Data entre o início da campanha (rotina: hoje − 30) e
# hoje (date_out_of_range, Q20). A segunda dose do animal na campanha é barrada
# pelo índice (a dose e a baixa voltam juntas). Depois da dose, a baixa de 1 un
# (Zoonoses::ApplyStock) e o lote do movimento na dose (nulo na falta).
RSpec.describe Zoonoses::RecordVaccination, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:vaccine) { zoonoses_product! }
  let(:campaign) { campaign!(stage: "open") }
  let(:location) { vector_location! }

  def campaign!(stage: "planned", starts_on: Time.zone.today - 10, **over)
    RabiesCampaign.create!({ name: "Campanha #{SecureRandom.hex(3)}", year: starts_on.year, starts_on: starts_on, ends_on: starts_on + 40,
                             goal_dogs: 100, goal_cats: 50, stage: stage }.merge(over))
  end

  def stock!(quantity: "10")
    vector_stock_location!(location)
    vector_lot!(location, product: vaccine, quantity: quantity)
  end

  def params(**over)
    { "modality" => "fixed_post", "campaign_id" => campaign.id, "vaccinated_on" => today.iso8601, "vector_product_id" => vaccine.id,
      "adverse_event" => false }.merge(over.transform_keys(&:to_s)).reject { |_, value| value == :omit }
  end

  def record(by: team, origin: "dashboard", zoonoses_field: true, **over)
    described_class.call(params: params(**over), by: by, origin: origin, zoonoses_field: zoonoses_field)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "posto sem animal com species dog → ok; sem species → path species; gato `other` → path animal_id" do
    stock!
    result = record(species: "dog")
    expect(result).to be_ok
    dose = result.payload.fetch(:vaccination)
    expect(dose).to have_attributes(modality: "fixed_post", animal_id: nil, species: "dog", campaign_id: campaign.id,
                                    vaccinated_on: today, household_id: nil, recorded_by_user_id: team.id, adverse_event: false)

    expect(refusal(record)).to eq([ :invalid_request, { path: "species" } ])
    expect(refusal(record(species: "other"))).to eq([ :invalid_request, { path: "species" } ])
    expect(refusal(record(animal_id: animal!(species: "other").id))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(record(animal_id: animal!(species: "cat").id, species: "dog"))).to eq([ :invalid_request, { path: "species" } ])
    cat = record(animal_id: animal!(species: "cat").id)
    expect(cat.payload.fetch(:vaccination)).to have_attributes(species: "cat")
    expect(RabiesVaccination.count).to eq(2)
  end

  it "casa a casa com gate de campo desligado → feature_disabled; ligado, pelo app no escopo → ok com o domicílio do animal" do
    household = registry_household!
    animal = animal!(household: household)
    expect(refusal(record(modality: "house", animal_id: animal.id, zoonoses_field: false))).to eq([ :feature_disabled, {} ])

    agent = registry_acs_of(household)
    result = record(by: agent, origin: "field", modality: "house", animal_id: animal.id, client_uuid: SecureRandom.uuid)
    expect(result).to be_ok
    expect(result.payload.fetch(:vaccination)).to have_attributes(modality: "house", household_id: household.id, health_unit_id: nil,
                                                                  recorded_by_user_id: agent.id)
  end

  it "casa a casa: agente fora do escopo → out_of_scope; animal sem domicílio → path animal_id; pelo app só house" do
    household = registry_household!
    outsider = endemic_agent!
    expect(refusal(record(by: outsider, origin: "field", modality: "house", animal_id: animal!(household: household).id)))
      .to eq([ :out_of_scope, {} ])
    expect(refusal(record(modality: "house", animal_id: animal!.id))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(record(modality: "house", species: "dog"))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(record(by: registry_acs_of(household), origin: "field", species: "dog"))).to eq([ :invalid_request, { path: "modality" } ])
    expect(refusal(record(by: outsider))).to eq([ :missing_role, {} ])
    expect(RabiesVaccination.count).to eq(0)
  end

  it "rotina com data de 31 dias atrás → date_out_of_range path vaccinated_on; de 30 → ok; amanhã → recusa" do
    animal = animal!
    routine = { modality: "routine", campaign_id: :omit, animal_id: animal.id }
    expect(refusal(record(**routine, vaccinated_on: (today - 31).iso8601))).to eq([ :date_out_of_range, { path: "vaccinated_on" } ])
    expect(refusal(record(**routine, vaccinated_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "vaccinated_on" } ])
    expect(record(**routine, vaccinated_on: (today - 30).iso8601)).to be_ok
    expect(refusal(record(**routine, campaign_id: campaign.id))).to eq([ :invalid_request, { path: "campaign_id" } ])
    expect(refusal(record(modality: "routine", campaign_id: :omit, species: "dog"))).to eq([ :invalid_request, { path: "animal_id" } ])
  end

  it "campanha: dose antes do início → date_out_of_range; no início → ok; data malformada → invalid_request" do
    expect(refusal(record(species: "dog", vaccinated_on: (campaign.starts_on - 1).iso8601)))
      .to eq([ :date_out_of_range, { path: "vaccinated_on" } ])
    expect(record(species: "dog", vaccinated_on: campaign.starts_on.iso8601)).to be_ok
    expect(refusal(record(species: "dog", vaccinated_on: "23/11/2026"))).to eq([ :invalid_request, { path: "vaccinated_on" } ])
  end

  it "sem saldo → dose gravada com stock_lot_id nil e falta; com saldo → o lote do movimento na dose" do
    without = record(species: "dog").payload.fetch(:vaccination)
    expect(without.reload.stock_lot_id).to be_nil
    expect(VectorStockShortfall.sole).to have_attributes(source: "vaccination", rabies_vaccination_id: without.id, cause: "no_location",
                                                         occurred_on: today)

    lot = stock!
    with = record(species: "dog").payload.fetch(:vaccination)
    expect(with.reload.stock_lot_id).to eq(lot.id)
    expect(StockMovement.where(rabies_vaccination_id: with.id).sole).to have_attributes(kind: "animal_vaccination", stock_lot_id: lot.id,
                                                                                         quantity: BigDecimal("-1"))
  end

  it "falta de uma rotina retroativa leva o dia da dose em occurred_on, não hoje" do
    vector_stock_location!(location)
    dose = record(modality: "routine", campaign_id: :omit, animal_id: animal!.id, vaccinated_on: (today - 12).iso8601)
             .payload.fetch(:vaccination)
    expect(VectorStockShortfall.find_by!(rabies_vaccination_id: dose.id)).to have_attributes(cause: "no_lot", occurred_on: today - 12)
  end

  it "campanha closed → campaign_not_open; planned → campaign_not_open; inexistente → invalid_request" do
    closed = campaign!(stage: "closed")
    expect(refusal(record(campaign_id: closed.id, species: "dog"))).to eq([ :campaign_not_open, { path: "campaign_id" } ])
    expect(refusal(record(campaign_id: campaign!.id, species: "dog"))).to eq([ :campaign_not_open, { path: "campaign_id" } ])
    expect(refusal(record(campaign_id: SecureRandom.uuid, species: "dog"))).to eq([ :invalid_request, { path: "campaign_id" } ])
    expect(refusal(record(modality: "fixed_post", campaign_id: :omit, species: "dog"))).to eq([ :invalid_request, { path: "campaign_id" } ])
  end

  it "segunda dose do animal na campanha → already_vaccinated_in_campaign, sem segundo movimento; anulada a primeira, passa" do
    stock!
    animal = animal!
    first = record(animal_id: animal.id).payload.fetch(:vaccination)
    expect(refusal(record(animal_id: animal.id))).to eq([ :already_vaccinated_in_campaign, {} ])
    expect(StockMovement.where(kind: "animal_vaccination").count).to eq(1)
    expect(DomainEvent.where(name: "rabies_vaccination.recorded").count).to eq(1)

    first.update!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado")
    expect(record(animal_id: animal.id)).to be_ok
  end

  it "animal missing, deceased ou transferred → animal_not_active; inexistente → path animal_id" do
    %w[missing deceased transferred].each do |status|
      expect(refusal(record(animal_id: animal!(status: status, status_on: today).id))).to eq([ :animal_not_active, {} ])
    end
    expect(refusal(record(animal_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "animal_id" } ])
  end

  it "produto inativo, de coleira ou vetorial → path vector_product_id" do
    [ zoonoses_product!(active: false), zoonoses_product!(use: "collar"), vector_product! ].each do |product|
      expect(refusal(record(species: "dog", vector_product_id: product.id))).to eq([ :invalid_request, { path: "vector_product_id" } ])
    end
  end

  it "evento adverso: nota 10–500 opcional, cifrada; nota sem evento, curta ou longa → path adverse_note (recusada, nunca cortada)" do
    note = "Edema local no ponto da aplicação"
    dose = record(species: "dog", adverse_event: true, adverse_note: "  #{note}  ").payload.fetch(:vaccination)
    expect(dose.reload).to have_attributes(adverse_event: true, adverse_note: note)
    expect(record(species: "dog", adverse_event: true)).to be_ok
    expect(refusal(record(species: "dog", adverse_note: note))).to eq([ :invalid_request, { path: "adverse_note" } ])
    expect(refusal(record(species: "dog", adverse_event: true, adverse_note: "curta"))).to eq([ :invalid_request, { path: "adverse_note" } ])
    expect(refusal(record(species: "dog", adverse_event: true, adverse_note: "a" * 501))).to eq([ :invalid_request, { path: "adverse_note" } ])
    expect(refusal(record(species: "dog", adverse_event: "sim"))).to eq([ :invalid_request, { path: "adverse_event" } ])
    expect(refusal(record(species: "dog", adverse_event: :omit))).to eq([ :invalid_request, { path: "adverse_event" } ])
  end

  it "chave desconhecida, client_uuid pelo dashboard e unidade inexistente → invalid_request com o path; unidade ativa → gravada" do
    expect(refusal(record(species: "dog", tutor_name: "Fulano"))).to eq([ :invalid_request, { path: "tutor_name" } ])
    expect(refusal(record(species: "dog", client_uuid: SecureRandom.uuid))).to eq([ :invalid_request, { path: "client_uuid" } ])
    expect(refusal(record(species: "dog", health_unit_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "health_unit_id" } ])
    unit = uvz_unit!
    expect(record(species: "dog", health_unit_id: unit.id).payload.fetch(:vaccination).health_unit_id).to eq(unit.id)
  end

  it "rabies_vaccination.recorded só com o id da dose" do
    tutor = tutor!
    animal = animal!(tutor: tutor)
    dose = record(animal_id: animal.id).payload.fetch(:vaccination)
    expect(DomainEvent.where(name: "rabies_vaccination.recorded").sole.payload).to eq("rabies_vaccination_id" => dose.id)
  end
end

# Review Focus 1 (plano; contrato §3, Q19): duas doses do MESMO animal na MESMA
# campanha ao mesmo tempo (o posto e o app, ou dois aparelhos). A primeira grava
# a dose e a baixa e fica parada antes do commit; a segunda espera no índice
# único parcial (animal, campanha) e, solta a primeira, volta
# already_vaccinated_in_campaign: nenhuma dose nem movimento dela. Threads reais
# contra TEST_CITY_A, sem fixture transacional (o padrão do
# spec/commands/vector_control/apply_stock_spec.rb): pop(timeout:), e o after
# solta as threads e apaga tudo o que commitou.
RSpec.describe Zoonoses::RecordVaccination, "× duas doses do mesmo animal na campanha", type: :model do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def snapshot
    connection = ApplicationRecord.connection
    connection.tables.select { |table| connection.column_exists?(table, :id) }
              .to_h { |table| [ table, connection.select_values("SELECT id::text FROM #{connection.quote_table_name(table)}").to_set ] }
  end

  before do
    @before = in_city { snapshot }
    @stock_location_before = in_city { VectorControlSetting.find_by(id: 1)&.stock_location_id }
    @ids = in_city do
      product = zoonoses_product!
      location = vector_location!
      vector_stock_location!(location)
      lot = vector_lot!(location, product: product, quantity: "5")
      campaign = RabiesCampaign.create!(name: "Campanha corrida #{SecureRandom.hex(3)}", year: Time.zone.today.year,
                                        starts_on: Time.zone.today - 5, ends_on: Time.zone.today + 30, goal_dogs: 10, goal_cats: 5,
                                        stage: "planned")
      { users: [ zoonoses_team!.id, zoonoses_team!.id ], animal: animal!.id, product: product.id, location: location.id, lot: lot.id,
        campaign: campaign.id, unit: uvz_unit!.id }
    end
    # Aberta só aqui (a única open da cidade; o after a apaga).
    in_city { RabiesCampaign.where(stage: "open").none? or raise "outra campanha open em TEST_CITY_A" }
    in_city { RabiesCampaign.find(@ids[:campaign]).update!(stage: "open") }
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        snapshot.each do |table, ids|
          fresh = ids - @before.fetch(table, Set.new)
          next if fresh.empty?

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id::text IN (#{fresh.map { connection.quote(_1) }.join(',')})")
        end
        VectorControlSetting.where(id: 1).update_all(stock_location_id: @stock_location_before)
      end
    end
  end

  def dose_now(go, index)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      described_class.call(params: { "modality" => "fixed_post", "campaign_id" => @ids[:campaign], "animal_id" => @ids[:animal],
                                     "vaccinated_on" => Time.zone.today.iso8601, "vector_product_id" => @ids[:product],
                                     "adverse_event" => false, "health_unit_id" => @ids[:unit] },
                           by: User.find(@ids[:users][index]), origin: "dashboard", zoonoses_field: false)
    end
  rescue StandardError => e
    e
  end

  it "uma gravada, a outra already_vaccinated_in_campaign, um movimento só" do
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "rabies_vaccination.recorded"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    go_first = Queue.new
    first_result = Queue.new
    threads << (holder = Thread.new { first_result << dose_now(go_first, 0) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << dose_now(go_second, 1) })
    go_second << true
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera no índice único (animal, campanha)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    first, second = first_result.pop(timeout: 1), second_result.pop(timeout: 1)
    expect([ first, second ]).to all(be_a(Result)) # nenhuma exceção (deadlock, RecordNotUnique solto)
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :already_vaccinated_in_campaign, {} ])
    in_city do
      dose = RabiesVaccination.where(animal_id: @ids[:animal]).sole
      expect(dose).to have_attributes(id: first.payload[:vaccination].id, recorded_by_user_id: @ids[:users][0], stock_lot_id: @ids[:lot])
      expect(StockMovement.where(kind: "animal_vaccination", vector_product_id: @ids[:product]).count).to eq(1)
      expect(VectorStockShortfall.where(vector_product_id: @ids[:product])).to be_empty
      expect(Pharmacy::Ledger.balance(location_id: @ids[:location], lot_id: @ids[:lot])).to eq(BigDecimal("4"))
      expect(DomainEvent.where(name: "rabies_vaccination.recorded").where("payload->>'rabies_vaccination_id' = ?", dose.id).count).to eq(1)
    end
  end
end
