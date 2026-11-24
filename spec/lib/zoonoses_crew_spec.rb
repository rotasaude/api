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
require Rails.root.join("lib/ombudsman_crew").to_s
require Rails.root.join("lib/zoonoses_crew").to_s

# Semente de dev do módulo 35b (contrato §17, Q30) no banco de teste (nunca no
# de dev), com o elenco na ordem do db/seeds.rb até o VectorControlCrew e o
# OmbudsmanCrew (a UVZ, o local, a coordenação, o ACE e a ouvidoria); a lista
# nacional de doenças e a vigilante (vigilancia@) fazem as vezes do
# SurveillanceCrew. Idempotente; tudo pelos comandos do módulo.
RSpec.describe ZoonosesCrew, type: :model do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:today) { Time.zone.today }
  let(:team_user) { User.find_by!(email_address: "zoonoses@curitiba.demo") }
  let(:veterinarian) { User.find_by!(email_address: "veterinaria@curitiba.demo") }
  let(:coordinator) { User.find_by!(email_address: "endemias@curitiba.demo") }

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
    VectorControlCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    OmbudsmanCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
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

  it "semear duas vezes não duplica animal, campanha, dose, inquérito, demanda nem observação" do
    first = seed
    tables = [ User, Membership, Professional, ProfessionalLink, VectorProduct, StockLot, StockMovement, StockEntry, Animal, RabiesCampaign,
               RabiesVaccination, LeishSurvey, LeishTest, Collar, BiteObservation, ShelterStay, ZoonosesDemand, Euthanasia, DiseaseNotification,
               OmbudsmanManifestation, OmbudsmanForwarding, OmbudsmanEvent, ProcessedEvent, DomainEvent, CityFeature, Patient ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
  end

  it "o roteiro 2–8 do §17 tem dado (microchip buscável, dose de posto sem cadastro, observação aberta, reagente pendente, " \
     "coleira vencendo, demanda aberta, dois no canil)" do
    result = seed

    aggregate_failures do
      expect(Zoonoses::Gate.usable?(Current.city)).to be(true)
      expect(result[:switch]).to eq("ligado (zoonoses)")

      # A veterinária só tem o papel zoonoses_team e o perfil (Q30).
      expect(veterinarian.memberships.active.pluck(:role)).to eq([ Zoonoses::Catalog::ROLE ])
      expect(Zoonoses::Access.veterinarian?(veterinarian)).to be(true)
      expect(veterinarian.professional).to have_attributes(council: "CRMV", council_state: "PR")
      expect(veterinarian.professional.registration_number).to match(/\A\d{1,10}\z/)
      link = veterinarian.professional.links.active.sole
      expect([ link.cbo_code, link.health_unit.name, link.health_unit.kind ]).to eq([ "223305", "UVZ Curitiba", "environmental_surveillance" ])
      expect(Zoonoses::Access.team?(team_user)).to be(true)
      expect(team_user.professional).to be_nil
      expect(Zoonoses::Access.coordinator?(coordinator)).to be(true)
      expect([ veterinarian, team_user ]).to all(be_mfa_enrolled)

      # Produtos e lotes no local da UVZ.
      expect(VectorProduct.where("uses && ARRAY['rabies_vaccine','collar']::text[]").pluck(:name, :uses))
        .to contain_exactly([ "Vacina antirrábica animal", %w[rabies_vaccine] ], [ "Coleira deltametrina 4%", %w[collar] ])

      # Oito animais: cinco com tutor, um comunitário, dois no canil; um com microchip de 15 dígitos buscável.
      expect(Animal.count).to eq(8)
      expect(Animal.where.not(tutor_patient_id: nil).count).to eq(5)
      expect(Animal.where(community: true, household_id: Household.select(:id)).count).to eq(1)
      expect(Animal.where(household_id: nil).count).to eq(2)
      expect(Animal.where.not(microchip: nil).count).to eq(3)
      expect(result[:microchip]).to match(Zoonoses::Catalog::MICROCHIP)
      expect(Animal.find_by(microchip: result[:microchip]).name).to eq("Thor")
      expect(ShelterStay.where(exited_on: nil).count).to eq(2)
      expect(Animal.where(status: "active").count).to eq(8)

      # Campanha open com quatro semanas de doses e doses de posto fixo sem animal.
      campaign = RabiesCampaign.find_by!(name: "Campanha antirrábica 2026")
      expect(campaign.stage).to eq("open")
      doses = RabiesVaccination.where(campaign_id: campaign.id, cancelled_at: nil)
      expect(doses.where(modality: "house").count).to eq(5)
      expect(doses.where(modality: "fixed_post", animal_id: nil).count).to eq(3)
      expect(doses.pluck(:vaccinated_on).map { |day| (today - day).to_i / 7 }.uniq.sort).to eq([ 0, 1, 2, 3 ])

      # Observação aberta pela notificação, pelo job inline.
      notification = DiseaseNotification.find_by!(disease_code: "acidente_animal_raiva")
      observation = BiteObservation.find_by!(disease_notification_id: notification.id)
      expect(observation).to have_attributes(state: "open", species: "dog", place: "home")
      expect(observation.ends_on).to be > today

      # Inquérito open com três testes (um DPP reagente, ELISA pendente) e uma coleira vencendo.
      survey = LeishSurvey.find_by!(name: "Inquérito canino de LV — Butiatuvinha")
      expect(survey.stage).to eq("open")
      tests = LeishTest.where(leish_survey_id: survey.id)
      expect(tests.count).to eq(3)
      reactive = tests.where(dpp_result: "reactive")
      expect(reactive.count).to eq(1)
      expect(reactive.first).to have_attributes(elisa_result: nil, elisa_on: nil)
      expect(Collar.active.where(due_on: today..(today + Zoonoses::Catalog::COLLAR_DUE_WINDOW)).count).to eq(1)

      # Demanda de escorpião aberta pela ouvidoria, encaminhada sozinha à UVZ.
      demand = ZoonosesDemand.sole
      expect(demand).to have_attributes(subtype: "scorpion", state: "open")
      expect(demand.ombudsman_forwarding.health_unit.name).to eq("UVZ Curitiba")

      # Resumo: só e-mail, papel, otpauth e o microchip de dev.
      lines = described_class.summary_lines(result, password: "dev-password").join("\n")
      expect(lines).to include(result[:microchip], "veterinaria@curitiba.demo", "zoonoses@curitiba.demo")
    end
  end

  it "nenhuma eutanásia; nenhum CPF/CNS inválido" do
    seed

    aggregate_failures do
      expect(Euthanasia.count).to eq(0)
      expect(LeishDogOutcome.count).to eq(0)
      professional = veterinarian.professional
      expect(Professionals::Cns.valid?(professional.cns)).to be(true)
      expect(CitizenIdentity::Cpf.check_digits_ok?(professional.cpf)).to be(true)
      expect(Patient.where.not(cpf: nil).pluck(:cpf)).to all(satisfy { |cpf| CitizenIdentity::Cpf.check_digits_ok?(cpf) })
      expect(Patient.where.not(cns: nil).pluck(:cns)).to all(satisfy { |cns| Professionals::Cns.valid?(cns) })
    end
  end

  it "fora de Curitiba não liga nada" do
    result = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")
    expect(result[:switch]).to eq("desligado (só Curitiba liga)")
    expect(Zoonoses::Gate.usable?(Current.city)).to be(false)
  end
end
