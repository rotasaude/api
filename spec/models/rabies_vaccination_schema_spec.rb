require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900002_add_vector_inspections.rb").to_s
require Rails.root.join("db/city_migrate/20261123900002_add_rabies_vaccinations.rb").to_s

# Módulo 35b (ADR 0054; contrato §1, §3 e Q17; plano, Task 3): o banco da
# vacinação antirrábica, da coleira e do estoque. Uma campanha aberta por vez,
# só andando para a frente; a dose imutável fora da anulação (uma vez); uma
# dose ativa por animal e campanha; a coleira ativa única por animal; os três
# tipos de movimento novos com a dose ou a coleira por documento; a falta de
# estoque com origem (Q17), as do 35a migradas como `inspection`.
RSpec.describe "Esquema da vacinação do módulo 35b", type: :model do
  before { zoonoses_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  # Avaliados antes de qualquer savepoint recusado (que desfaria as linhas).
  let!(:author) { zoonoses_team! }
  let!(:unit) { uvz_unit! }
  let!(:vaccine) { vector_product!(unit: "un", charge_size: "1.00", uses: %w[rabies_vaccine]) }
  let!(:collar_product) { vector_product!(unit: "un", charge_size: "1.00", uses: %w[collar]) }

  def campaign!(stage: "planned", **over)
    RabiesCampaign.create!({ name: "Campanha #{SecureRandom.hex(3)}", year: Time.zone.today.year, starts_on: Time.zone.today - 10,
                             ends_on: Time.zone.today + 20, goal_dogs: 100, goal_cats: 50, stage: stage }.merge(over))
  end

  def vaccination!(modality: "fixed_post", campaign: :auto, animal: :auto, **over)
    campaign = (modality == "routine" ? nil : campaign!) if campaign == :auto
    animal = animal!(species: "dog") if animal == :auto
    RabiesVaccination.create!({ modality: modality, campaign: campaign, animal: animal, species: "dog", vaccinated_on: Time.zone.today,
                                health_unit: (unit unless modality == "house"), vector_product: vaccine, recorded_by_user: author,
                                adverse_event: false }.merge(over))
  end

  def collar!(animal: animal!, **over)
    Collar.create!({ animal: animal, vector_product: collar_product, placed_on: Time.zone.today, due_on: Time.zone.today + 180 }.merge(over))
  end

  def raw_update(record, **attrs) = record.class.where(id: record.id).update_all(attrs)

  def location!
    StockLocation.create!(kind: "vector_control", name: "Insumos #{SecureRandom.hex(3)}", health_unit: uvz_unit!, updated_by_user: author)
  end

  def lot!(product = vaccine)
    StockLot.create!(item_kind: "vector_control", vector_product_id: product.id, lot_number: "V#{SecureRandom.hex(3).upcase}",
                     expires_on: Time.zone.today + 180, dispensing_unit: product.unit, created_by_user: author)
  end

  def opening!(location, lot, quantity = 10)
    entry = StockEntry.create!(stock_location: location, kind: "opening", recorded_by_user: author)
    Pharmacy::Ledger.record!(location: location, lot: lot, kind: "opening", quantity: quantity, by: author, document: entry)
  end

  def movement_attrs(location, lot, **over)
    { stock_location: location, stock_lot: lot, vector_product_id: lot.vector_product_id, kind: "animal_vaccination", quantity: -1,
      recorded_by_user: author, recorded_at: Time.current }.merge(over)
  end

  it "a migração espelha Pharmacy::Catalog e Zoonoses::Catalog; irreversível" do
    catalog = Pharmacy::Catalog
    expect([ AddRabiesVaccinations::MOVEMENT_KINDS, AddRabiesVaccinations::POSITIVE_KINDS, AddRabiesVaccinations::NEGATIVE_KINDS ])
      .to eq([ catalog::MOVEMENT_KINDS, catalog::POSITIVE_KINDS, catalog::NEGATIVE_KINDS ])
    expect(AddRabiesVaccinations::MOVEMENT_KINDS).to include("animal_vaccination", "animal_vaccination_reversal", "collar_placement")
    expect(AddRabiesVaccinations::POSITIVE_KINDS).to include("animal_vaccination_reversal")
    expect(AddRabiesVaccinations::NEGATIVE_KINDS).to include("animal_vaccination", "collar_placement")
    expect([ AddRabiesVaccinations::CAMPAIGN_STAGES, AddRabiesVaccinations::MODALITIES, AddRabiesVaccinations::REMOVAL_REASONS,
             AddRabiesVaccinations::VACCINE_SPECIES, AddRabiesVaccinations::SHORTFALL_SOURCES ])
      .to eq([ Zoonoses::Catalog::CAMPAIGN_STAGES, Zoonoses::Catalog::MODALITIES, Zoonoses::Catalog::REMOVAL_REASONS,
               Zoonoses::Catalog::VACCINE_SPECIES, VectorStockShortfall::SOURCES ])
    expect { AddRabiesVaccinations.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(Pharmacy::Ledger::DOCUMENTS).to include(RabiesVaccination => :rabies_vaccination, Collar => :collar)
  end

  describe "campanha" do
    it "duas campanhas open → único; planned e closed à vontade" do
      campaign!(stage: "open")
      expect { campaign!(stage: "open") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_rabies_campaigns_open/)
      expect { 2.times { campaign!(stage: "planned") } }.not_to raise_error
    end

    it "nome 1–80, metas ≥ 0, início ≤ fim, etapa no domínio, versão ≥ 1" do
      refused(/ck_rabies_campaigns_name/) { campaign!(name: "") }
      refused(/ck_rabies_campaigns_name/) { campaign!(name: "a" * 81) }
      refused(/ck_rabies_campaigns_goals/) { campaign!(goal_dogs: -1) }
      refused(/ck_rabies_campaigns_goals/) { campaign!(goal_cats: -1) }
      refused(/ck_rabies_campaigns_period/) { campaign!(starts_on: Time.zone.today + 5, ends_on: Time.zone.today) }
      refused(/ck_rabies_campaigns_stage/) { campaign!(stage: "paused") }
      refused(/ck_rabies_campaigns_version/) { campaign!(version: 0) }
      accepted { campaign!(name: "a" * 80, goal_dogs: 0, goal_cats: 0, starts_on: Time.zone.today, ends_on: Time.zone.today) }
    end

    it "planned → open → closed; campanha planned → closed recusado; closed → open recusado; nunca volta" do
      campaign = campaign!
      accepted { campaign.update_columns(stage: "open") }
      accepted { campaign.update_columns(stage: "closed") }
      refused(/rabies_campaigns: the stage only goes planned → open → closed/) { campaign.update_columns(stage: "open") }
      refused(/rabies_campaigns: the stage only goes planned → open → closed/) { campaign.update_columns(stage: "planned") }

      opened = campaign!(stage: "open")
      refused(/rabies_campaigns: the stage only goes planned → open → closed/) { opened.update_columns(stage: "planned") }
      skipped = campaign!
      refused(/rabies_campaigns: the stage only goes planned → open → closed/) { skipped.update_columns(stage: "closed") }
    end

    it "metas e período seguem editáveis; DELETE e TRUNCATE recusados" do
      campaign = campaign!
      accepted { campaign.update_columns(goal_dogs: 200, name: "Nova") }
      refused(/rabies_campaigns: DELETE refused/) { campaign.delete }
      refused(/rabies_campaigns is append-only: TRUNCATE refused/) { RabiesCampaign.connection.execute("TRUNCATE rabies_campaigns CASCADE") }
    end
  end

  describe "vacinação" do
    it "segunda dose ativa do animal na campanha → único; anulada a primeira, passa" do
      campaign = campaign!(stage: "open")
      animal = animal!
      first = vaccination!(campaign: campaign, animal: animal)
      expect { vaccination!(campaign: campaign, animal: animal) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_rabies_vaccinations_animal_campaign/)
      first.update!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado")
      expect { vaccination!(campaign: campaign, animal: animal) }.not_to raise_error
      expect { vaccination!(campaign: campaign, animal: animal) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "mesmo animal em outra campanha, ou na rotina, passa" do
      animal = animal!
      vaccination!(animal: animal)
      expect { vaccination!(animal: animal) }.not_to raise_error # outra campanha (a automática é nova)
      expect { 2.times { vaccination!(modality: "routine", animal: animal) } }.not_to raise_error
    end

    it "rotina com campanha → CHECK; campanha sem rotina → CHECK; casa a casa sem domicílio → CHECK" do
      refused(/ck_rabies_vaccinations_campaign/) { vaccination!(modality: "routine", campaign: campaign!(stage: "open")) }
      refused(/ck_rabies_vaccinations_campaign/) { vaccination!(modality: "fixed_post", campaign: nil) }
      refused(/ck_rabies_vaccinations_household/) { vaccination!(modality: "house", household_id: nil) }
      refused(/ck_rabies_vaccinations_household/) { vaccination!(modality: "fixed_post", household: registry_household!) }
      refused(/ck_rabies_vaccinations_house_unit/) do
        vaccination!(modality: "house", household: registry_household!, health_unit: unit)
      end
      accepted { vaccination!(modality: "house", household: registry_household!) }
    end

    it "dose de posto sem animal passa; rotina sem animal e casa a casa sem animal → CHECK" do
      accepted { vaccination!(modality: "fixed_post", animal: nil) }
      refused(/ck_rabies_vaccinations_animal/) { vaccination!(modality: "routine", animal: nil) }
      refused(/ck_rabies_vaccinations_animal/) { vaccination!(modality: "house", animal: nil, household: registry_household!) }
    end

    it "domínios: espécie só cão e gato, modalidade, anulação em par" do
      refused(/ck_rabies_vaccinations_species/) { vaccination!(species: "other") }
      refused(/ck_rabies_vaccinations_modality/) { vaccination!(modality: "mobile") }
      refused(/ck_rabies_vaccinations_cancellation/) { vaccination!(cancelled_at: Time.current) }
      refused(/ck_rabies_vaccinations_cancellation/) { vaccination!(cancel_reason: "Dose lançada no animal errado") }
      accepted { vaccination!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado") }
    end

    it "client_uuid repetido → único; dois nulos passam" do
      uuid = SecureRandom.uuid
      vaccination!(client_uuid: uuid)
      expect { vaccination!(client_uuid: uuid) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_rabies_vaccinations_client_uuid/)
      expect { 2.times { vaccination!(client_uuid: nil) } }.not_to raise_error
    end

    it "anular duas vezes → trigger; a anulação só de NULL a valor" do
      dose = vaccination!
      accepted { dose.update!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado") }
      refused(/rabies_vaccinations: a dose is cancelled once/) do
        raw_update(dose, cancelled_at: Time.current + 1.minute, cancel_reason: "Outro motivo qualquer")
      end
      refused(/rabies_vaccinations: a dose is cancelled once/) { raw_update(dose, cancelled_at: nil, cancel_reason: nil) }
    end

    it "mudar vaccinated_on, animal, produto, lote ou o evento adverso → trigger" do
      dose = vaccination!
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) { raw_update(dose, vaccinated_on: Time.zone.today - 1) }
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) { raw_update(dose, animal_id: animal!.id) }
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) { raw_update(dose, adverse_event: true) }
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) { raw_update(dose, stock_lot_id: lot!.id) }
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) do
        raw_update(dose, cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado", vaccinated_on: Time.zone.today - 1)
      end
    end

    it "a re-cifra regrava só as colunas cifradas; sem a marca, a mesma escrita é recusada" do
      dose = vaccination!(adverse_event: true, adverse_note: "Edema local no ponto da aplicação")
      connection = RabiesVaccination.connection
      rewrite = lambda do |value|
        connection.execute(RabiesVaccination.sanitize_sql([ "UPDATE rabies_vaccinations SET adverse_note = ? WHERE id = ?", value, dose.id ]))
      end
      refused(/rabies_vaccinations: only cancelled_at and cancel_reason change/) { rewrite.call("texto-recifrado") }
      accepted { CityEncryption.allowing_reencryption { rewrite.call("texto-recifrado") } }
      expect(connection.select_value("SELECT current_setting('rota.reencrypting', true)")).to eq("off")
      expect(RabiesVaccination.connection.select_value("SELECT adverse_note FROM rabies_vaccinations WHERE id = '#{dose.id}'")).to eq("texto-recifrado")
    end

    it "nota adversa e motivo da anulação cifrados; DELETE e TRUNCATE recusados; inspect sem dado" do
      dose = vaccination!(adverse_event: true, adverse_note: "Edema local no ponto da aplicação")
      dose.update!(cancelled_at: Time.current, cancel_reason: "Dose lançada no animal errado")
      raw = RabiesVaccination.connection.select_rows("SELECT adverse_note, cancel_reason FROM rabies_vaccinations WHERE id = '#{dose.id}'").first
      expect(raw.join).not_to include("Edema", "errado")
      expect(RabiesVaccination.find(dose.id)).to have_attributes(adverse_note: "Edema local no ponto da aplicação")
      [ dose.inspect, dose.to_s, dose.as_json.to_s ].each do |text|
        expect(text).not_to include("Edema")
        expect(text).not_to include("errado")
        expect(text).to include(dose.id)
      end
      refused(/rabies_vaccinations: DELETE refused/) { dose.delete }
      refused(/rabies_vaccinations is append-only: TRUNCATE refused/) { RabiesVaccination.connection.execute("TRUNCATE rabies_vaccinations CASCADE") }
    end
  end

  describe "coleira" do
    it "duas coleiras ativas → único; retirada a primeira, passa" do
      animal = animal!
      first = collar!(animal: animal)
      expect { collar!(animal: animal) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_collars_active/)
      accepted { first.update_columns(removed_on: Time.zone.today, removal_reason: "replaced") }
      expect { collar!(animal: animal) }.not_to raise_error
      expect { collar! }.not_to raise_error
    end

    it "vencimento depois da colocação; retirada em par com o motivo no domínio" do
      refused(/ck_collars_due/) { collar!(due_on: Time.zone.today) }
      refused(/ck_collars_removal/) { collar!(removed_on: Time.zone.today) }
      refused(/ck_collars_removal/) { collar!(removal_reason: "lost") }
      refused(/ck_collars_removal_reason/) { collar!(removed_on: Time.zone.today, removal_reason: "stolen") }
      accepted { collar!(removed_on: Time.zone.today, removal_reason: "death") }
    end

    it "client_uuid repetido → único" do
      uuid = SecureRandom.uuid
      collar!(client_uuid: uuid)
      expect { collar!(client_uuid: uuid) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_collars_client_uuid/)
    end

    it "só a retirada muda, uma vez; DELETE e TRUNCATE recusados" do
      collar = collar!
      refused(/collars: only removed_on and removal_reason change/) { raw_update(collar, due_on: Time.zone.today + 365) }
      refused(/collars: only removed_on and removal_reason change/) { raw_update(collar, placed_on: Time.zone.today - 1) }
      accepted { collar.update_columns(removed_on: Time.zone.today, removal_reason: "lost") }
      refused(/collars: a collar is removed once/) { raw_update(collar, removed_on: Time.zone.today + 1, removal_reason: "other") }
      refused(/collars: a collar is removed once/) { raw_update(collar, removed_on: nil, removal_reason: nil) }
      refused(/collars: DELETE refused/) { collar.delete }
      refused(/collars is append-only: TRUNCATE refused/) { Collar.connection.execute("TRUNCATE collars CASCADE") }
    end
  end

  describe "movimento de estoque" do
    it "movimento animal_vaccination positivo → CHECK sign; estorno negativo → CHECK sign; sem documento → CHECK document" do
      location = location!
      lot = lot!
      dose = vaccination!
      refused(/ck_stock_movements_sign/) { StockMovement.create!(movement_attrs(location, lot, rabies_vaccination: dose, quantity: 1)) }
      refused(/ck_stock_movements_sign/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "animal_vaccination_reversal", rabies_vaccination: dose, quantity: -1))
      end
      refused(/ck_stock_movements_sign/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "collar_placement", collar: collar!, quantity: 1))
      end
      refused(/ck_stock_movements_document/) { StockMovement.create!(movement_attrs(location, lot)) }
      refused(/ck_stock_movements_document/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "collar_placement", rabies_vaccination: dose))
      end
      refused(/ck_stock_movements_document/) { StockMovement.create!(movement_attrs(location, lot, collar: collar!)) }
      refused(/ck_stock_movements_document/) do
        StockMovement.create!(movement_attrs(location, lot, rabies_vaccination: dose, collar: collar!))
      end
      refused(/ck_stock_movements_document/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "loss", reason: "Embalagem rompida no transporte", rabies_vaccination: dose))
      end
    end

    it "baixa, estorno e coleira com o documento certo passam" do
      location = location!
      lot = lot!
      opening!(location, lot)
      dose = vaccination!(stock_lot: lot)
      collar = collar!
      expect do
        StockMovement.create!(movement_attrs(location, lot, rabies_vaccination: dose))
        StockMovement.create!(movement_attrs(location, lot, kind: "animal_vaccination_reversal", quantity: 1, rabies_vaccination: dose))
        StockMovement.create!(movement_attrs(location, lot, kind: "collar_placement", collar: collar))
      end.not_to raise_error
      expect(Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)).to eq(9)
      expect(dose.movements.count).to eq(2)
      expect(collar.movements.count).to eq(1)
    end
  end

  describe "falta de estoque" do
    def shortfall!(source: "vaccination", cause: "no_lot", validate: false, **over)
      refs = case source
             when "vaccination" then { rabies_vaccination: vaccination! }
             when "collar" then { collar: collar! }
             else { vector_inspection_measure: nil }
             end
      record = VectorStockShortfall.new({ source: source, occurred_on: Time.zone.today, vector_product: vaccine, quantity: 1, cause: cause,
                                          stock_location: (location! unless cause == "no_location") }.merge(refs).merge(over))
      record.save!(validate: validate) # sem as validações do modelo: o banco é quem recusa
      record
    end

    it "falta de vacinação e de coleira com a referência certa passa" do
      accepted { shortfall!(source: "vaccination") }
      accepted { shortfall!(source: "collar") }
    end

    it "falta source vaccination com medida → CHECK; sem a dose → CHECK; coleira com a dose → CHECK" do
      measure = vector_shortfall_measure!
      refused(/ck_vector_stock_shortfalls_reference/) { shortfall!(source: "vaccination", vector_inspection_measure: measure) }
      refused(/ck_vector_stock_shortfalls_reference/) { shortfall!(source: "vaccination", rabies_vaccination: nil) }
      refused(/ck_vector_stock_shortfalls_reference/) { shortfall!(source: "collar", rabies_vaccination: vaccination!) }
      refused(/ck_vector_stock_shortfalls_reference/) { shortfall!(source: "collar", collar: nil) }
      refused(/ck_vector_stock_shortfalls_reference/) { shortfall!(source: "inspection", vector_inspection_measure: nil) }
      refused(/ck_vector_stock_shortfalls_reference/) do
        shortfall!(source: "inspection", vector_inspection_measure: measure, rabies_vaccination: vaccination!)
      end
      accepted { shortfall!(source: "inspection", vector_inspection_measure: measure) }
    end

    it "origem no domínio e obrigatória; occurred_on obrigatório" do
      refused(/ck_vector_stock_shortfalls_(source|reference)/) { shortfall!(source: "manual") }
      refused(/null value in column "source"/) { shortfall!(source: nil) }
      refused(/null value in column "occurred_on"/) { shortfall!(occurred_on: nil) }
    end

    it "uma falta por dose e por coleira" do
      dose = vaccination!
      collar = collar!
      shortfall!(source: "vaccination", rabies_vaccination: dose)
      shortfall!(source: "collar", collar: collar)
      expect { shortfall!(source: "vaccination", rabies_vaccination: dose) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_stock_shortfalls_rabies_vaccination/)
      expect { shortfall!(source: "collar", collar: collar) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_stock_shortfalls_collar/)
    end

    it "a falta de inspeção do 35a nasce com source inspection e occurred_on do dia da visita" do
      measure = vector_shortfall_measure!
      row = VectorStockShortfall.create!(vector_inspection_measure: measure, vector_product: vaccine, quantity: 1, cause: "no_location")
      expect(row).to have_attributes(source: "inspection",
                                     occurred_on: measure.vector_inspection.home_visit.occurred_at.in_time_zone.to_date)
    end

    it "as faltas do 35a migram com source inspection e o dia da visita (a migração preenche antes do NOT NULL)" do
      measures = [ vector_shortfall_measure!, vector_shortfall_measure!(occurred_at: 3.days.ago.change(hour: 23, min: 30)) ]
      rows = measures.map do |measure|
        VectorStockShortfall.create!(vector_inspection_measure: measure, vector_product: vaccine, quantity: 1, cause: "no_location")
      end
      reconciled = rows.last
      reconciled.update!(reconciled_at: Time.current, reconciled_by_user: author, reconciliation_note: "Conciliada na contagem do mês")

      connection = VectorStockShortfall.connection
      connection.execute("ALTER TABLE vector_stock_shortfalls ALTER COLUMN source DROP NOT NULL")
      connection.execute("ALTER TABLE vector_stock_shortfalls ALTER COLUMN occurred_on DROP NOT NULL")
      connection.execute("ALTER TABLE vector_stock_shortfalls DISABLE TRIGGER vector_stock_shortfalls_guard")
      connection.execute("UPDATE vector_stock_shortfalls SET source = NULL, occurred_on = NULL")
      connection.execute("ALTER TABLE vector_stock_shortfalls ENABLE TRIGGER vector_stock_shortfalls_guard")

      AddRabiesVaccinations.new.backfill_shortfalls(connection)

      rows.each(&:reload)
      expect(rows.map(&:source)).to eq(%w[inspection inspection])
      expect(rows.map(&:occurred_on)).to eq(measures.map { |measure| measure.vector_inspection.home_visit.occurred_at.in_time_zone.to_date })
      expect(rows.last.occurred_on).to eq(3.days.ago.in_time_zone.to_date)
      expect(rows.last.reconciled_at).to be_present
      expect(connection.select_value("SELECT count(*) FROM pg_trigger WHERE tgname = 'vector_stock_shortfalls_guard' AND tgenabled = 'O'")).to eq(1)
    end
  end

  # A medida de uma inspeção do 35a (a falta de inspeção).
  def vector_shortfall_measure!(occurred_at: nil)
    household = registry_household!
    visit = home_visit!(household: household, occurred_at: occurred_at)
    inspection = VectorInspection.create!(home_visit: visit, household_id: household.id, activity: "li", work_type: "routine",
                                          situation: "worked", educational_action: true)
    product = vector_product!(unit: "g", charge_size: "2.00", uses: %w[focal])
    VectorInspectionMeasure.create!(vector_inspection_id: inspection.id, method: "focal", vector_product_id: product.id,
                                    charges: BigDecimal("2"), quantity: BigDecimal("4.00"))
  end
end
