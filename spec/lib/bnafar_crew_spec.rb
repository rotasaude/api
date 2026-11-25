require "rails_helper"
require "webmock/rspec"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s
require Rails.root.join("lib/clinical_documents_crew").to_s
require Rails.root.join("lib/controlled_prescriptions_crew").to_s
require Rails.root.join("lib/pharmacy_crew").to_s
require Rails.root.join("lib/vaccination_crew").to_s
require Rails.root.join("lib/territory_registry_crew").to_s
require Rails.root.join("lib/home_visit_crew").to_s
require Rails.root.join("lib/vector_control_crew").to_s
require Rails.root.join("lib/ombudsman_crew").to_s
require Rails.root.join("lib/zoonoses_crew").to_s
require Rails.root.join("lib/bnafar_crew").to_s

# Semente de dev do módulo 27b (envio à BNAFAR) no banco de teste (nunca no de
# dev), com o elenco na ordem do db/seeds.rb até o ZoonosesCrew: a farmácia
# (central e UBS), a rede de frio e a sala de vacina, os insumos da UVZ e o
# centro de zoonoses. A semente do BNAFAR roda por último, uma vez por arquivo
# (api#159); quem chama `seed` de novo prova a segunda rodada.
RSpec.describe BnafarCrew, type: :model do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:today) { Time.zone.today }
  let(:central) { StockLocation.find_by!(kind: "central") }
  let(:cold_chain) { StockLocation.find_by!(kind: "cold_chain_central") }
  let(:csv_path) { described_class::CSV_PATH }

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
    RegulationCrew.seed_platform!
    ClinicalDocumentsCrew.seed_platform!
    PharmacyCrew.seed_platform!
    BnafarCrew.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    (CityProfile.current || CityProfile.new).update!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    unit = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
    unit.update!(cnes: "2384299") if unit.cnes.blank?
    ledi_ready!(City.find(city.id), pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    ClinicalDocumentsCrew.seed_current_city(slug: "curitiba")
    ControlledPrescriptionsCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    PharmacyCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    VaccinationCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    TerritoryRegistryCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    HomeVisitCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    Surveillance::DiseaseList::Load.call
    staff_with("vigilancia@curitiba.demo", "surveillance")
    VectorControlCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    OmbudsmanCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    ZoonosesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  before do
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba")

  def fingerprint
    tables = [ User, Membership, StockLocation, StockLot, StockMovement, StockEntry, StockOpening, VectorProduct, IntegrationCredential,
               CityFeature, ObmPresentation, ProcessedEvent, DomainEvent ]
    [ tables.map(&:count), StockLot.order(:id).pluck(:id, :bnafar_version), VectorProduct.order(:id).pluck(:id, :catmat_code),
      StockLocation.order(:id).pluck(:id, :cnes), File.binread(csv_path).hash ]
  end

  def lots_in(domains) = StockLot.all.select { |lot| domains.include?(Stock::Domain.of_lot(lot)) }

  def usable_domains
    [ Stock::Domain::MEDICATION, Stock::Domain::IMMUNOBIOLOGICAL, Stock::Domain::VECTOR_CONTROL ].select { |d| Stock::Domain.usable?(city, d) }
  end

  describe "depois da semente" do
    seed_once { @seeded = BnafarCrew.seed_current_city(slug: "curitiba") }

    def seeded = @seeded

    it "é idempotente: semear de novo não grava nada" do
      first = fingerprint
      expect { expect(seed).to eq(seeded) }.not_to(change { fingerprint })
      expect(fingerprint).to eq(first)
    end

    it "tem pendência de cada código, salvo exit_type_missing e lot_number_too_long" do
      found = Bnafar::Pendencies.current(domains_all: usable_domains, domains_on: Bnafar::Gate.domains(city)).map(&:code).uniq
      expected = Bnafar::Catalog::PENDENCY_CODES - %w[exit_type_missing lot_number_too_long]

      expect(found).to include(*expected)
      expect(found - Bnafar::Catalog::PENDENCY_CODES).to be_empty
    end

    it "grava a credencial bnafar nos dois ambientes, sem devolver o segredo no resumo" do
      credentials = IntegrationCredential.where(kind: "bnafar")
      expect(credentials.pluck(:environment)).to contain_exactly("homologation", "production")
      expect(credentials.map { |credential| credential.secret.keys.sort }.uniq).to eq([ %w[password username] ])

      lines = described_class.summary_lines(seeded).join("\n")
      expect(lines).to include("credencial bnafar (dev;")
      expect(lines).not_to include(city.encryption_key.to_s)
    end

    it "liga bnafar, bnafar_medications e bnafar_mock, com vacinas e vetorial desligados (domain_off)" do
      expect(Bnafar::Gate.usable?(city)).to be(true)
      expect(Bnafar::Gate.domains(city)).to eq([ Stock::Domain::MEDICATION ])
      expect(Bnafar::Mock.on?(city)).to be(true)
      expect(Platform::Features.enabled?(city, "bnafar_vaccines")).to be(false)
      expect(Platform::Features.enabled?(city, "bnafar_vector_supplies")).to be(false)
      expect(usable_domains).to include(Stock::Domain::IMMUNOBIOLOGICAL, Stock::Domain::VECTOR_CONTROL)
    end

    it "põe CNES de sete dígitos nos dois centrais, que não é de unidade nenhuma" do
      cnes = [ central.cnes, cold_chain.cnes ]
      expect(cnes).to all(match(Bnafar::Catalog::CNES))
      expect(cnes.uniq.size).to eq(2)
      expect(HealthUnit.where(cnes: cnes)).to be_empty
    end

    it "completa metade dos lotes de medicamento e de insumo, com um fabricante internacional, e deixa a outra metade pendente" do
      lots = lots_in([ Stock::Domain::MEDICATION, Stock::Domain::VECTOR_CONTROL ])
      complete, pending = lots.partition { |lot| Bnafar::LotFields.missing(lot).empty? }

      aggregate_failures do
        expect(complete.size).to be_within(1).of(lots.size / 2.0)
        expect(pending).not_to be_empty
        expect(complete.map(&:bnafar_version).uniq).to eq([ 1 ])
        expect(pending.map(&:bnafar_version).uniq).to eq([ 0 ])
        expect(complete.select(&:manufacturer_international).size).to eq(1)
        expect(complete.find(&:manufacturer_international)).to have_attributes(manufacturer_cnpj: nil, manufacturer: be_present)
        expect(lots.reject(&:manufacturer_international).filter_map(&:manufacturer_cnpj)).to all(satisfy { |cnpj| Cnpj.normalize(cnpj) })
      end
    end

    it "põe catmat_code em um produto vetorial só" do
      expect(VectorProduct.where.not(catmat_code: nil).count).to eq(1)
      expect(VectorProduct.where(catmat_code: nil)).not_to be_empty
    end

    it "carrega três apresentações do OBM: duas dos itens da farmácia e uma sem item, para a lista de revisão" do
      presentations = ObmPresentation.where(ampp_code: described_class::PRESENTATIONS.map { |p| p.fetch(:ampp_code) })
      expect(presentations.count).to eq(3)
      expect(ObmPresentation.unmatched.pluck(:ampp_code)).to eq([ described_class::PRESENTATIONS.last.fetch(:ampp_code) ])
      expect(MedicationCatalogItem.where(vmp_code: presentations.map(&:vmp_code)).count).to eq(2)
    end

    it "escreve o ok.csv de exemplo, com o cabeçalho exato, e todas as linhas passam na conferência da cidade" do
      text = File.binread(csv_path)
      expect(text.lines.first.chomp).to eq(OpeningImports::Reader::HEADER.join(";"))

      rows = OpeningImports::Reader.call(text).payload.fetch(:rows)
      expect(rows.size).to be >= 2
      results = OpeningImports::Validator.call(rows: rows, today: today, usable_domains: usable_domains,
                                               required_domains: Bnafar::Gate.domains(city))
      expect(results.map { |row| [ row.line, row.status, row.error_codes ] }).to all(satisfy { |_line, status, codes| status == "valid" && codes.empty? })
    end
  end
end
