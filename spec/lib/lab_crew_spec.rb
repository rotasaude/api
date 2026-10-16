require "rails_helper"
require Rails.root.join("lib/lab_crew").to_s

# Semente de dev (ADR 0037; dev imita o real): laboratório municipal de
# Curitiba uses_municipal_lab com endereço e telefone; UBS que coleta e UBS
# que não; catálogo adotado com códigos de aparelho e críticos; motivos;
# RT biomédica (CRBM), médico substituto (CRM, CPF válido, só ICP); técnica;
# token do middleware simulado. Idempotente. Nunca imprime o token.
RSpec.describe LabCrew do
  before do
    lab_city!(fake_middleware: true)
    Lab::Templates::Load.sigtap_codes.each { |c| SigtapProcedure.find_or_create_by!(release: sigtap_release!, code: c) { |p| p.name = "EXAME #{c}" } }
    Maintainer.find_by(email_address: "dev@local") ||
      Maintainer.create!(email_address: "dev@local", password: "dev-password-123", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    ExamProvider.create!(name: LabCrew::LAB, kind: "municipal", cnes: "2385123")
    %w[UBS\ Jardim\ das\ Flores UBS\ Vila\ Esperança].each { |name| HealthUnit.find_or_create_by!(name: name) { |u| u.kind = "ubs" } }
  end

  it "monta o laboratório, a equipe e o catálogo; segunda rodada não duplica" do
    described_class.seed_platform!
    result = described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    lab = ExamProvider.find_by!(name: LabCrew::LAB)
    expect(lab).to have_attributes(uses_municipal_lab: true, phone: "4133501200")
    expect(HealthUnit.find_by!(name: "UBS Jardim das Flores").collects_samples).to be(true)
    expect(HealthUnit.find_by!(name: "UBS Vila Esperança").collects_samples).to be(false)
    glucose = LabExam.find_by!(exam_provider: lab, sigtap_code: "0202010473")
    expect(glucose.current_version).to have_attributes(version: 2, instrument_test_code: "GLI")
    expect(glucose.current_version.analyte("glicose")).to include("critical_high" => 400.0, "entry_max" => 1500.0)
    expect(LabExam.where(exam_provider: lab).count).to eq(16)
    expect(LabRejectionReason.where(exam_provider: lab).count).to eq(6)
    bio = User.find_by!(email_address: "biomedica@curitiba.demo")
    doctor = User.find_by!(email_address: "patologista@curitiba.demo")
    expect(bio.professional.council).to eq("CRBM")
    expect(LabReleaser.active.find_by!(user: bio)).to have_attributes(technical_lead: true)
    expect(LabReleaser.active.find_by!(user: doctor)).to have_attributes(technical_deputy: true)
    expect(CitizenIdentity::Cpf.normalize(doctor.professional.cpf)).to be_present
    expect(User.find_by!(email_address: "tecnica-lab@curitiba.demo").has_role?("lab_staff")).to be(true)
    expect(LabMiddlewareToken.active.find_by!(exam_provider: lab)).to have_attributes(simulated: true,
      token_digest: LabMiddlewareToken.digest(LabCrew::DEFAULT_FAKE_MIDDLEWARE_TOKEN))
    expect(result[:users].map { |u| u[:email] }).to contain_exactly("tecnica-lab@curitiba.demo", "biomedica@curitiba.demo", "patologista@curitiba.demo")
    expect(result.to_s).not_to include(LabCrew::DEFAULT_FAKE_MIDDLEWARE_TOKEN)
    expect { described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!) }
      .not_to(change { [ LabExam.count, LabExamVersion.count, LabReleaser.count, LabMiddlewareToken.count, LabRejectionReason.count ] })
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", password: "x", admin: lab_admin!)[:switch]).to start_with("desligado")
  end

  it "instrument codes são os do fake-middleware, um RT e um substituto, e a segunda rodada não muda nada (B46)" do
    described_class.seed_platform!
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    lab = ExamProvider.find_by!(name: LabCrew::LAB)
    expect(LabCrew::INSTRUMENT_CODES.values).to match_array(%w[HEM GLI A1C COL HDL LDL TRI CRE URE TGO TGP TSH T4L HCG])
    expect(LabReleaser.active.where(exam_provider: lab, technical_lead: true).count).to eq(1)
    expect(LabReleaser.active.where(exam_provider: lab, technical_deputy: true).count).to eq(1)
    snapshot = lambda do
      [ lab.reload.attributes, User.where("email_address LIKE '%@curitiba.demo'").order(:id).map(&:attributes), LabExam.order(:id).map(&:attributes),
        LabExamVersion.order(:id).map(&:attributes), LabReleaser.order(:id).map(&:attributes), LabMiddlewareToken.order(:id).map(&:attributes),
        Membership.order(:id).map(&:attributes), HealthUnit.order(:id).map(&:attributes) ]
    end
    before = snapshot.call
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    expect(snapshot.call).to eq(before)
  end

  it "o portal do 21a (laboratorio@) não pertence ao laboratório municipal (E18)" do
    require Rails.root.join("lib/exam_crew").to_s
    ExamCrew.send(:catalog!)
    ExamCrew.send(:providers!)
    # Dev já semeado antes do E18: o usuário começa ligado ao municipal.
    old = User.create!(email_address: "laboratorio@curitiba.demo", password: "dev-password")
    ExamProviderUser.create!(user: old, exam_provider: ExamProvider.find_by!(name: LabCrew::LAB))
    ExamCrew.send(:ensure_user, ExamCrew::USERS.first, slug: "curitiba", password: "dev-password")
    portal = ExamProviderUser.find_by!(user: User.find_by!(email_address: "laboratorio@curitiba.demo"))
    expect(portal.exam_provider.name).to eq("Clínica Diagnóstica Credenciada")
    expect(portal.exam_provider.uses_municipal_lab).to be(false)
  end

  it "rerodada converge depois de falha no meio do exame, repara o CPF e liga o CBO real do biomédico" do
    described_class.seed_platform!
    calls = 0
    allow(Lab::CreateVersion).to receive(:call).and_wrap_original do |original, **kwargs|
      (calls += 1) == 3 ? Result.fail(:invalid_version) : original.call(**kwargs)
    end
    expect { described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!) }.to raise_error(/versão de/)
    lab = ExamProvider.find_by!(name: LabCrew::LAB)
    expect(LabExam.where(exam_provider: lab).count).to eq(2)
    result = described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    bio = User.find_by!(email_address: "biomedica@curitiba.demo")
    bio.professional.update!(cpf: nil)
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    expect(LabExam.where(exam_provider: lab).map { |e| e.current_version.version }.uniq).to eq([ 2 ])
    expect(LabExam.where(exam_provider: lab).count).to eq(16)
    expect(bio.reload.professional.cpf).to be_present
    expect(bio.professional.links.active.pluck(:cbo_code)).to eq([ "221205" ])
    expect(result[:switch]).not_to include("nada a fazer")
    expect(described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)[:switch]).to include("nada a fazer")
  end

  it "FAKE_MIDDLEWARE_TOKEN vazio cai no padrão" do
    described_class.seed_platform!
    stub_const("ENV", ENV.to_h.merge("FAKE_MIDDLEWARE_TOKEN" => ""))
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
    expect(LabMiddlewareToken.active.pick(:token_digest)).to eq(LabMiddlewareToken.digest(LabCrew::DEFAULT_FAKE_MIDDLEWARE_TOKEN))
  end
end
