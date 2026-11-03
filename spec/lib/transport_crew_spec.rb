require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s
require Rails.root.join("lib/transport_crew").to_s

# Semente de dev do módulo 30 (ADR 0048) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o CareLinesCrew (UBS, médica, José e
# Sebastião) e a SIGTAP de dev do RegulationCrew. Cada exemplo prova o que a
# prova no navegador precisa achar sem preparo manual. Idempotente; a saída
# nunca leva CPF nem nome de paciente.
RSpec.describe TransportCrew do
  let!(:city) { clinical_city! }
  let(:dispatcher) { User.find_by!(email_address: "transporte@curitiba.dev") }

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
    RegulationCrew.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def counts
    [ TransportVehicle.count, TransportDriver.count, TransportDestination.count, TransportSeries.count, TransportTrip.count,
      TransportTripPassenger.count, TransportTripStop.count, TfdCase.count, TfdCaseEvent.count, HealthUnit.count, Membership.count,
      CityFeature.count ]
  end

  it "liga os dois interruptores e deixa a frota, os motoristas, os destinos e os parâmetros prontos" do
    result = seed
    settings = Transport::Settings.current
    unit = HealthUnit.find_by!(name: "Secretaria Municipal de Saúde")

    aggregate_failures do
      expect(result[:switch]).to eq("ligado (sanitary_transport e tfd)")
      expect(Transport::Gate.usable?(city)).to be(true)
      expect(Tfd::Gate.usable?(city)).to be(true)
      expect(TransportVehicle.pluck(:plate, :seats, :wheelchair_spots, :kind).sort)
        .to eq([ [ "ABC1D23", 15, 1, "van" ], [ "BRA2E19", 4, 0, "car" ] ])
      expect(TransportDestination.pluck(:ibge_code, :distance_km, :metropolitan).sort)
        .to eq([ [ "4101804", 27, true ], [ "4106902", 0, false ], [ "4113700", 380, false ], [ "4119905", 117, false ] ])
      expect(unit).to have_attributes(kind: "health_management")
      expect(unit.cnes).to match(/\A\d{7}\z/)
      expect(settings.tfd_billing_health_unit_id).to eq(unit.id)
      davi = TransportDriver.find_by!(user: User.find_by!(email_address: "motorista@curitiba.dev"))
      caio = TransportDriver.find_by!(user: User.find_by!(email_address: "condutor@curitiba.dev"))
      expect(davi).to have_attributes(license_category: "D", license_expires_on: Time.zone.today + 3 * 365)
      expect(caio).to have_attributes(license_category: "B", license_expires_on: Time.zone.today + 20)
    end
  end

  it "os usuários têm o papel e o TOTP fixo, e a saída leva só e-mail, papel e otpauth" do
    result = seed
    roles = result[:users].to_h { |user| [ user[:email], user[:role] ] }

    expect(roles).to eq("transporte@curitiba.dev" => "transport_dispatcher", "tfd@curitiba.dev" => "tfd_committee",
                        "motorista@curitiba.dev" => "driver", "condutor@curitiba.dev" => "driver")
    expect(result[:users].map { |user| user[:otpauth_uri] }).to all(start_with("otpauth://totp/"))
    expect(User.where(email_address: roles.keys).map(&:mfa_enrolled?)).to all(be(true))
  end

  it "a série de hemodiálise gerou viagens seg/qua/sex nas próximas três semanas" do
    seed
    series = TransportSeries.sole
    days = TransportTrip.where(status: "planned").pluck(:date)
    horizon = Time.zone.today..(Time.zone.today + Transport::Catalog::SERIES_HORIZON_DAYS - 1)

    aggregate_failures do
      expect(series).to have_attributes(weekdays: [ 1, 3, 5 ], starts_on: Time.zone.today)
      expect(series.transport_destination.ibge_code).to eq("4119905")
      expect(days).not_to be_empty
      expect(days).to all(satisfy { |day| horizon.cover?(day) && [ 1, 3, 5 ].include?(day.cwday) })
      expect(days.sort).to eq(horizon.select { |day| [ 1, 3, 5 ].include?(day.cwday) })
      expect(TransportTripPassenger.where(transport_series_id: series.id).count).to eq(days.size)
    end
  end

  it "o TFD de Londrina está authorized, com atendimento em 7 dias e a unidade de faturamento nos parâmetros" do
    result = seed
    tfd = TfdCase.sole

    aggregate_failures do
      expect(result[:tfd]).to eq("authorized" => 1)
      expect(tfd.status).to eq("authorized")
      expect(tfd.transport_destination.ibge_code).to eq("4113700")
      expect(tfd.requester_cbo).to start_with("225")
      expect(tfd.appointment_at.to_date).to eq(Time.zone.today + 7)
      expect(tfd.appointment_at).to be_future
      expect(tfd.tfd_case_events.pluck(:kind)).to include("created", "submitted", "appointment_set", "authorized")
      expect(Transport::Settings.current.tfd_billing_health_unit_id).to eq(HealthUnit.find_by!(name: "Secretaria Municipal de Saúde").id)
    end
  end

  it "duas rodadas dão as mesmas contagens" do
    seed
    first = counts
    seed

    expect(counts).to eq(first)
  end

  it "nenhuma linha da saída leva CPF nem nome de paciente" do
    result = seed
    text = described_class.summary_lines(result, password: "dev-password").join("\n")
    secrets = Patient.all.flat_map { |patient| [ patient.cpf, patient.full_name ] }.compact

    aggregate_failures do
      expect(secrets).not_to be_empty
      secrets.each { |secret| expect(text).not_to include(secret) }
      expect(text).not_to match(/\b\d{11}\b/)
      expect(text).to include("transporte@curitiba.dev (transport_dispatcher)")
    end
  end

  it "recusa rodar em ambiente implantado" do
    allow(Rota).to receive(:deployed?).and_return(true)

    expect { seed }.to raise_error(/só de dev/)
  end

  it "sem as pessoas do CareLinesCrew, para com a mensagem de pré-requisito" do
    allow(Patient).to receive(:find_by).and_call_original
    allow(Patient).to receive(:find_by).with(cpf: anything).and_return(nil)

    expect { seed }.to raise_error(/CareLinesCrew/)
  end
end
