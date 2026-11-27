require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s
require Rails.root.join("lib/vaccination_crew").to_s
require Rails.root.join("lib/regulation_rnds_crew").to_s

# Semente de dev do módulo 26c (envio da regulação à RNDS) no banco de teste
# (nunca no de dev), com o elenco na ordem do db/seeds.rb até o RegulationCrew
# (os dez pedidos da 26a). A semente sob teste roda uma vez (api#159); quem
# chama `seed` de novo prova a segunda rodada. Os motivos de parado são
# conferidos pela mesma conferência do envio (RndsValidation) sobre os fatos do
# documento que sairia: o bloqueio em si é do RndsDeliverJob.
RSpec.describe RegulationRndsCrew, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  seed_once do
    city = clinical_city!(record_mode: "off", enabled: false)
    create_default_protocol!
    admin = staff_with("admin@curitiba.demo", "municipal_admin")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    city_profile!.update!(ibge_code: "4106902", uf: "PR")
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
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    RegulationCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
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

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41")

  def request_of(spec) = RegulationCrew.request_of("curitiba", spec)

  def scenario_request(key) = request_of(described_class::SCENARIOS.fetch(key))

  def sync_of(request) = RegulationRndsSync.find_by!(regulation_request_id: request.id)

  # O que o envio confere no documento que sairia (o primeiro passo, senão o desejado).
  def verdict(request)
    settings = RegulationRndsSetting.current
    sync = sync_of(request)
    facts = Regulation::RiraFacts.for(request: request.reload, settings: settings, credential: IntegrationCredential.find_by!(kind: "rnds_regulation"))
    Regulation::RndsValidation.call(facts: facts, status: sync.pending_steps.first || Regulation::RndsSync.target(request, settings: settings))
  end

  # Final wave, item 8: o 92222 era do ClinicalRecordCrew; o prefixo desta semente é só dela.
  it "o prefixo de telefone não colide com o de outra semente" do
    others = Dir[Rails.root.join("lib/*_crew.rb")].reject { |file| file.end_with?("/regulation_rnds_crew.rb") }.flat_map do |file|
      File.read(file).scan(/PHONE_PREFIX = "(\d{5})"|%s(9\d{4})%04d/).flatten.compact
    end
    expect(others).to include(ClinicalRecordCrew::PHONE_PREFIX, "97777") # controle: a varredura acha as duas formas
    expect(others).not_to include(described_class::PHONE_PREFIX)
  end

  describe "depois da semente de Curitiba" do
    seed_once do
      CityCatalog.reset_cache!
      Current.city = City.find_by!(slug: TEST_CITY_A.slug)
      @seeded = described_class.seed_current_city(slug: "curitiba", ddd: "41")
    end

    def seeded = @seeded

    it "credencial de dev, interruptores e configurações" do
      credential = IntegrationCredential.find_by!(kind: "rnds_regulation")
      secret = credential.secret.to_h.stringify_keys
      settings = RegulationRndsSetting.current

      aggregate_failures do
        expect(credential.environment).to eq("production")
        expect(secret.keys).to match_array(IntegrationCredential::SECRET_KEYS.fetch("rnds_regulation"))
        expect(secret["requester_id"]).to eq("12345")
        expect(Professionals::Cns.valid?(secret["responsible_cns"])).to be(true)
        expect(OpenSSL::PKCS12.new(Base64.strict_decode64(secret["pfx_base64"]), secret["pfx_password"]).certificate.not_after).to be > Time.current
        expect(Platform::Features.enabled?(city, "rnds_regulation")).to be(true)
        expect(Platform::Features.enabled?(city, "rnds_mock")).to be(true)
        expect(Platform::Features.usable?(city, "rnds_regulation")).to be(true)
        expect(settings.specialty_sigtap[RegulationCrew::CARDIOLOGY]).to eq("0301010072")
        expect(settings.send_external).to be(true)
        expect(CareOffer.where.not(performer_cbo: nil).count).to eq(1)
        expect(CareProvider.where.not(default_performer_cbo: nil).count).to eq(1)
      end
    end

    it "há linha para cada motivo de parado que a semente alcança, cada uma com o seu motivo" do
      reasons = described_class::BLOCKED.to_h { |reason, key| [ reason, verdict(scenario_request(key)) ] }

      aggregate_failures do
        expect(reasons).to eq(described_class::BLOCKED.to_h { |reason, _| [ reason, [ :blocked, [ reason ] ] ] })
        # `missing_priority` é inalcançável no banco (suggested_color é NOT NULL) e `patient_without_cpf_or_cns`
        # só nasce no provisório da UPA (módulo 32): ficam de fora.
        expect(described_class::BLOCKED.keys).to match_array(Regulation::RndsCatalog::BLOCK_REASONS - %w[missing_priority patient_without_cpf_or_cns])
        expect(RegulationRndsSync.where(regulation_request_id: described_class::BLOCKED.values.map { |key| scenario_request(key).id }).count)
          .to eq(described_class::BLOCKED.size)
      end
    end

    it "a falta externa nasce sem as colunas da Q24 (o formato anterior ao deploy)" do
      request = scenario_request(:external_absence)
      missed = request.events.select { |event| event.status == "missed" }

      aggregate_failures do
        expect(request.state_regulated).to be(true)
        expect(missed.size).to eq(1)
        expect([ missed.first.scheduled_at, missed.first.ends_at, missed.first.care_provider_id ]).to all(be_nil)
        expect(sync_of(request).pending_steps.map { |step| step["status"] }).to eq(%w[absence])
      end
    end

    it "os marcadores existem e esses pedidos passam na conferência" do
      refused = sync_of(request_of(RegulationCrew::REQUESTS.find { |spec| spec[:n] == 3 }))
      timeout = sync_of(request_of(RegulationCrew::REQUESTS.find { |spec| spec[:n] == 4 }))

      aggregate_failures do
        expect(refused.bundle_identifier).to match(/\ARECUSA-[0-9a-f-]{36}\z/)
        expect(timeout.bundle_identifier).to match(/\ATIMEOUT-[0-9a-f-]{36}\z/)
        expect([ refused, timeout ].map { |sync| verdict(sync.regulation_request) }).to eq([ :ok, :ok ])
        expect([ refused.status, timeout.status ]).to eq(%w[queued queued])
      end
    end

    # Final wave, item 8: o mapa salvo guarda o SIGTAP vencido da ginecologia (pedido 14); a tela de
    # configurações recusa todo salvar enquanto ele estiver lá. As summary_lines dizem como sair disso.
    it "o SIGTAP vencido da ginecologia barra o salvar com o path dela; removido, salva (o roteiro das summary_lines)" do
      settings = RegulationRndsSetting.current
      admin = User.find_by!(email_address: "admin@curitiba.demo")
      attrs = { "expected_version" => settings.version, "priority_by_color" => settings.priority_by_color,
                "specialty_sigtap" => settings.specialty_sigtap, "send_external" => settings.send_external }
      refused = Regulation::SaveRndsSettings.call(attrs: attrs, by: admin)
      expect([ refused.reason, refused.details ]).to eq([ :invalid_sigtap, { path: "specialty_sigtap.#{described_class::GYNECOLOGY}" } ])
      expect(described_class.summary_lines(seeded).join("\n")).to include("specialty_sigtap.#{described_class::GYNECOLOGY}")

      saved = Regulation::SaveRndsSettings.call(attrs: attrs.merge("specialty_sigtap" => settings.specialty_sigtap.except(described_class::GYNECOLOGY)),
                                                by: admin)
      expect(saved).to be_ok
      expect(RegulationRndsSetting.current.specialty_sigtap).not_to have_key(described_class::GYNECOLOGY)
    end

    it "nenhum segredo nas summary_lines" do
      text = described_class.summary_lines(seeded).join("\n")
      secret = IntegrationCredential.find_by!(kind: "rnds_regulation").secret.to_h.stringify_keys

      aggregate_failures do
        expect(text).to include("rnds_regulation")
        expect(text).to include("TIMEOUT")
        %w[pfx_base64 pfx_password requester_id responsible_cns].each do |key|
          expect(text).not_to include(secret.fetch(key)), key
        end
        expect(text).not_to match(/staging|production|produção|homolog/i)
        expect(text).not_to match(/\d{11}|\d{15}/)
      end
    end

    it "idempotente: semear de novo não grava nada" do
      tables = [ RegulationRequest, RegulationRequestEvent, RegulationRndsSync, RegulationRndsDelivery, IntegrationCredential, CareOffer,
                 CareProvider, HealthUnit, Patient, Citizen, CityFeature ]
      before_counts = tables.map(&:count)
      versions = [ RegulationRndsSetting.current.version, RegulationRndsSetting.current.specialty_sigtap ]
      identifiers = RegulationRndsSync.order(:id).pluck(:id, :bundle_identifier)

      again = nil
      expect { again = seed }.not_to(change { IntegrationCredential.find_by!(kind: "rnds_regulation").set_at })

      aggregate_failures do
        expect(tables.map(&:count)).to eq(before_counts)
        expect([ RegulationRndsSetting.current.version, RegulationRndsSetting.current.specialty_sigtap ]).to eq(versions)
        expect(RegulationRndsSync.order(:id).pluck(:id, :bundle_identifier)).to eq(identifiers)
        expect(again[:blocked]).to eq(seeded[:blocked])
      end
    end
  end
end
