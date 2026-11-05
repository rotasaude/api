require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/psychosocial_crew").to_s

# Semente de dev do módulo 31 (ADR 0049) no banco de teste (nunca no de dev),
# com o mínimo do elenco anterior: o admin, a recepção, a UBS Jardim das Flores
# com a equipe da ESF, o IBGE da cidade e a CID-10 de dev. Cada exemplo prova o
# que a prova no navegador precisa achar sem preparo manual. Idempotente; a
# saída nunca leva CPF, CNS, nome nem CID de paciente.
RSpec.describe PsychosocialCrew do
  let!(:city) { clinical_city! }
  let(:today) { Time.zone.today }
  let(:caps_ii) { HealthUnit.find_by!(name: "CAPS II Boa Vista") }
  let(:caps_ad) { HealthUnit.find_by!(name: "CAPS AD III Centro Vida") }
  let(:ubs) { HealthUnit.find_by!(name: CareLinesCrew::UNIT) }

  before do
    cnes_city!
    create_default_protocol!
    staff_with("admin@curitiba.demo", "municipal_admin")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
    unit = create_unit(CareLinesCrew::UNIT, cnes: "2345678")
    HealthTeam.create!(health_unit: unit, kind: "70", name: "ESF JARDIM DAS FLORES", ine: "0000000070")
    ClinicalRecordCrew.seed_platform!
    described_class.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.dev")

  def patient(key) = Patient.find_by!(cpf: described_class.cpf_for("curitiba", key))

  def enrollment(key) = PsychosocialEnrollment.find_by!(patient_id: patient(key).id)

  def counts
    [ HealthUnit.count, PsychosocialBed.count, PsychosocialGroup.count, PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count,
      PsychosocialCarePlan.count, PsychosocialAction.count, PsychosocialActionParticipant.count, PsychosocialNightStay.count,
      PsychosocialMatrixSupport.count, PsychosocialMatrixCase.count, User.count, Membership.count, Professional.count,
      ProfessionalLink.count, Citizen.count, Patient.count, CnesProfessionalBond.count, CityFeature.count,
      SigtapProcedure.count, Cid10Code.count ]
  end

  it "liga o interruptor (com o prontuário) e cria os dois CAPS com modalidade, classificação, CNES e telefone" do
    result = seed

    aggregate_failures do
      expect(result[:switch]).to eq("ligado (psychosocial_care)")
      expect(Psychosocial::Gate.usable?(city)).to be(true)
      expect(Platform::Features.usable?(city, "clinical_record")).to be(true)
      expect(HealthUnit.where(kind: "caps").pluck(:name, :caps_modality, :service_classification).sort)
        .to eq([ [ "CAPS AD III Centro Vida", "caps_ad_iii", "001" ], [ "CAPS II Boa Vista", "caps_ii", "001" ] ])
      expect(HealthUnit.where(kind: "caps").pluck(:cnes)).to all(match(/\A\d{7}\z/))
      expect(HealthUnit.where(kind: "caps").pluck(:phone)).to all(match(/\A\d{10,11}\z/)) # P27
      expect(caps_ad).to be_night_capable
    end
  end

  it "o CAPS AD III tem os leitos L1 a L4 e o CAPS II nenhum" do
    seed

    aggregate_failures do
      expect(PsychosocialBed.where(health_unit_id: caps_ad.id).order(:label).pluck(:label, :active))
        .to eq([ [ "L1", true ], [ "L2", true ], [ "L3", true ], [ "L4", true ] ])
      expect(PsychosocialBed.where(health_unit_id: caps_ii.id)).to be_empty
    end
  end

  it "os quatro profissionais têm papel, TOTP fixo, conselho coerente, CNS válido e a lotação nos CAPS" do
    result = seed
    expected = {
      "caps" => [ %w[psychosocial_lead psychosocial_staff], "COREN", { caps_ii => "223505", caps_ad => "223505" } ],
      "capsmed" => [ %w[psychosocial_staff], "CRM", { caps_ii => "225133", caps_ad => "225133" } ],
      "capspsi" => [ %w[psychosocial_staff], "CRP", { caps_ii => "251510" } ],
      "capstec" => [ %w[psychosocial_staff], "COREN", { caps_ad => "322205" } ]
    }

    aggregate_failures do
      expected.each do |prefix, (roles, council, links)|
        account = user(prefix)
        expect(account.memberships.active.pluck(:role)).to match_array(roles)
        expect(account.mfa_enrolled?).to be(true)
        expect(account.has_role?("health_professional")).to be(false)
        expect(DomainEvent.where(name: "professional.created").count).to be >= 4
        expect(account.professional.council).to eq(council)
        expect(Professionals::Cns.valid?(account.professional.cns)).to be(true)
        expect(account.professional.links.active.to_h { |link| [ link.health_unit, link.cbo_code ] }).to eq(links)
        links.each_key { |unit| expect(Psychosocial::Access.link(account, unit.id)).to be_present }
      end
      expect(result[:users].to_h { |u| [ u[:email], u[:role] ] })
        .to eq("caps@curitiba.dev" => "psychosocial_lead", "capsmed@curitiba.dev" => "psychosocial_staff",
               "capspsi@curitiba.dev" => "psychosocial_staff", "capstec@curitiba.dev" => "psychosocial_staff")
      expect(result[:users].map { |u| u[:otpauth_uri] }).to all(start_with("otpauth://totp/"))
    end
  end

  it "os quatro segredos TOTP têm 32 caracteres em base32 estrito e geram um código válido" do
    seed

    aggregate_failures do
      %w[caps capsmed capspsi capstec].each do |prefix|
        secret = user(prefix).otp_secret
        expect(secret).to match(/\A[A-Z2-7]{32}\z/)
        totp = ROTP::TOTP.new(secret)
        code = totp.now
        expect(code).to match(/\A\d{6}\z/)
        expect(totp.verify(code)).to be_truthy
      end
      expect(described_class::STAFF.values.map { |spec| spec[:default_secret] }.uniq.size).to eq(4)
    end
  end

  it "nenhum telefone da semente coincide com o de outra crew" do
    mine = described_class::PHONE_PREFIX
    sources = Dir[Rails.root.join("lib/*_crew.rb")].reject { |path| path.end_with?("psychosocial_crew.rb") }
    others = sources.flat_map do |path|
      text = File.read(path)
      text.scan(/PHONE_PREFIX\s*=\s*"(\d{5})"/).flatten + text.scan(/%s(\d{5})%04d/).flatten
    end.uniq
    fixed = File.read(Rails.root.join("db/seeds.rb")).scan(/\+55#\{ddd\}(\d{5})\d{4}/).flatten

    aggregate_failures do
      expect(others).to include("91111", "96666", "97777", "98888") # a varredura enxerga os formatos das outras
      expect(others + fixed).not_to include(mine)
      seed
      phones = Citizen.pluck(:phone)
      mine_phones = Patient.where.not(id: nil).filter_map { |p| Citizen.find_by(patient_id: p.id)&.phone }
      expect(mine_phones.size).to eq(4)
      expect(mine_phones).to all(match(/\A\+55\d{2}#{mine}\d{4}\z/))
      expect(phones.uniq.size).to eq(phones.size)
    end
  end

  it "o retrato do CNES da cidade tem o vínculo (CNES, CBO e CNS) de cada profissional em cada CAPS" do
    seed
    snapshot = CnesSnapshot.where(ibge_code: "4106902").order(competence: :desc).first
    bonds = snapshot.bonds.map { |bond| [ bond.cnes, bond.cbo_code, bond.cns ] }

    aggregate_failures do
      { "caps" => [ caps_ii, caps_ad ], "capsmed" => [ caps_ii, caps_ad ], "capspsi" => [ caps_ii ], "capstec" => [ caps_ad ] }.each do |prefix, units|
        professional = user(prefix).professional
        units.each do |unit|
          cbo = professional.links.active.find_by!(health_unit_id: unit.id).cbo_code
          expect(bonds).to include([ unit.cnes, cbo, professional.cns ])
        end
      end
    end
  end

  it "cria os quatro pacientes com CPF e CNS válidos, a matrícula no CAPS certo e o CID" do
    seed
    expected = { renato: [ caps_ii, "F200", %w[99] ], luciana: [ caps_ii, "F321", %w[99] ],
                 marcos: [ caps_ad, "F102", %w[01] ], patricia: [ caps_ad, "F142", %w[02 04] ] }

    aggregate_failures do
      expect(Patient.count).to eq(4)
      expected.each do |key, (unit, cid, substances)|
        current = patient(key)
        expect(CitizenIdentity::Cpf.normalize(current.cpf)).to eq(current.cpf)
        expect(Professionals::Cns.valid?(current.cns)).to be(true)
        expect(current.race_color).to be_present
        enrolled = enrollment(key)
        expect(enrolled).to have_attributes(health_unit_id: unit.id, cid_main: cid, substances: substances)
        expect(enrolled).to be_open
      end
      expect(patient(:renato).full_name).to eq("Renato Alves Pereira")
    end
  end

  it "o Renato tem o PTS em dia e a Luciana o PTS vencido há 10 dias; o Marcos tem o dele e a Patrícia ainda não" do
    seed
    renato = PsychosocialCarePlan.find_by!(psychosocial_enrollment_id: enrollment(:renato).id)
    luciana = PsychosocialCarePlan.find_by!(psychosocial_enrollment_id: enrollment(:luciana).id)
    due = Psychosocial::CarePlanReview.due(unit: caps_ii, today: today).map { |enrolled, _| enrolled.id }

    aggregate_failures do
      expect(renato).to have_attributes(version: 1, review_on: today + 60, intensity: "semi_intensive")
      expect(luciana).to have_attributes(version: 1, review_on: today - 10)
      expect(PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollment(:marcos).id).count).to eq(1)
      expect(PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollment(:patricia).id)).to be_empty
      expect(due).to eq([ enrollment(:luciana).id ])
    end
  end

  it "o Marcos está na permanência aberta do leito L2, dentro do limite" do
    seed
    stay = PsychosocialNightStay.open_stays.sole

    aggregate_failures do
      expect(stay.psychosocial_bed.label).to eq("L2")
      expect(stay.health_unit_id).to eq(caps_ad.id)
      expect(stay.psychosocial_enrollment_id).to eq(enrollment(:marcos).id)
      expect(stay.started_at).to be < Time.current
      expect(stay.expected_end_at).to be > Time.current
      expect(stay.reassessment_reason).to be_nil
    end
  end

  it "as duas grades de grupo estão no CAPS II e a oficina teve uma sessão com o Renato e a Luciana" do
    seed
    workshop = PsychosocialGroup.find_by!(name: "Oficina de artesanato")
    assembly = PsychosocialGroup.find_by!(name: "Assembleia de usuários")
    session = PsychosocialAction.find_by!(psychosocial_group_id: workshop.id)

    aggregate_failures do
      expect(PsychosocialGroup.pluck(:health_unit_id).uniq).to eq([ caps_ii.id ])
      expect(workshop).to have_attributes(weekday: 3, kind: "workshop", sigtap_code: "0301080216", active: true)
      expect(workshop.starts_at.strftime("%H:%M")).to eq("14:00")
      expect(workshop.ends_at.strftime("%H:%M")).to eq("16:00")
      expect(assembly).to have_attributes(weekday: 5, kind: "assembly", active: true)
      expect(assembly.starts_at.strftime("%H:%M")).to eq("10:00")
      expect(session.performed_at.in_time_zone.wday).to eq(3)
      expect(session.performed_at).to be < Time.current
      expect(session.psychosocial_action_participants.pluck(:psychosocial_enrollment_id))
        .to match_array([ enrollment(:renato).id, enrollment(:luciana).id ])
      expect(session).to have_attributes(instrument: "raas_psi", cancelled_at: nil)
    end
  end

  it "o matriciamento de hoje com a ESF da UBS leva o caso compartilhado do Renato" do
    seed
    support = PsychosocialMatrixSupport.sole

    aggregate_failures do
      expect(support).to have_attributes(health_unit_id: caps_ii.id, held_on: today, sigtap_code: "0301080305")
      expect(support.health_team.health_unit_id).to eq(ubs.id)
      expect(support.psychosocial_action).to have_attributes(instrument: "bpa_c", place: "territory", origin: "matrix_support")
      expect(PsychosocialMatrixCase.where(psychosocial_matrix_support_id: support.id).pluck(:patient_id)).to eq([ patient(:renato).id ])
    end
  end

  it "o mês corrente do CAPS II sai sem pendência e sem aviso para o Renato (e para a Luciana)" do
    seed
    month = Psychosocial::MonthProblems.for(health_unit: caps_ii, month: today.beginning_of_month)
    by_patient = month[:records].to_h { |entry| [ entry[:patient].id, entry ] }

    aggregate_failures do
      expect(by_patient.keys).to match_array([ patient(:renato).id, patient(:luciana).id ])
      expect(by_patient.fetch(patient(:renato).id)).to include(problems: [], warnings: [])
      expect(by_patient.fetch(patient(:luciana).id)).to include(problems: [], warnings: [])
    end
  end

  it "no AD III, só a permanência aberta do Marcos pesa no mês (o fechamento a cobra)" do
    seed
    month = Psychosocial::MonthProblems.for(health_unit: caps_ad, month: today.beginning_of_month)
    by_patient = month[:records].to_h { |entry| [ entry[:patient].id, entry[:problems] ] }

    expect(by_patient).to eq(patient(:marcos).id => %w[night_stay_open], patient(:patricia).id => [])
  end

  it "duas rodadas dão as mesmas contagens" do
    seed
    first = counts
    second = seed

    aggregate_failures do
      expect(counts).to eq(first)
      expect(second[:units]).to eq([ "CAPS II Boa Vista", "CAPS AD III Centro Vida" ])
      expect(second).to include(beds: 4, groups: 2, enrollments: 4, care_plans: 3, night_stays: 1, matrix_supports: 1)
    end
  end

  it "a plataforma também é idempotente (SIGTAP e CID-10 já completos)" do
    expect(described_class.seed_platform!).to eq(sigtap: :complete, cid10: :complete)
  end

  it "não recria o que a coordenação encerrou na prova" do
    seed
    stay = PsychosocialNightStay.open_stays.sole
    closed = Psychosocial::CloseNightStay.call(stay: stay, ended_at: (Time.current - 1.hour).iso8601, reason: "Alta do acolhimento noturno na prova.",
                                               by: user("capstec"), link: Psychosocial::Access.link(user("capstec"), caps_ad.id))
    expect(closed).to be_ok
    first = counts
    seed

    expect(counts).to eq(first)
  end

  it "a saída leva só e-mail, papel e otpauth: nunca CPF, CNS, nome nem CID de paciente" do
    result = seed
    text = described_class.summary_lines(result, password: "dev-password").join("\n")
    secrets = Patient.all.flat_map { |current| [ current.cpf, current.cns, current.full_name ] }.compact + PsychosocialEnrollment.pluck(:cid_main)

    aggregate_failures do
      expect(secrets).not_to be_empty
      secrets.each { |secret| expect(text).not_to include(secret) }
      expect(text).not_to match(/\b\d{11}\b/)
      expect(text).to include("caps@curitiba.dev (psychosocial_lead)")
    end
  end

  it "fora de Curitiba não semeia nada" do
    result = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")

    aggregate_failures do
      expect(result).to include(switch: "fora", units: [], users: [])
      expect(HealthUnit.where(kind: "caps")).to be_empty
    end
  end

  it "SIGTAP sem os procedimentos do CAPS: avisa, desliga a crew e não levanta (não interrompe o db:seed)" do
    stub_const("SigtapSample::PSYCHOSOCIAL_CODES", SigtapSample::PSYCHOSOCIAL_CODES + [ "0399999999" ])
    competences = [ today << 1, today ].map { |day| day.strftime("%Y%m") }
    result = nil

    expect { result = seed }.to output(/importe a competência #{competences.join(' e ')}/).to_stderr
    aggregate_failures do
      expect(result).to include(units: [], users: [])
      expect(result[:switch]).to match(/\Adesligado \(SIGTAP sem os procedimentos do CAPS — importe a competência #{competences.join(' e ')}\)\z/)
      expect(HealthUnit.where(kind: "caps")).to be_empty
      expect(Psychosocial::Gate.enabled?(city)).to be(false)
    end
  end

  it "exige as duas competências: só a anterior faltando também desliga, apontando-a" do
    previous = (today << 1).strftime("%Y%m")
    allow(TerminologyRelease).to receive(:active).and_wrap_original do |original|
      relation = original.call
      allow(relation).to receive(:find_by).and_wrap_original do |find, **conditions|
        conditions[:version] == previous ? nil : find.call(**conditions)
      end
      relation
    end
    result = nil

    expect { result = seed }.to output(/importe a competência #{previous}\b(?! e)/).to_stderr
    expect(result[:switch]).to include("importe a competência #{previous})")
    expect(HealthUnit.where(kind: "caps")).to be_empty
  end

  it "CID-10 sem qualquer das quatro chaves da crew: avisa e desliga, sem levantar" do
    allow(ClinicalTerms).to receive(:find).and_call_original
    allow(ClinicalTerms).to receive(:find).with("cid10", "F142").and_return(nil)
    result = nil

    expect { result = seed }.to output(/CID-10 sem F142/).to_stderr
    expect(result[:switch]).to start_with("desligado (CID-10 sem F142")
    expect(HealthUnit.where(kind: "caps")).to be_empty
  end

  it "recusa rodar em ambiente implantado" do
    allow(Rota).to receive(:deployed?).and_return(true)

    expect { seed }.to raise_error(/só de dev/)
  end

  it "sem a UBS do CareLinesCrew, para com a mensagem de pré-requisito" do
    allow(HealthUnit).to receive(:find_by).and_call_original
    allow(HealthUnit).to receive(:find_by).with(name: CareLinesCrew::UNIT).and_return(nil)

    expect { seed }.to raise_error(/CareLinesCrew/)
  end
end
