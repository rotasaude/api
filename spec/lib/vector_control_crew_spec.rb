require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/territory_registry_crew").to_s
require Rails.root.join("lib/home_visit_crew").to_s
require Rails.root.join("lib/vector_control_crew").to_s

# Semente de dev do módulo 35a (contrato §18) no banco de teste (nunca no de
# dev), com o elenco na ordem do db/seeds.rb até o HomeVisitCrew (de quem vêm
# a UBS, a eSF, a enfermeira, as microáreas 01 e 02, os domicílios e as
# pessoas, e a visita domiciliar ligada). A lista nacional de doenças e a
# vigilante (vigilancia@) fazem as vezes do SurveillanceCrew: a notificação de
# dengue da Daniela sai pelo Surveillance::CreateNotification. Idempotente.
RSpec.describe VectorControlCrew, type: :model do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:today) { Time.zone.today }
  let(:unit) { HealthUnit.find_by!(name: CareLinesCrew::UNIT) }
  let(:team) { HealthTeam.find_by!(health_unit: unit, name: CareLinesCrew::TEAM_NAME) }
  let(:areas) { %w[01 02].map { |code| MicroArea.find_by!(team: team, code: code) } }
  let(:ace) { User.find_by!(email_address: "ace@curitiba.demo") }
  let(:coordinator) { User.find_by!(email_address: "endemias@curitiba.demo") }
  let(:lab) { User.find_by!(email_address: "entomologia@curitiba.demo") }
  let(:keeper) { User.find_by!(email_address: "almoxarifado-uvz@curitiba.demo") }
  let(:nurse) { User.find_by!(email_address: "enfermeira@curitiba.demo") }

  # A cadeia anterior do db/seeds.rb, uma vez por arquivo (api#159).
  seed_once do
    city = clinical_city!(record_mode: "off", enabled: false)
    create_default_protocol!
    admin = staff_with("admin@curitiba.demo", "municipal_admin")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    Territory::Seed.call(path: Territory::Seed.path_for("curitiba"))
    TriageCatalogCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ScreeningCrew.seed_platform!
    ScreeningCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ClinicalRecordCrew.seed_platform!
    ClinicalRecordCrew.seed_current_city(slug: "curitiba", ddd: "41")
    CareLinesCrew.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    (CityProfile.current || CityProfile.new).update!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    unit = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
    unit.update!(cnes: "2384299") if unit.cnes.blank?
    ledi_ready!(City.find(city.id), pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    TerritoryRegistryCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    HomeVisitCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    # Como o SurveillanceCrew deixa em dev: a lista nacional e a vigilante.
    Surveillance::DiseaseList::Load.call
    staff_with("vigilancia@curitiba.demo", "surveillance")
  end

  before do
    stub_pec!
    allow(Ledi::DeliverJob).to receive(:perform_later)
    CityCatalog.reset_cache!
    Current.city = city
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  def patient(key) = TerritoryRegistryCrew.patient_of("curitiba", key)

  def household_at(number) = Household.all.detect { |household| household.latest_version.address["number"] == number }

  it "semear duas vezes não duplica quarteirão, ovitrampa, levantamento nem bloqueio" do
    first = seed
    tables = [ User, Membership, StockLocationStaff, Professional, ProfessionalLink, HealthTeamMember, MicroAreaFieldAssignment, HealthUnit, StockLocation,
               VectorControlSetting, VectorProduct, StockLot, StockMovement, StockEntry, CityBlock, CityBlockNeighbor, Household,
               HouseholdVersion, HouseholdVectorProfile, VectorCadence, VectorCycle, HomeVisitDay, HomeVisit, VectorInspection,
               VectorSample, VectorStockShortfall, Ovitrap, OvitrapReading, VectorTask, LiraaSurvey, LiraaStratum, LiraaDrawItem,
               DiseaseNotification, TransmissionBlock, TransmissionBlockArea, TransmissionBlockCase, TransmissionBlockCycle,
               ProcessedEvent, DomainEvent, CityFeature, LediOutboxEntry, Patient ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
  end

  it "o ACE é field_agent nas duas microáreas e o roteiro 1–9 do §18 tem dado " \
     "(vencido por risco, ovitrampa acima do alerta, item pending, bloqueio active, falta-estoque conciliável)" do
    result = seed
    blocks = CityBlock.all.to_a
    acacias = household_at("245")
    ipe_1180 = household_at("1180")
    ipe_1236 = household_at("1236")
    pedro_gusso = household_at("780")
    strategic_points = Household.all.select { |household| household.latest_version.property_type == "4" }

    aggregate_failures do
      # Interruptor e pessoas do §18.
      expect(VectorControl::Gate.usable?(Current.city)).to be(true)
      expect(result[:switch]).to eq("ligado (vector_control)")
      expect(VectorControl::Access.coordinator?(coordinator)).to be(true)
      expect(VectorControl::Access.lab?(lab)).to be(true)
      expect([ ace, coordinator, lab, keeper ]).to all(be_mfa_enrolled)
      expect(HealthTeamMember.active.where(health_team: team, professional: ace.professional).pluck(:cbo_code)).to eq([ "515140" ])
      expect(VectorControl::Access.field_agent?(ace, team)).to be(true)
      assignments = MicroAreaFieldAssignment.active.where(professional: ace.professional)
      expect(assignments.map { |row| [ row.micro_area_id, row.assigned_by_user_id ] }).to match_array(areas.map { |area| [ area.id, nurse.id ] })
      areas.each { |area| expect(HomeVisits::Access.reads_micro_area?(ace, area)).to be(true) }

      # UVZ, local, configuração, produtos e lotes com saldo.
      uvz = HealthUnit.find_by!(name: "UVZ Curitiba")
      expect(uvz.kind).to eq("environmental_surveillance")
      location = StockLocation.find_by!(health_unit: uvz, kind: "vector_control")
      expect(VectorControlSetting.find(1).stock_location_id).to eq(location.id)
      products = VectorProduct.order(:code).to_a
      expect(products.map { |product| product.uses }).to contain_exactly(%w[focal], %w[focal], %w[spatial])
      balances = Pharmacy::Ledger.balances(location_id: location.id, lot_ids: StockLot.where(vector_product_id: products.map(&:id)).pluck(:id))
      expect(balances.size).to eq(3)
      expect(balances.values).to all(be_positive)
      # Q21: o almoxarife da UVZ, vinculado ao local, é o autor das entradas dos lotes.
      expect(keeper).to be_mfa_enrolled
      expect(keeper.has_role?("stock_keeper")).to be(true)
      expect(StockLocationStaff.active.where(stock_location: location, user: keeper).pluck(:role)).to eq([ "stock_keeper" ])
      expect(Pharmacy::Access.allowed?(user: keeper, location: location, roles: %w[stock_keeper])).to be(true)
      entries = StockEntry.where(stock_location_id: location.id)
      expect(entries).to exist
      expect(entries.pluck(:recorded_by_user_id).uniq).to eq([ keeper.id ])

      # Território: quarteirões com vizinhos em dois bairros, todos os imóveis
      # das duas microáreas com perfil e quarteirão, risco variado, dois PE.
      expect(blocks.map(&:neighborhood_id).uniq.size).to eq(2)
      pairs = CityBlockNeighbor.current.to_a
      expect(pairs.size).to be >= 3
      expect(pairs.any? { |pair| pair.city_block.neighborhood_id != pair.neighbor_block.neighborhood_id }).to be(true)
      households = Household.where(micro_area: areas).to_a
      profiles = HouseholdVectorProfile.where(household_id: households.map(&:id)).to_a
      expect(profiles.size).to eq(households.size)
      expect(profiles.map(&:city_block_id)).to all(be_present)
      expect(profiles.filter_map(&:risk_class).uniq.size).to be >= 3
      expect(strategic_points.size).to eq(2)
      expect(strategic_points.map(&:micro_area_id)).to match_array(areas.map(&:id))

      # 1. Boletim completo na visita: depósitos, medidas e amostras, com os
      #    motivos 34–37 derivados (a ficha 8 lê os gravados).
      worked = VectorInspection.find_by!(household_id: acacias.id)
      expect([ worked.activity, worked.situation ]).to eq(%w[li worked])
      expect([ worked.deposits.count, worked.measures.count, worked.samples.count ]).to all(be_positive)
      expect(worked.home_visit.reasons).to include(35, 37)
      expect(worked.home_visit.home_visit_day.state).to eq("closed")

      # 2. Baixa de estoque e falta conciliável pela coordenação.
      expect(StockMovement.where(stock_location_id: location.id, kind: "vector_application")).to exist
      shortfall = VectorStockShortfall.open_shortfalls.sole
      expect(shortfall.cause).to eq("insufficient_balance")
      expect(VectorControl::ReconcileShortfall.allowed?(user: coordinator, location: shortfall.stock_location)).to be(true)

      # 3. Vencido por risco; e o PE fechado na pendência.
      entries = VectorControl::Due.entries(acacias.micro_area, today).index_by(&:household_id)
      expect(entries.fetch(acacias.id)).to have_attributes(reason: "due", risk_class: "red")
      expect(entries.fetch(acacias.id).due_since).to be <= today
      closed_pe = strategic_points.detect { |household| household.micro_area_id == acacias.micro_area_id }
      expect(entries.fetch(closed_pe.id).reason).to eq("pending")

      # 4. Quatro semanas de ovitrampas contadas, uma acima do alerta com a tarefa aberta.
      ovitraps = Ovitrap.active_ovitraps.to_a
      expect(ovitraps.size).to eq(2)
      ovitraps.each { |ovitrap| expect(ovitrap.readings.where.not(egg_count: nil).count).to eq(4) }
      alert = VectorControl::Parameters.current.values.fetch("ovitrap_alert_eggs")
      expect(OvitrapReading.where("egg_count >= ?", alert).count).to eq(1)
      expect(VectorTask.open_tasks.where(kind: "ovitrap_intensification").count).to eq(1)

      # 5. LIRAa census sorteado, metade inspecionada, com o item pending na lista.
      survey = LiraaSurvey.sole
      expect(survey.status).to eq("drawn")
      expect(survey.strata.map(&:mode)).to eq(%w[census])
      items = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id }).to_a
      expect(items.map(&:household_id)).to match_array([ ipe_1180.id, ipe_1236.id ])
      expect(items.map(&:status).tally).to eq("inspected" => 1, "pending" => 1)
      expect(entries.fetch(ipe_1236.id).reason).to eq("liraa")

      # 6. Caso de dengue numa paciente da semente, bloqueio active com um ciclo.
      notification = DiseaseNotification.find_by!(patient_id: patient(:daniela).id, disease_code: "dengue")
      block_case = TransmissionBlockCase.find_by!(disease_notification_id: notification.id)
      block = block_case.transmission_block
      expect([ block.status, block.cycles.count, block_case.added_by ]).to eq([ "active", 1, "job" ])
      expect(block.center_block_id).to eq(HouseholdVectorProfile.find_by!(household_id: pedro_gusso.id).city_block_id)
      due_02 = VectorControl::Due.entries(pedro_gusso.micro_area, today).index_by(&:household_id)
      expect(due_02.fetch(pedro_gusso.id).reason).to eq("transmission_block")
      expect(VectorInspection.find_by!(household_id: pedro_gusso.id).transmission_block_id).to eq(block.id)

      # 7. Amostra do LIRAa à espera do resultado (o resultado muda o IIP).
      liraa_inspection = VectorInspection.find_by!(household_id: ipe_1180.id, activity: "liraa")
      expect(liraa_inspection.samples.pending_results).to exist

      # 8. Relatórios: situações variadas e consumo com baixa.
      expect(VectorInspection.distinct.pluck(:situation)).to include("worked", "closed")

      # 9. Boletim offline no app: o ACE com o gate utilizável e as duas microáreas no escopo.
      scope = HomeVisits::Access.scope(ace, team)
      expect([ scope[:kind], scope[:micro_area_ids].sort ]).to eq([ "assigned", areas.map(&:id).sort ])

      # Saída: e-mail, papel e otpauth; nenhum CPF.
      expect(result[:users].map { |user| user[:email] }).to eq(%w[ace@curitiba.demo endemias@curitiba.demo entomologia@curitiba.demo almoxarifado-uvz@curitiba.demo])
      lines = described_class.summary_lines(result, password: "dev-password").join("\n")
      cpfs = Patient.where.not(cpf: nil).pluck(:cpf) + Professional.where.not(cpf: nil).pluck(:cpf)
      expect(cpfs.select { |cpf| lines.include?(cpf) || result.inspect.include?(cpf) }).to be_empty
    end
  end

  it "nenhum CPF/CNS inválido na semente nova" do
    professionals = Professional.count
    patients = Patient.count
    seed
    new_professionals = Professional.order(:created_at).last(Professional.count - professionals)
    expect(new_professionals.map { |row| row.user.email_address }).to eq([ "ace@curitiba.demo" ])
    expect(Patient.count).to eq(patients)
    aggregate_failures do
      Professional.find_each do |row|
        expect(CitizenIdentity::Cpf.check_digits_ok?(row.cpf)).to be(true) if row.cpf
        expect(Professionals::Cns.valid?(row.cns)).to be(true) if row.cns
      end
      Patient.find_each do |row|
        expect(CitizenIdentity::Cpf.check_digits_ok?(row.cpf)).to be(true) if row.cpf
        expect(Professionals::Cns.valid?(row.cns)).to be(true) if row.cns
      end
    end
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "desligado (só Curitiba liga)")
    expect([ CityBlock.count, Ovitrap.count, LiraaSurvey.count, TransmissionBlock.count ]).to eq([ 0, 0, 0, 0 ])
    expect(VectorControl::Gate.usable?(Current.city)).to be(false)
  end
end
