require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/exam_crew").to_s

# Semente do módulo 21a no banco de teste (nunca no de dev). Dev é fictício
# mas imita o real: SIGTAP reais, LOINC reais, prestadores coerentes,
# anti-HIV e anatomopatológico sem laudo no wpda, o laboratório simulado
# com o token do compose. Idempotente.
RSpec.describe ExamCrew do
  let!(:city) { clinical_city!(record_mode: "record", enabled: true) }
  let(:slug) { city.slug }

  before do
    create_default_protocol!
    admin = staff_with("admin@#{slug}.demo", "municipal_admin")
    SignatureCrew.seed_current_city(slug: slug, password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: slug, password: "dev-password", admin: admin)
    ScreeningCrew.seed_platform!
    ScreeningCrew.seed_current_city(slug: slug, ddd: "41")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  after { Current.reset }

  it "SIGTAP com os quatro exames; catálogo, prestadores, usuários e pedidos de exemplo; duas vezes = mesma coisa" do
    expect(described_class.seed_platform![:sigtap]).to eq(Time.zone.today.strftime("%Y%m"))
    %w[0202020380 0202010503 0202030300 0203020030].each do |code|
      expect(ClinicalTerms::SigtapExams.find(code, on: Time.zone.today)).to be_present, code
    end
    2.times { described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password") }
    expect(Exams::Gate.usable?(city)).to be(true)
    expect(ExamCatalogItem.pluck(:sigtap_code, :release_policy, :requires_authorization)).to contain_exactly(
      [ "0202020380", "immediate", false ], [ "0202010503", "after_acknowledgement", false ],
      [ "0202030300", "never_citizen", false ], [ "0203020030", "never_citizen", true ])
    expect(ExamCatalogItem.find_by(sigtap_code: "0202010503").result_fields.first["loinc"]).to eq("4548-4")
    simulated = ExamProvider.find_by!(name: "Laboratório Simulado")
    expect(simulated).to have_attributes(simulated: true, fhir_token_digest: Digest::SHA256.hexdigest(ExamCrew::DEFAULT_FAKE_LAB_TOKEN))
    expect(ExamProvider.where(simulated: false).count).to eq(2)
    lab = User.find_by!(email_address: "laboratorio@#{slug}.demo")
    expect(lab.has_role?("exam_provider")).to be(true)
    expect(ExamProviderUser.find_by(user: lab).exam_provider.name).to eq("Laboratório Municipal Central")
    expect(User.find_by!(email_address: "regulacao@#{slug}.demo").has_role?("exam_regulator")).to be(true)
    expect(ExamOrder.where("external_reference LIKE 'SEED-%'").pluck(:status)).to contain_exactly("scheduled", "awaiting_authorization", "scheduled")
    expect(ExamOrder.find_by(external_reference: "SEED-3").overdue).to include(stage: "collect")
    expect(ExamOrder.find_by(external_reference: "SEED-1").exam_provider).to eq(simulated)
  end

  it "equipe de referência de dev na unidade das guias, com a enfermeira: a fila da equipe tem a quem chegar" do
    described_class.seed_platform!
    2.times { described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password") }
    unit = HealthUnit.find_by!(name: ClinicalRecordCrew::UNIT)
    nurse = User.find_by!(email_address: "enfermeira@#{slug}.demo")
    expect(HealthTeam.where(health_unit: unit, active: true).count).to eq(1)
    expect(Exams::Access.team_unit_ids(nurse)).to eq([ unit.id ])
    expect(HealthTeamMember.active.where(professional: nurse.professional).count).to eq(1)
  end

  it "idempotente: a segunda rodada não cria nada; a competência da guia antiga é a corrente, mesmo sem release para 40 dias atrás" do
    described_class.seed_platform!
    described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password")
    counts = -> { [ ExamOrder, ExamOrderEvent, ExamFile, ExamProvider, ExamProviderItem, ExamCatalogItem, ExamProviderUser, User, Membership ].map(&:count) }
    before_counts = counts.call
    again = described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password")
    expect(again[:orders]).to eq(0)
    expect(counts.call).to eq(before_counts)
    expect(described_class.seed_platform!).to eq(sigtap: Time.zone.today.strftime("%Y%m"), republished: false, status: :complete)
    expect(ExamOrder.find_by(external_reference: "SEED-3").sigtap_competence).to eq(Time.zone.today.strftime("%Y%m"))
  end

  it "liga os interruptores da cidade de registro e nunca imprime o token" do
    result = described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password")
    expect(result[:switch]).to eq("exam_tracking, exam_fhir_inbound, fake_lab")
    expect(result.to_s).not_to include(described_class::DEFAULT_FAKE_LAB_TOKEN)
  end

  it "sem o mantenedor de dev não liga nem cria nada" do
    Maintainer.where(email_address: "dev@local").destroy_all
    expect(described_class.seed_current_city(slug: slug, ddd: "41", password: "dev-password")[:switch]).to start_with("desligado")
    expect(ExamCatalogItem.count).to eq(0)
  end

  describe "seed_platform! guards" do
    let(:competence) { Time.zone.today.strftime("%Y%m") }

    def active_release_without_exams!(procedures:)
      TerminologyRelease.where(kind: "sigtap").update_all(status: "superseded")
      release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "a" * 64, imported_by: "db:seed",
                                           imported_at: Time.current, status: "importing")
      procedures.times do |n|
        SigtapProcedure.create!(release_id: release.id, code: format("03%08d", n), name: "PROC #{n}", complexity: "1", sex: "I",
                                age_min_months: 0, age_max_months: 9999)
      end
      release.update!(status: "active", activated_at: Time.current)
      release
    end

    it "release de dev (recorte) sem os quatro exames: republica" do
      active_release_without_exams!(procedures: SigtapSample::PROCEDURES.size - 4)
      expect(described_class.seed_platform!).to eq(sigtap: competence, republished: true, status: :republished)
    end

    it "release real (grande) sem os quatro exames: não toca em nada" do
      release = active_release_without_exams!(procedures: SigtapSample::PROCEDURES.size + 1)
      expect(described_class.seed_platform!).to eq(sigtap: competence, republished: false, status: :real_sigtap)
      expect(release.reload.status).to eq("active")
      expect(TerminologyRelease.where(kind: "sigtap", version: competence).count).to eq(1)
    end

    it "release real de competência ANTERIOR ativa: não importa o recorte, não cria release, devolve o motivo" do
      previous = (Time.zone.today.beginning_of_month - 1.day).strftime("%Y%m")
      TerminologyRelease.where(kind: "sigtap").update_all(status: "superseded")
      real = TerminologyRelease.create!(kind: "sigtap", version: previous, source_sha256: "b" * 64, imported_by: "terminology:import",
                                        imported_at: Time.current, status: "importing")
      (SigtapSample::PROCEDURES.size + 1).times do |n|
        SigtapProcedure.create!(release_id: real.id, code: format("03%08d", n), name: "PROC #{n}", complexity: "1", sex: "I",
                                age_min_months: 0, age_max_months: 9999)
      end
      real.update!(status: "active", activated_at: Time.current)
      expect { @result = described_class.seed_platform! }.not_to change(TerminologyRelease, :count)
      expect(@result).to eq(sigtap: competence, republished: false, status: :real_sigtap)
      expect(real.reload.status).to eq("active")
    end

    it "em ambiente implantado recusa as duas entradas" do
      allow(Rota).to receive(:deployed?).and_return(true)
      expect { described_class.seed_platform! }.to raise_error(/implantado/)
      expect { described_class.seed_current_city(slug: slug, ddd: "41", password: "x") }.to raise_error(/implantado/)
    end
  end
end
