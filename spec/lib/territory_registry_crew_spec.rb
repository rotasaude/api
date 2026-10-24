require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/territory_registry_crew").to_s

# Semente de dev do módulo 24a no banco de teste (nunca no de dev), com o
# elenco na ordem do db/seeds.rb até o CareLinesCrew (de quem vêm a UBS, a
# equipe e as pessoas). O perfil da cidade e o CNES da UBS como o db:seed e
# o BillingCrew deixam em dev. Cada exemplo prova o que a prova no navegador
# precisa achar sem preparo manual. Idempotente.
RSpec.describe TerritoryRegistryCrew, type: :request do
  # A tabela da prova (a mesma do cabeçalho de lib/territory_registry_crew.rb):
  # pessoa → situação em RegistryStatus; "exited" = fora da população da equipe.
  let(:table) do
    { jose: "valid", osvaldo: "valid", daniela: "valid", lorena: "valid",
      ana: "due_soon", sebastiao: "expired", benedito: "missing_identifier", claudio: "refused",
      geraldo: "exited", tatiane: "exited",
      miguel: "missing", maria: "missing", rafael: "missing", juliana: "missing", clinical_record: "missing" }
  end

  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  let(:today) { Time.zone.today }
  let(:unit) { HealthUnit.find_by!(name: CareLinesCrew::UNIT) }
  let(:team) { HealthTeam.find_by!(health_unit: unit, name: CareLinesCrew::TEAM_NAME) }

  before do
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
    # Como o db:seed (perfil) e o BillingCrew (CNES da UBS) deixam em dev.
    (CityProfile.current || CityProfile.new).update!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    unit.update!(cnes: "2384299") if unit.cnes.blank?
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  # Exportação utilizável (ledi_export ligado, credencial, PEC simulado).
  def export_on!
    stub_pec!
    ledi_ready!(City.find(city.id), pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
  end

  # O id com que a pessoa aparece na lista: o paciente, ou o par sem paciente.
  def ref_of(key)
    return Citizen.find_by!(cpf: ScreeningCrew.send(:cpf_for, "curitiba:clinical_record:1")).patient_id if key == :clinical_record

    if CareLinesCrew::PEOPLE.key?(key)
      citizen = Citizen.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", key))
      return citizen.patient_id || citizen.id
    end
    described_class.patient_of("curitiba", key).id
  end

  def registration_of(key) = IndividualRegistration.find_by!(patient_id: ref_of(key))

  it "a tabela: cada pessoa na situação esperada, a contagem derivada dela e a ficha não gerada da pessoa em situação de rua" do
    export_on!
    result = seed
    statuses = TerritoryRegistry::RegistryStatus.page(team: team, limit: 100, today: today)[:people]
                                                .to_h { |row| [ row[:patient_id] || row[:citizen_id], row[:status] ] }
    expected = table.to_h { |key, status| [ ref_of(key), status ] }
    listed = expected.reject { |_, status| status == "exited" }
    tally = listed.values.tally

    aggregate_failures do
      expect(result).to include(switch: "ligado (territory_registry)", team: team.name)
      expect(TerritoryRegistry::Gate.usable?(Current.city)).to be(true)
      # Ninguém fora da tabela; quem saiu não está na população.
      expect(statuses).to eq(listed)
      expect(TerritoryRegistry::RegistryStatus.count(team: team, today: today))
        .to eq(TerritoryRegistry::RegistryStatus::COUNTED.to_h { |status| [ status.to_sym, tally.fetch(status, 0) ] })
      expect(result[:status]).to eq(TerritoryRegistry::RegistryStatus.count(team: team, today: today))

      # Microáreas: 01 da ACS, 02 descoberta; ACS sem conselho, CNS válido, 515105 na equipe.
      areas = MicroArea.where(team: team).order(:code)
      acs = User.find_by!(email_address: "acs@curitiba.demo")
      expect(areas.map { |a| [ a.code, a.name, a.acs_professional_id ] })
        .to eq([ [ "01", "Jardim das Flores — norte", acs.professional.id ], [ "02", "Jardim das Flores — sul", nil ] ])
      expect([ acs.professional.professional_name, acs.professional.council, Professionals::Cns.valid?(acs.professional.cns) ])
        .to eq([ "Rosana Aparecida Moreira", nil, true ])
      expect(HealthTeamMember.active.where(health_team: team, professional: acs.professional).pluck(:cbo_code)).to eq([ "515105" ])
      expect(acs).to be_mfa_enrolled
      expect(result[:users]).to eq([ { email: "acs@curitiba.demo", role: "health_professional (ACS 515105)",
                                       otpauth_uri: SignatureCrew.otpauth_uri(acs) } ])

      # Quatro domicílios, com família e endereço em Curitiba (CEP 82…, bairros da UBS).
      households = Household.where(micro_area: areas).to_a
      expect(households.size).to eq(4)
      expect(households.map { |h| h.latest_version.address["zip"] }).to all(start_with("82"))
      expect(households.map { |h| h.families.active_families.count }).to all(eq(1))
      expect(result[:households]).to eq(4)

      # Recém-nascida: sem CPF (justificativa 3), CNS válido, mãe = a responsável do domicílio.
      lorena = described_class.patient_of("curitiba", :lorena)
      expect([ lorena.cpf, lorena.no_cpf_reason, Professionals::Cns.valid?(lorena.cns) ]).to eq([ nil, "3", true ])
      expect(lorena.mother_name).to eq(described_class.patient_of("curitiba", :daniela).full_name)

      # Situação de rua: sem CPF nem CNS, sem domicílio (fora de área) → ficha "não gerada".
      benedito = registration_of(:benedito)
      expect([ benedito.patient.cpf, benedito.patient.cns, benedito.patient.no_cpf_reason ]).to eq([ nil, nil, "5" ])
      expect([ benedito.household_id, benedito.micro_area_id, benedito.team_id ]).to eq([ nil, nil, team.id ])
      failure = LediGenerationFailure.find_by(source_type: "IndividualRegistrationVersion", source_id: benedito.latest_version.id)
      expect(failure&.reason_codes).to eq([ "patient_without_identifier" ])
      expect(registration_of(:osvaldo).household_id).to be_nil

      # Saídas: óbito (com data e DO) e mudança; recusa com termo.
      geraldo, tatiane = registration_of(:geraldo), registration_of(:tatiane)
      expect([ geraldo.exit_reason, geraldo.death_on, geraldo.death_certificate ]).to eq([ "death", today - 20, "312458769" ])
      expect([ tatiane.exit_reason, tatiane.exited_on ]).to eq([ "moved", today - 60 ])
      expect(registration_of(:claudio)).to be_refused

      # Datas pelo caminho real: a versão e o cabeçalho com o mesmo instante.
      %i[jose osvaldo daniela lorena ana sebastiao benedito claudio].each do |key|
        registration = registration_of(key)
        last_save = registration.versions.where(origin: "save").reorder(version: :desc).first
        expect(registration.registered_at).to eq(last_save.created_at)
      end
      expect(registration_of(:sebastiao).registered_at.to_date).to eq(today << 25)
      # Situação e vencimento pela mesma conta da semente (29/02: ver "datas da semente").
      ana = registration_of(:ana)
      expect(TerritoryRegistry::Validity.status(ana, today: today, identified: true)).to eq("due_soon")
      expect(TerritoryRegistry::Validity.expires_on(ana.registered_at)).to eq(((today + 40) << 24) >> 24)

      # As fichas das outras versões nasceram (só a da situação de rua não).
      sources = IndividualRegistrationVersion.where(registration_id: IndividualRegistration.select(:id)).pluck(:id)
      expect(LediGenerationFailure.where(source_id: sources).count).to eq(1)
      expect(LediOutboxEntry.where(source_type: "IndividualRegistrationVersion", source_id: sources).count).to eq(sources.size - 1)
      expect(result[:fichas]).to eq("geradas (ledi_export utilizável)")

      # Telefones da semente: todos com o prefixo 96666.
      phones = IndividualRegistrationVersion.all.filter_map { |v| v.identification["telefone_celular"] } +
               HouseholdVersion.all.filter_map(&:contact_phone) + [ acs.professional.phone ]
      expect(phones).not_to be_empty
      expect(phones).to all(start_with("41#{described_class::PHONE_PREFIX}"))
    end
  end

  it "a segunda rodada não muda nada" do
    export_on!
    first = seed
    tables = [ User, Membership, Professional, ProfessionalLink, HealthTeamMember, MicroArea, Household, HouseholdVersion, Family,
               IndividualRegistration, IndividualRegistrationVersion, Patient, LediOutboxEntry, LediGenerationFailure, DomainEvent,
               CityFeature, PlatformEvent ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
  end

  it "login de dev: a ACS entra e cadastra só na microárea 01" do
    seed
    json_post "/session", email_address: "acs@curitiba.demo", password: "dev-password"
    expect(response).to have_http_status(:created)
    get "/territory/teams"
    row = json_body["teams"].find { |t| t["id"] == team.id }
    expect(row["micro_areas"].map { |a| [ a["code"], a["can_register"] ] }).to eq([ [ "01", true ], [ "02", false ] ])
  end

  it "com a equipe da UBS com outro nome (a do ExamCrew em dev) e sem exportação: semeia na mesma equipe, sem ficha" do
    team.update!(name: "ESF UBS Jardim das Flores (dev)")
    result = seed
    expect(result).to include(team: "ESF UBS Jardim das Flores (dev)", fichas: "não geradas (ledi_export desligado ou não utilizável)")
    expect(MicroArea.where(team: team).count).to eq(2)
    expect(LediOutboxEntry.where(source_type: "IndividualRegistrationVersion")).to be_empty
    expect(LediGenerationFailure.count).to eq(0)
  end

  it "sem o mantenedor de dev não liga nada" do
    allow(Maintainer).to receive(:find_by).and_call_original
    allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
    result = nil
    expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
    expect(result).to include(switch: "desligado (sem mantenedor dev@local)", micro_areas: [])
    expect(MicroArea.count).to eq(0)
  end

  it "sem UF ou IBGE no perfil da cidade falha antes de ligar, dizendo o que rodar" do
    CityProfile.current.update!(ibge_code: nil)
    expect { seed }.to raise_error(/perfil da cidade sem UF\/IBGE — rode o db:seed/)
    expect(TerritoryRegistry::Gate.enabled?(Current.city)).to be(false)
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "desligado (só Curitiba liga)")
    expect(MicroArea.count).to eq(0)
    expect(TerritoryRegistry::Gate.enabled?(Current.city)).to be(false)
  end
end

# Datas da semente (revisão final, M3): a Ana "vence em 40 dias" com
# moment({ expires_in: 40 }) = (hoje + 40) << 24. Date#>> não é o inverso de
# <<: com hoje + 40 = 29/02 o cadastro vence em 28/02. A prova é a situação
# (due_soon) e o vencimento pela mesma conta, nunca "registrado >> 24 = hoje + 40".
RSpec.describe TerritoryRegistryCrew, "datas da semente" do
  include ActiveSupport::Testing::TimeHelpers

  # 2028 é bissexto: hoje + 40 = 29/02; hoje = 29/02; hoje = 28/02.
  [ "2028-01-20", "2028-02-29", "2028-02-28" ].each do |day|
    it "Ana em #{day}: due_soon, vencimento = ((hoje + 40) << 24) >> 24" do
      travel_to(Time.zone.parse("#{day} 10:00")) do
        today = Time.zone.today
        registered_at = described_class.moment({ expires_in: 40 }, hour: 9)
        registration = IndividualRegistration.new(registered_at: registered_at, refused: "false")
        expect(TerritoryRegistry::Validity.status(registration, today: today, identified: true)).to eq("due_soon")
        expect(TerritoryRegistry::Validity.expires_on(registered_at)).to eq(((today + 40) << 24) >> 24)
      end
    end
  end
end
