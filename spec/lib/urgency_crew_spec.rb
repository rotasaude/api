require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/urgency_crew").to_s

# Semente de dev do módulo 32a (ADR 0050) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o CareLinesCrew (a UPA, a UBS, a
# equipe da ESF e o José com a consulta da médica). Cada exemplo prova o que a
# prova no navegador precisa achar sem preparo manual. Idempotente; a saída
# nunca leva CPF, CNS, nome nem descrição de paciente.
RSpec.describe UrgencyCrew, type: :request do
  let!(:city) { clinical_city! }
  let(:unit) { HealthUnit.find_by!(name: UrgencyCrew::UNIT) }

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

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.dev")

  def counts
    [ UrgencyEncounter.count, UrgencyClassification.count, UrgencyOutcome.count, Attendance.count, Patient.count, CallLocation.count,
      WaitingRoomDisplay.count, User.count, Membership.count, Professional.count, ProfessionalLink.count, CityFeature.count,
      ProtocolDefinition.count, Consultation.count ]
  end

  it "liga os dois interruptores e deixa a UPA com prefixo de senha, TV com tempos e os quatro locais" do
    result = seed

    aggregate_failures do
      expect(result[:switch]).to eq("ligado (urgency_care e waiting_room_display)")
      expect(Urgency::Gate.usable?(city)).to be(true)
      expect(WaitingRoom::Gate.usable?(city)).to be(true)
      expect([ unit.ticket_prefix, unit.show_wait_times ]).to eq([ "U", true ])
      expect(CallLocation.where(health_unit_id: unit.id).pluck(:name))
        .to match_array([ "Classificação de risco", "Consultório 1", "Consultório 2", "Sala de medicação" ])
      display = WaitingRoomDisplay.find_by!(health_unit_id: unit.id)
      expect([ display.name, display.show_wait_times, display.active ]).to eq([ "TV da recepção", true, true ])
    end
  end

  it "a equipe tem papel, TOTP fixo, CBO real no vínculo da UPA e só a enfermagem 2235 classifica" do
    seed

    aggregate_failures do
      expect(user("upa").memberships.pluck(:role)).to eq([ "citizen_verifier" ])
      expect(user("upa").professional).to be_nil
      %w[upaenf upamed].each { |prefix| expect(user(prefix).memberships.pluck(:role)).to eq([ "health_professional" ]) }
      expect(%w[upa upaenf upamed].map { |prefix| user(prefix).mfa_enrolled? }).to all(be(true))
      expect(user("upaenf").professional.links.active.where(health_unit_id: unit.id).pluck(:cbo_code)).to eq([ "223505" ])
      expect(user("upamed").professional.links.active.where(health_unit_id: unit.id).pluck(:cbo_code)).to eq([ "225125" ])
      expect(Urgency::Access.classifier(user("upaenf"), unit.id)).to be_ok
      expect(Urgency::Access.classifier(user("upamed"), unit.id)).to be_failure
      expect(user("upaenf").professional.council).to eq("COREN")
      expect(user("upamed").professional.council).to eq("CRM")
    end
  end

  it "o protocolo ativo é o classificacao-urgencia v1 da semente, assinado pelo ciclo" do
    seed

    active = ProtocolDefinition.urgency_protocols.where(status: "active")
    aggregate_failures do
      expect(active.pluck(:name, :version)).to eq([ [ "classificacao-urgencia", 1 ] ])
      expect(Urgency::ActiveProtocol.current).to eq(active.first)
      expect(Urgency::Levels.for(active.first).values).to eq([ 0, 10, 60, 120, 240 ])
      expect(active.first.definition["classification_rules"].size).to eq(11)
    end
  end

  it "a fila tem 4 classificados e 1 aguardando; o laranja estourou pela regra da 1ª classificação (Q18)" do
    seed
    groups = Urgency::Queue.groups(unit)
    colors = groups[:by_color].map { |item| item[:color] }
    orange = groups[:by_color].find { |item| item[:color] == "orange" }
    encounter = UrgencyEncounter.find(orange[:encounter_id])

    aggregate_failures do
      expect(groups[:by_color].size).to eq(4)
      expect(groups[:awaiting_classification].size).to eq(1)
      expect(groups[:in_care]).to be_empty
      expect(colors).to eq(%w[orange yellow green green]) # a ordem da fila: cor, depois a chegada
      expect(groups[:by_color].map { |item| item[:overdue] }).to eq([ true, false, false, false ])
      expect(orange[:waited_minutes]).to be >= 24
      expect(((Time.current - encounter.first_classified_at) / 60).floor).to be > encounter.current_classification.max_wait_minutes
      expect(encounter.current_classification.max_wait_minutes).to eq(10)
      expect(groups[:by_color].first[:ticket]).to match(/\AU-\d{3,4}\z/)
    end
  end

  it "classifica pelo protocolo: a cor aceita é a sugerida, e o azul reclassificado para verde guarda a justificativa" do
    seed
    patient = Patient.find_by!(cpf: described_class.cpf_for("curitiba", :juliana))
    encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: patient.id })
    first, second = encounter.classifications.order(:position).to_a
    roberto = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: Patient.find_by!(cpf: described_class.cpf_for("curitiba", :roberto)).id })

    aggregate_failures do
      expect([ first.color, second.color, encounter.current_classification.color ]).to eq(%w[blue green green])
      expect(first.suggested_color).to be_nil
      expect(first.justification.length).to be >= 10
      expect(second.justification.length).to be >= 10
      expect(roberto.current_classification).to have_attributes(color: "orange", suggested_color: "orange", pain_scale: 8)
      expect(UrgencyClassification.pluck(:pain_scale)).to all(be_an(Integer))
      expect(UrgencyClassification.all.map { |c| c.classified_by_user.email_address }.uniq).to eq([ "upaenf@curitiba.dev" ])
    end
  end

  it "o não identificado aguarda classificação como provisório" do
    seed

    provisional = Patient.where(unidentified: true).first
    encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: provisional.id })
    aggregate_failures do
      expect(provisional.unidentified_description).to eq(described_class::UNIDENTIFIED)
      expect(encounter.state).to eq("waiting_classification")
    end
  end

  it "o encontro de ontem do José fecha com alta para a UBS e aparece na contrarreferência dele e no histórico" do
    seed
    jose = Patient.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :jose))
    encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: jose.id, health_unit_id: unit.id })
    ubs = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
    consultation = Consultation.find_by!(attendance_id: encounter.attendance_id)

    aggregate_failures do
      expect(encounter).to be_closed
      expect(encounter.attendance.checked_in_at).to be < 23.hours.ago
      expect(consultation).to have_attributes(kind: "urgency", status: "finalized")
      expect(consultation.author_user.email_address).to eq("upamed@curitiba.dev")
      expect(encounter.outcome).to have_attributes(kind: "discharged_to_primary_care", return_days: 7)
      expect(encounter.outcome.recorded_by_user.email_address).to eq("upamed@curitiba.dev")
      referrals = Urgency::CounterReferrals.for(unit: ubs)
      expect(referrals.map { |item| item[:encounter_id] }).to eq([ encounter.id ])
      expect(referrals.first).to include(return_days: 7, upa: { name: UrgencyCrew::UNIT })
    end
  end

  it "o código da TV vale 10 min, é novo a cada semente e pareia" do
    first = seed
    second = seed
    paired = WaitingRoom::Pair.call(code: second[:tv_code])

    aggregate_failures do
      expect(first[:tv_code]).to match(/\A\d{6}\z/)
      expect(paired).to be_ok
      expect(WaitingRoomDisplay.count).to eq(1)
    end
  end

  it "rodar duas vezes não duplica encontros, classificações, locais, TVs nem equipe" do
    seed
    before_counts = counts
    seed

    aggregate_failures do
      expect(counts).to eq(before_counts)
      expect(UrgencyEncounter.count).to eq(6)
      expect(UrgencyClassification.count).to eq(6) # 1 + 1 + 1 + 2 + 1 (ontem)
      expect(UrgencyOutcome.count).to eq(1)
      expect(Urgency::Queue.groups(unit)[:by_color].size).to eq(4)
    end
  end

  it "o resumo leva só e-mail, papel, otpauth e o código da TV: nenhum nome, CPF, CNS nem descrição de paciente" do
    result = seed
    text = described_class.summary_lines(result, password: "dev-password").join("\n")
    patient_data = Patient.pluck(:full_name, :cpf, :cns, :unidentified_description).flatten.compact.reject(&:blank?)
    names = described_class::PEOPLE.values.map { |person| person.fetch(:name) } + [ described_class::UNIDENTIFIED ]

    aggregate_failures do
      expect(text).to match(/TV: código \d{6}, vale 10 min/)
      expect(text).to include("upa@curitiba.dev (citizen_verifier)", "upaenf@curitiba.dev (health_professional)", "upamed@curitiba.dev (health_professional)")
      expect(text).to include("otpauth://")
      (names + patient_data).each { |value| expect(text).not_to include(value) }
    end
  end

  it "fora de Curitiba não semeia nada" do
    result = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")

    expect(result[:switch]).to eq("fora")
    expect(UrgencyEncounter.count).to eq(0)
  end
end
