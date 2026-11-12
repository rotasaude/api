require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/ombudsman_crew").to_s

# Semente de dev do módulo 33 (ADR 0051) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o CareLinesCrew (as unidades e as
# pessoas do wpda). Cada exemplo prova o que a prova no navegador precisa achar
# sem preparo manual. Idempotente; o resumo nunca leva protocolo, texto nem nome.
RSpec.describe OmbudsmanCrew, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { clinical_city! }

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
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(email) = User.find_by!(email_address: email)
  def settings = OmbudsmanSetting.current
  def color(manifestation) = Ombudsman::Deadlines.color(manifestation, settings, today: Time.zone.today)

  def counts
    [ OmbudsmanManifestation, OmbudsmanEvent, OmbudsmanForwarding, OmbudsmanNotice, OmbudsmanAttachment, OmbudsmanSatisfactionResponse,
      OmbudsmanResponder, Department, OmbudsmanAnnualReport, User, Membership, CitizenSession, Citizen, ExamFile ].map(&:count)
  end

  it "liga os dois interruptores e deixa os prazos padrão e os assuntos semeados" do
    result = seed

    aggregate_failures do
      expect(result[:switch]).to eq("ligado (ombudsman e ombudsman_anonymous_web)")
      expect(Ombudsman::Gate.usable?(city)).to be(true)
      expect(Ombudsman::AnonymousGate.usable?(city)).to be(true)
      expect(settings.response_days).to eq(30)
      expect(OmbudsmanSubject.where(parent_id: nil).count).to be >= 8
    end
  end

  it "cria a equipe com papel e TOTP fixo, e os respondentes nos seus destinos" do
    seed

    aggregate_failures do
      { "ouvidor@curitiba.dev" => "ombudsman", "ouvidoria@curitiba.dev" => "ombudsman_staff",
        "farmacia.resp@curitiba.dev" => "ombudsman_responder", "ubs.resp@curitiba.dev" => "ombudsman_responder" }.each do |email, role|
        account = user(email)
        expect(account.has_role?(role)).to be(true), email
        expect(account.mfa_enrolled?).to be(true), email
        expect(account.authenticate("dev-password")).to be_truthy, email
      end
      expect(Department.order(:name).pluck(:name)).to eq([ "Assistência Farmacêutica", "Atenção Primária", "Regulação", "Vigilância Sanitária" ])
      expect(Ombudsman::Access.destinations(user("farmacia.resp@curitiba.dev"))[:department_ids])
        .to eq([ Department.find_by!(name: "Assistência Farmacêutica").id ])
      expect(Ombudsman::Access.destinations(user("ubs.resp@curitiba.dev"))[:health_unit_ids])
        .to eq([ HealthUnit.find_by!(name: OmbudsmanCrew::RESPONDER_UNIT).id ])
    end
  end

  it "deixa uma manifestação de cada cor e os cenários da prova no navegador" do
    seed
    open_ones = OmbudsmanManifestation.where.not(state: Ombudsman::Catalog::FINAL_STATES)

    aggregate_failures do
      expect(open_ones.map { |m| color(m) }.uniq).to include("green", "yellow", "red", "paused")

      red = open_ones.find { |m| color(m) == "red" }
      expect([ red.channel, red.citizen_id, red.state ]).to eq([ "phone", nil, "in_analysis" ])
      expect((Time.zone.today - red.received_at.in_time_zone.to_date).to_i).to eq(35)

      expect(OmbudsmanManifestation.where(identification_mode: "anonymous", channel: "web", state: "received").count).to eq(1)
      expect(OmbudsmanManifestation.where(identification_mode: "preserved", state: "awaiting_complement").count).to eq(1)
      expect(OmbudsmanManifestation.where(state: "archived", archive_reason: "duplicate").where.not(duplicate_of_id: nil).count).to eq(1)
      expect(OmbudsmanManifestation.where(state: "forwarded").count).to eq(2)
      expect(OmbudsmanManifestation.where(extended: true).count).to be >= 1
      expect(OmbudsmanForwarding.where(state: "replied").count).to be >= 1
      expect(OmbudsmanEvent.where(kind: %w[complement_requested complement_received final_response interim_response]).distinct.pluck(:kind))
        .to match_array(%w[complement_requested complement_received final_response interim_response])
      expect(OmbudsmanNotice.distinct.pluck(:kind)).to include("final_response", "complement_requested")
      expect(OmbudsmanSatisfactionResponse.count).to be >= 6
      expect(OmbudsmanAttachment.count).to eq(1)
      expect(OmbudsmanAttachment.first.filename).to eq("anexo-1.pdf")
      declared = OmbudsmanManifestation.where(channel: "web", identification_mode: "identified").find { |m| m.manifestant_name.present? }
      expect(declared).to be_present
    end
  end

  it "cobre a identidade preservada para o ouvidor abrir, sem abrir por ele" do
    seed
    preserved = OmbudsmanManifestation.find_by!(identification_mode: "preserved", state: "awaiting_complement")

    aggregate_failures do
      expect(preserved.citizen_id).to be_present
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      opened = Ombudsman::ViewIdentity.call(manifestation_id: preserved.id, justification: "Conferir a identidade para contato.", by: user("ouvidor@curitiba.dev"))
      expect(opened.failure?).to be(false)
      expect(opened.payload[:identity][:name]).to be_present
    end
  end

  it "tem dado suficiente para o painel mostrar números e deixa o relatório de 2025 em rascunho" do
    seed
    panel = Ombudsman::Panel.call(from: 1.year.ago.to_date, to: Time.zone.today, today: Time.zone.today)
    report = OmbudsmanAnnualReport.find_by!(year: 2025)

    aggregate_failures do
      expect(panel[:total]).to be >= 40
      expect(panel[:by_state][:answered]).to be_a(Integer)
      expect(panel[:by_kind].values_at(:complaint, :praise, :report, :suggestion, :request)).to all(be_a(Integer))
      expect(panel[:by_channel].values_at(:web, :phone, :in_person, :ouvidorsus)).to all(be_a(Integer))
      expect(panel[:satisfaction][:responses]).to be >= 5
      expect(report.state).to eq("draft")
      expect(report.recurring_problems).to be_present
    end
  end

  it "é idempotente: duas execuções não duplicam nada" do
    seed
    before = counts
    result = seed

    expect(counts).to eq(before)
    expect(result[:switch]).to eq("ligado (ombudsman e ombudsman_anonymous_web)")
  end

  it "só imprime e-mail, papel e otpauth: nunca protocolo, texto nem nome" do
    result = seed
    lines = described_class.summary_lines(result, password: "dev-password").join("\n")
    secrets = OmbudsmanManifestation.all.flat_map { |m| [ m.protocol, m.body, m.manifestant_name ].compact } +
              Citizen.all.map(&:full_name).compact + CareLinesCrew::PEOPLE.values.map { |p| p[:name] }

    aggregate_failures do
      expect(lines).to include("ouvidor@curitiba.dev (ombudsman)", "ouvidoria@curitiba.dev (ombudsman_staff)",
                               "farmacia.resp@curitiba.dev (ombudsman_responder)", "ubs.resp@curitiba.dev (ombudsman_responder)", "otpauth://")
      secrets.each { |secret| expect(lines).not_to include(secret) }
    end
  end

  it "não semeia fora de Curitiba" do
    result = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")

    expect(result[:users]).to eq([])
    expect(OmbudsmanManifestation.count).to eq(0)
    expect(Ombudsman::Gate.usable?(city)).to be(false)
  end
end
