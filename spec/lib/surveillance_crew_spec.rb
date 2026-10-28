require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/territory_registry_crew").to_s
require Rails.root.join("lib/surveillance_crew").to_s

# Semente de dev do módulo 25 no banco de teste (nunca no de dev), com o
# elenco na ordem do db/seeds.rb até o TerritoryRegistryCrew (de quem vêm a
# UBS, a médica, a recepção, as pessoas do 23 e a Benedito, sem CPF, do 24a) e
# a lista nacional carregada. Cada exemplo prova o que a prova no navegador
# precisa achar sem preparo manual. As semanas são relativas a hoje (W = a
# última semana completa; em 27/10/2026, SE 42/2026). Idempotente.
RSpec.describe SurveillanceCrew, type: :request do
  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  let(:today) { Time.zone.today }
  let(:last_week) { Surveillance::EpiWeek.current(today).pred }
  let(:ubs) { HealthUnit.find_by!(name: "UBS Jardim das Flores") }
  let(:vila) { HealthUnit.find_by!(name: "UBS Vila Esperança") }
  let(:upa) { HealthUnit.find_by!(name: "UPA 24h Centro") }
  let(:officer) { User.find_by!(email_address: "vigilancia@curitiba.demo") }

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
    (CityProfile.current || CityProfile.new).update!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    HealthUnit.find_by!(name: "UBS Jardim das Flores").update!(cnes: "2384299") if HealthUnit.find_by!(name: "UBS Jardim das Flores").cnes.blank?
    TerritoryRegistryCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    Surveillance::DiseaseList::Load.call
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def panel(disease: "dengue") = Surveillance::Panel.call(from: last_week - 4, to: last_week, disease: disease)

  def notification_of(patient, disease) = DiseaseNotification.where(patient_id: patient.id, disease_code: disease).order(:created_at).last

  it "o painel da semana W: sinal no Santa Felicidade (1, 1, 2, 1 e 6) e células suprimidas nos outros dois bairros" do
    seed
    rows = panel.fetch(:rows).to_h { |row| [ row[:neighborhood][:name], row ] }

    aggregate_failures do
      expect(panel.fetch(:weeks)).to eq(Surveillance::EpiWeek.between(last_week - 4, last_week).map(&:to_s))
      expect(rows.keys).to eq([ "Batel", "Boqueirão", "Santa Felicidade" ])
      # 1–4 vira nil, 0 continua 0; o 6 aparece e é sinal (6 > 2 × média 2,5 da base suprimida, K14).
      expect(rows.fetch("Santa Felicidade")).to include(counts: [ nil, nil, nil, nil, 6 ], signal: [ false, false, false, false, true ])
      expect(rows.fetch("Boqueirão")).to include(counts: [ 0, 0, 0, 0, nil ], signal: [ false ] * 5)
      expect(rows.fetch("Batel")).to include(counts: [ 0, 0, 0, 0, nil ], signal: [ false ] * 5)
      # 11 + 3 + 2 casos de dengue, nenhum deles em notified (venceria), mais a possível da rede de segurança (A90, na UBS).
      dengue = DiseaseNotification.where(disease_code: "dengue")
      expect(dengue.count).to eq(17)
      expect(dengue.group(:status).count).to eq("entered" => 7, "investigating" => 9, "possible" => 1)
      expect(dengue.group(:health_unit_id).count).to eq(ubs.id => 12, vila.id => 5)
    end
  end

  it "a fila: count = vencida 1 (o sarampo), imediata aberta 1, sem número 1 (a sífilis)" do
    result = seed

    aggregate_failures do
      expect(Surveillance::Queue.counts).to include(overdue: 1, immediate_open: 1, without_official_number: 1)
      expect(result[:queue]).to eq(Surveillance::Queue.counts)
      measles = DiseaseNotification.find_by!(disease_code: "sarampo")
      expect([ measles.status, measles.deadline, measles.overdue?, measles.created_at < 29.hours.ago ]).to eq([ "notified", "immediate", true, true ])
      expect(DiseaseNotification.overdue_at(Time.current).pluck(:disease_code)).to eq([ "sarampo" ])
      expect(DiseaseNotification.where(deadline: "immediate", status: Surveillance::Catalog::OPEN_STATUSES).pluck(:disease_code)).to eq([ "sarampo" ])

      closed = DiseaseNotification.where(status: "closed")
      expect(closed.pluck(:disease_code, :official_number, :classification)).to eq([ [ "sifilis_gestante", nil, "confirmed" ] ])
      expect(Surveillance::Queue.call(filters: { "without_official_number" => "true" }, limit: 10).payload[:rows].map(&:disease_code))
        .to eq([ "sifilis_gestante" ])
    end
  end

  it "o resto do cenário: tuberculose com ficha, hanseníase digitada com 7 dígitos, Benedito sem CPF e o residente de Londrina" do
    seed
    jose = Citizen.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :jose)).patient
    osvaldo = Citizen.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :osvaldo)).patient
    benedito = TerritoryRegistryCrew.patient_of("curitiba", :benedito)

    aggregate_failures do
      tuberculosis = notification_of(jose, "tuberculose")
      expect(tuberculosis.status).to eq("investigating")
      expect(tuberculosis.form).to include("schooling" => "4", "residence_zone" => "1", "pregnancy" => "6")
      expect(Surveillance::Form.validate(tuberculosis.form)).to be_ok

      leprosy = notification_of(osvaldo, "hanseniase")
      expect([ leprosy.status, leprosy.classification ]).to eq([ "entered", "confirmed" ])
      expect(leprosy.official_number).to match(/\A\d{7}\z/)
      expect(DiseaseNotification.where(status: "entered").where.not(disease_code: %w[dengue hanseniase])).to be_empty
      expect(DiseaseNotification.where(status: "entered", disease_code: "dengue").pluck(:official_number)).to all(match(/\A\d{7}\z/))

      # Paciente do 24a sem CPF (situação de rua), com a tuberculose notificada e ainda no prazo.
      expect(benedito.cpf).to be_nil
      pending_tb = notification_of(benedito, "tuberculose")
      expect([ pending_tb.status, pending_tb.overdue?, pending_tb.neighborhood_id ]).to eq([ "notified", false, nil ])

      # Residente em Londrina: manual, com a pessoa digitada e o IBGE de fora.
      away = DiseaseNotification.find_by!(disease_code: "hepatites_virais")
      expect([ away.resident_elsewhere, away.residence_ibge, away.origin, away.status, away.overdue? ]).to eq([ true, "4113700", "manual", "notified", false ])
      expect(away.patient.cpf).to eq(ScreeningCrew.send(:cpf_for, "curitiba:surveillance:londrina"))
      expect(away.form).not_to include("residence_uf")
    end
  end

  it "o recorte de dev ganha o A90 (e só ele) pela própria semente; a segunda rodada não publica outra release" do
    dev = ClinicalTerms.release("cid10")
    before_codes = Cid10Code.where(release_id: dev.id).pluck(:code, :description, :sex_restriction).sort
    expect(before_codes.map(&:first)).not_to include("A90")

    seed
    current = ClinicalTerms.release("cid10")
    aggregate_failures do
      expect([ current.version, current.status ]).to eq([ "dev-a90", "active" ])
      expect(Cid10Code.where(release_id: current.id).pluck(:code, :description, :sex_restriction).sort)
        .to eq((before_codes + [ [ "A90", "Dengue [dengue clássico]", nil ] ]).sort)
      expect(dev.reload.status).to eq("superseded")
    end
    expect { seed }.not_to(change { TerminologyRelease.where(kind: "cid10").count })
  end

  it "release real ativa sem A90: não é tocada; avisa, não semeia a possível e segue" do
    # Uma release real (não "dev-*") e sem A90 no lugar do recorte de dev.
    ClinicalTerms.release("cid10").update!(status: "superseded")
    real = TerminologyRelease.create!(kind: "cid10", version: "2026-real", source_sha256: "e" * 64, imported_by: "rspec",
                                      imported_at: Time.current, status: "importing")
    Cid10Code.create!(release: real, code: "I10", description: "Hipertensão essencial (primária)", sex_restriction: nil)
    real.update!(status: "active", activated_at: Time.current)
    result = nil
    expect { result = seed }.to output(/CID-10 A90 ausente/).to_stderr

    expect(TerminologyRelease.active.where(kind: "cid10").pluck(:version)).to eq([ "2026-real" ])
    expect(result).to include(safety_net: "sem A90 na CID-10 ativa (release real): não semeada")
    expect(DiseaseNotification.where(origin: "safety_net")).to be_empty
    expect(Consultation.where(author_user: User.find_by!(email_address: "profissional@curitiba.demo"))
                       .joins(:problem_items).where(problem_items: { code: "A90" })).to be_empty
    expect(Surveillance::Queue.counts).to include(possible: 0)
  end

  it "com o A90 semeado no recorte de dev: a possível nasce da consulta finalizada da médica da UBS, sem notificador, e não entra no painel" do
    result = seed
    possible = DiseaseNotification.find_by!(origin: "safety_net")

    aggregate_failures do
      expect(result).to include(safety_net: "possível pela consulta com A90")
      expect([ possible.status, possible.disease_code, possible.notifier_user_id, possible.health_unit_id ]).to eq([ "possible", "dengue", nil, ubs.id ])
      consultation = possible.consultation
      expect([ consultation.status, consultation.author_user.email_address ]).to eq([ "finalized", "profissional@curitiba.demo" ])
      expect(consultation.problem_items.pluck(:terminology, :code, :action)).to eq([ %w[cid10 A90 add] ])
      expect(Surveillance::Queue.counts).to include(possible: 1, overdue: 1, immediate_open: 1, without_official_number: 1)
      # Possível não conta no painel: a linha do Santa Felicidade segue como estava.
      santa = panel.fetch(:rows).find { |row| row[:neighborhood][:name] == "Santa Felicidade" }
      expect(santa[:counts]).to eq([ nil, nil, nil, nil, 6 ])
      expect(Surveillance::PatientNeighborhood.for(possible.patient)).to eq(possible.neighborhood_id)
      expect(possible.neighborhood.name).to eq("Santa Felicidade")
    end
  end

  it "as negativas da semana W: a UBS Jardim das Flores com caso, a Vila Esperança com negativa e a UPA pendente" do
    seed

    aggregate_failures do
      expect(Surveillance::WeekCases.unit_ids_with_cases(last_week)).to eq(Set[ubs.id])
      expect(WeeklyNegativeReport.pluck(:health_unit_id, :week)).to eq([ [ vila.id, last_week.to_s ] ])
      expect(Surveillance::WeekCases.pending_units(last_week).map(&:name)).to eq([ "UPA 24h Centro" ])
      expect(HealthUnit.where(notifying: true).order(:name).pluck(:name)).to eq([ "UBS Jardim das Flores", "UBS Vila Esperança", "UPA 24h Centro" ])
    end
  end

  it "a vigilante: papel surveillance, TOTP fixo, doença local de dev sem colidir com a lista nacional" do
    result = seed

    aggregate_failures do
      expect(result).to include(switch: "ligado (surveillance)", local_disease: "local_agravo_dev_pr")
      expect(Surveillance::Gate.usable?(Current.city)).to be(true)
      expect(officer).to be_mfa_enrolled
      expect(officer.has_role?("surveillance")).to be(true)
      expect(officer.otp_secret).to eq("VIGILANCIAEPIDEMIOLOGICASEMENTE2")
      expect(result[:users]).to eq([ { email: "vigilancia@curitiba.demo", role: "surveillance", otpauth_uri: SignatureCrew.otpauth_uri(officer) } ])

      local = Surveillance::Diseases.find("local_agravo_dev_pr")
      expect([ local.name, local.deadline, local.cid10, local.local ]).to eq([ "Agravo estadual (exemplo de dev)", "weekly", [ "R17" ], true ])
      # K13(d): fora da lista nacional (prefixo dos dois lados) e sem o X22 do escorpionismo.
      national = Surveillance::Diseases.platform.flat_map(&:cid10)
      expect(national.none? { |code| code.start_with?("R17") || "R17".start_with?(code) }).to be(true)
      expect(national).to include("X22")
      expect(local.cid10).not_to include("X22")
    end
  end

  it "telefones: toda pessoa nova da semente tem celular +55 41 96666-NNNN a partir de 2600" do
    seed
    citizens = (0..described_class::SAFETY_NET_INDEX).map { |index| Citizen.find_by!(cpf: described_class.cpf_for("curitiba", index)) }

    expect(citizens.map(&:phone)).to eq((0..described_class::SAFETY_NET_INDEX).map { |index| format("+554196666%04d", 2600 + index) })
    expect(citizens).to all(be_verification_level_verified)
    expect(citizens.map(&:cpf)).to all(satisfy { |cpf| CitizenIdentity::Cpf.normalize(cpf) })
    # Nenhum número de pessoa da semente fora do prefixo (a de Londrina e a Benedito não têm telefone).
    expect(Citizen.where(cpf: citizens.map(&:cpf)).pluck(:phone)).to all(start_with("+5541#{described_class::PHONE_PREFIX}"))
  end

  it "o neighborhood do paciente sai do par validado (sem cadastro territorial) e o painel nunca mistura dengue com o resto" do
    seed
    sarampo = DiseaseNotification.find_by!(disease_code: "sarampo")

    expect(sarampo.neighborhood.name).to eq("Centro")
    all_diseases = Surveillance::Panel.call(from: last_week - 4, to: last_week).fetch(:rows)
    santa = all_diseases.find { |row| row[:neighborhood][:name] == "Santa Felicidade" }
    expect(santa[:counts].last).to eq(6)
  end

  it "a segunda rodada não muda nada (com a possível da rede de segurança)" do
    first = seed
    tables = [ User, Membership, Citizen, Patient, DiseaseNotification, DiseaseNotificationEvent, WeeklyNegativeReport, LocalNotifiableDisease,
               Consultation, Attendance, HealthUnit, DomainEvent, CityFeature, PlatformEvent ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
    expect(first[:notifications]).to eq(DiseaseNotification.count)
  end

  it "a possível descartada não é recriada por uma nova rodada" do
    seed
    possible = DiseaseNotification.find_by!(origin: "safety_net")
    dismissed = Surveillance::Dismiss.call(notification: possible, reason: "Não é caso", version: possible.version, by: officer)
    expect(dismissed).to be_ok

    expect { seed }.not_to(change { DiseaseNotification.count })
    expect(DiseaseNotification.where(origin: "safety_net").pluck(:status)).to eq([ "dismissed" ])
  end

  it "login de dev: a vigilante entra e lê os contadores da fila" do
    seed
    json_post "/session", email_address: "vigilancia@curitiba.demo", password: "dev-password"
    expect(response).to have_http_status(:created)

    get "/surveillance/notifications/count"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("overdue" => 1, "immediate_open" => 1, "without_official_number" => 1)
  end

  it "ambiente implantado: recusa" do
    allow(Rota).to receive(:deployed?).and_return(true)

    expect { seed }.to raise_error(/ambiente implantado; a semente é só de dev/)
    expect(DiseaseNotification.count).to eq(0)
  end

  it "sem a lista nacional carregada falha antes de ligar, dizendo o que rodar" do
    allow(Surveillance::Diseases).to receive(:platform).and_return([])

    expect { seed }.to raise_error(/lista nacional não carregada/)
    expect(Surveillance::Gate.enabled?(Current.city)).to be(false)
  end

  it "sem o mantenedor de dev não liga nada" do
    allow(Maintainer).to receive(:find_by).and_call_original
    allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
    result = nil
    expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
    expect(result).to include(switch: "desligado (sem mantenedor dev@local)", notifications: 0, users: [])
    expect(DiseaseNotification.count).to eq(0)
  end

  it "fora de Curitiba devolve desligado e não liga nada" do
    result = described_class.seed_current_city(slug: "maringa", ddd: "44")

    expect(result).to include(switch: "desligado (só Curitiba liga)", notifications: 0, negatives: 0)
    expect(DiseaseNotification.count).to eq(0)
    expect(Surveillance::Gate.enabled?(Current.city)).to be(false)
  end
end
