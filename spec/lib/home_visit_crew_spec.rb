require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/territory_registry_crew").to_s
require Rails.root.join("lib/home_visit_crew").to_s

# Semente de dev do módulo 24b no banco de teste (nunca no de dev), com o
# elenco na ordem do db/seeds.rb até o TerritoryRegistryCrew (de quem vêm a
# UBS, a equipe, a enfermeira, a microárea 02 descoberta, o domicílio da
# R. Pedro Gusso e as pessoas). O perfil da cidade e o CNES da UBS como o
# db:seed e o BillingCrew deixam em dev; a exportação utilizável, para a ficha
# da folha de ontem nascer no fechamento. Idempotente.
RSpec.describe HomeVisitCrew, type: :model do
  # A cidade nasce em off no seed_once; o ClinicalRecordCrew e o ledi_ready! a
  # deixam em record. Recriá-la por exemplo (let!) a voltaria para off.
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:today) { Time.zone.today }
  let(:unit) { HealthUnit.find_by!(name: CareLinesCrew::UNIT) }
  let(:team) { HealthTeam.find_by!(health_unit: unit, name: CareLinesCrew::TEAM_NAME) }
  let(:tacs) { User.find_by!(email_address: "tacs@curitiba.demo") }
  let(:area) { MicroArea.find_by!(team: team, code: "02") }

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
    # Como o db:seed (perfil) e o BillingCrew (CNES da UBS) deixam em dev.
    (CityProfile.current || CityProfile.new).update!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    unit = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
    unit.update!(cnes: "2384299") if unit.cnes.blank?
    # Exportação utilizável (ledi_export ligado, credencial); o PEC simulado é
    # stub do rspec-mocks e fica por exemplo.
    ledi_ready!(City.find(city.id), pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    TerritoryRegistryCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  before do
    stub_pec!
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

  it "semear duas vezes não duplica (nem fichas, nem trilhas, nem eventos)" do
    first = seed
    tables = [ User, Membership, Professional, ProfessionalLink, HealthTeamMember, MicroAreaFieldAssignment, HomeVisitDay, HomeVisit,
               CollectiveActivity, CollectiveActivityParticipant, CollectiveActivityProfessional, FieldDevice, Patient,
               LediOutboxEntry, LediGenerationFailure, DomainEvent, CityFeature, PlatformEvent ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
  end

  it "a folha de ontem tem ficha; a de hoje fica aberta; TACS atribuído, atividades 5 e 1 e aparelho revogado" do
    result = seed
    nurse = User.find_by!(email_address: "enfermeira@curitiba.demo")
    days = HomeVisitDay.where(professional: tacs.professional, team: team)
    yesterday = days.find_by!(day: today - 1)
    open_today = days.find_by!(day: today)

    aggregate_failures do
      # Interruptores ligados e utilizáveis.
      expect(HomeVisits::Gate.usable?(Current.city)).to be(true)
      expect(CollectiveActivities::Gate.usable?(Current.city)).to be(true)
      expect(result[:switch]).to eq("ligado (home_visits e collective_activities)")

      # O TACS: CBO 322255 na equipe, CNS e CPF válidos, sem conselho, MFA;
      # atribuído à microárea 02 (descoberta) pela enfermeira (223505) da equipe.
      professional = tacs.professional
      expect([ professional.council, Professionals::Cns.valid?(professional.cns), CitizenIdentity::Cpf.check_digits_ok?(professional.cpf) ]).to eq([ nil, true, true ])
      expect(HealthTeamMember.active.where(health_team: team, professional: professional).pluck(:cbo_code)).to eq([ "322255" ])
      expect(HealthTeamMember.active.find_by!(health_team: team, professional: nurse.professional).cbo_code).to eq("223505")
      expect(tacs).to be_mfa_enrolled
      assignment = MicroAreaFieldAssignment.active.sole
      expect([ assignment.micro_area_id, assignment.professional_id, assignment.assigned_by_user_id ])
        .to eq([ area.id, professional.id, nurse.id ])
      expect(HomeVisits::Access.scope(tacs, team)).to eq(micro_area_ids: [ area.id ], kind: "assigned")

      # Ontem: fechada pela dona, com a ficha na fila; morador, família, comércio,
      # recusa e a retirada (fora da ficha).
      expect([ yesterday.state, yesterday.closed_by, yesterday.closed_by_user_id, yesterday.cbo ]).to eq([ "closed", "user", tacs.id, "322255" ])
      visits = yesterday.home_visits.order(:occurred_at)
      expect(visits.map { |v| [ v.subject, v.property_type, v.outcome, v.withdrawn? ] }).to eq(
        [ [ "resident", "1", 1, false ], [ "family_responsible", "1", 1, false ], [ "none", "2", 1, false ],
          [ "resident", "1", 2, false ], [ "resident", "1", 1, true ] ]
      )
      expect(visits.map(&:patient_id)).to eq([ patient(:lorena).id, patient(:daniela).id, nil, patient(:claudio).id, patient(:daniela).id ])
      expect(visits.map { |v| v.occurred_at.to_date }.uniq).to eq([ today - 1 ])
      expect(LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: yesterday.id).count).to eq(1)
      expect(LediGenerationFailure.where(source_type: "HomeVisitDay").count).to eq(0)
      expect(result.dig(:yesterday, :ficha)).to eq("gerada")

      # Hoje: aberta, com visitas de hoje, sem ficha.
      expect(open_today.state).to eq("open")
      expect(open_today.home_visits.valid.count).to be >= 1
      expect(open_today.home_visits.map { |v| v.occurred_at.to_date }.uniq).to eq([ today ])
      expect(LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: open_today.id)).to be_empty

      # Atividades: tipo 5 com 3 participantes identificados (CPF), tipo 1 sem lista; fichas na fila.
      group = CollectiveActivity.find_by!(activity_type: 5)
      meeting = CollectiveActivity.find_by!(activity_type: 1)
      expect(group.participants.map(&:patient_id)).to match_array([ patient(:jose), patient(:sebastiao), patient(:osvaldo) ].map(&:id))
      expect(group.participants.map { |p| CitizenIdentity::Cpf.check_digits_ok?(p.patient.cpf) }).to all(be(true))
      expect([ group.recorded_by_user_id, group.cbo, group.team_id ]).to eq([ tacs.id, "322255", team.id ])
      expect(group.professionals.map(&:professional_id)).to eq([ nurse.professional.id ])
      expect([ meeting.recorded_by_user_id, meeting.participants.count, meeting.meeting_topics ]).to eq([ nurse.id, 0, [ 3, 4 ] ])
      expect(LediOutboxEntry.where(source_type: "CollectiveActivity", source_id: [ group.id, meeting.id ]).count).to eq(2)

      # Aparelho: um, revogado pela dona; só o digest.
      device = FieldDevice.where(user: tacs).sole
      expect([ device.revoked?, device.revoked_reason, device.revoked_by_user_id ]).to eq([ true, "user", tacs.id ])
      expect(device.token_digest).to match(/\A\h{64}\z/)

      # Saída: e-mail, papel e otpauth; nenhum CPF.
      expect(result[:users]).to eq([ { email: "tacs@curitiba.demo", role: "health_professional (TACS 322255)",
                                       otpauth_uri: SignatureCrew.otpauth_uri(tacs) } ])
      cpfs = Patient.where.not(cpf: nil).pluck(:cpf) + [ professional.cpf ]
      lines = described_class.summary_lines(result, password: "dev-password").join("\n")
      expect(cpfs.select { |cpf| lines.include?(cpf) || result.inspect.include?(cpf) }).to be_empty
    end
  end

  it "nenhum token em claro no banco: o token do cadastro só existe na resposta do comando" do
    tokens = []
    allow(FieldDevices::Register).to receive(:call).and_wrap_original do |original, **args|
      original.call(**args).tap { |result| tokens << result.payload[:token] if result.ok? }
    end
    result = seed
    expect(tokens.size).to eq(1)
    token = tokens.first
    expect(token).to start_with(FieldSync::Catalog::TOKEN_PREFIX)

    # Varre toda linha de toda tabela da cidade e da plataforma (t::text).
    rows_with = lambda do |text|
      [ ApplicationRecord.connection, PlatformRecord.connection ].uniq.sum do |connection|
        connection.tables.sum do |table|
          connection.select_value(
            "SELECT count(*) FROM #{connection.quote_table_name(table)} t WHERE strpos(t::text, #{connection.quote(text)}) > 0"
          ).to_i
        end
      end
    end
    aggregate_failures do
      expect(rows_with.(token)).to eq(0)
      # Controle positivo: a mesma varredura acha o digest (a linha do aparelho).
      expect(rows_with.(FieldDevice.digest(token))).to eq(1)
      expect(FieldDevice.find_by!(token_digest: FieldDevice.digest(token))).to be_revoked
      expect(result.inspect).not_to include(token)
      expect(described_class.summary_lines(result, password: "dev-password").join("\n")).not_to include(token)
    end
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "desligado (só Curitiba liga)")
    expect([ HomeVisitDay.count, CollectiveActivity.count, FieldDevice.count ]).to eq([ 0, 0, 0 ])
    expect(HomeVisits::Gate.usable?(Current.city)).to be(false)
  end
end
