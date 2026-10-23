require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s

# Semente de dev do módulo 23 no banco de teste (nunca no de dev), com o
# elenco que ela exige na ordem do db/seeds.rb (profissionais, território,
# catálogo de triagens, acolhimento, prontuário). Cada exemplo prova o que
# uma prova no navegador precisa encontrar sem preparo manual (errata da
# Task 16, provas 1–12 e P18): a pessoa existe, o estado está certo e o login
# funciona onde cabe. Idempotente.
RSpec.describe CareLinesCrew, type: :request do
  it "o prefixo do telefone não aparece em nenhum outro lib/*_crew.rb" do
    others = Dir[Rails.root.join("lib/*_crew.rb")].reject { |f| f.end_with?("/care_lines_crew.rb") }
    expect(others.select { |f| File.read(f).include?(described_class::PHONE_PREFIX) }).to eq([])
  end

  # Provas 11/12: catálogo-base carregado, só a v1 (a v2 é da prova do maintenance).
  it "carrega o catálogo-base só na v1; a segunda carga não cria nada" do
    expect(described_class.seed_platform!).to eq(created: 6)
    expect(CareLineTemplate.pluck(:version).uniq).to eq([ 1 ])
    expect(described_class.seed_platform!).to eq(created: 0)
  end

  describe ".seed_current_city" do
    let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
    let(:today) { Time.zone.today }
    let(:unit) { HealthUnit.find_by!(name: described_class::UNIT) }
    let(:team) { HealthTeam.find_by!(health_unit: unit, active: true) }

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
    def person(key) = Citizen.find_by!(cpf: described_class.cpf_for("curitiba", key))
    def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.demo")
    def line(key) = CareLine.find_by!(template_key: key)
    def pending_for(citizen, line)
      scope = CareLineSuggestion.pending_suggestions.where(care_line: line)
      citizen.patient_id ? scope.find_by(patient_id: citizen.patient_id) : scope.find_by(citizen_id: citizen.id)
    end
    def enrollment_of(citizen, line) = CareLineEnrollment.active_enrollments.find_by(patient_id: citizen.patient_id, care_line: line)

    it "provas 1–12 e P18: as pessoas existem com o estado que cada prova precisa" do
      result = seed
      jose, ana, miguel, maria, rafael, antonio, juliana, osvaldo, sebastiao, sandra =
        %i[jose ana miguel maria rafael antonio juliana osvaldo sebastiao sandra].map { |key| person(key) }
      doctor, nurse, technician = user("profissional"), user("enfermeira"), user("tecnica")

      aggregate_failures do
        # 11/12: interruptor ligado; seis linhas adotadas (v1) e a própria de saúde mental.
        expect(result).to include(switch: "ligado (care_lines)", team: team.name)
        expect(CareLines::Gate.usable?(Current.city)).to be(true)
        expect(CareLine.where(source: "template").pluck(:template_key, :template_version))
          .to match_array(CareLines::Catalog::INDICATORS.keys.map { |key| [ key, 1 ] })
        expect(HealthTeam.where(health_unit: unit, active: true).count).to eq(1)
        expect(HealthTeamMember.active.where(health_team: team).joins(professional: :user).pluck("users.email_address"))
          .to match_array(%w[profissional@curitiba.demo enfermeira@curitiba.demo tecnica@curitiba.demo])

        # 1: hipertensão do José por problema ativo, pendente para a médica confirmar.
        hypertension = pending_for(jose, line("hypertension_c5"))
        expect([ hypertension&.reason, hypertension&.team_id ]).to eq([ "problem", team.id ])
        expect(hypertension.evidence_ref).to start_with("patient_problem:")
        expect(CareLines::Access.confirmer?(doctor, team)).to be(true)

        # 2: técnica 322245 na UBS e na equipe — vê o painel, não confirma.
        expect(technician.professional.links.active.where(health_unit: unit).pluck(:cbo_code)).to eq([ "322245" ])
        expect(%w[health_professional citizen_verifier].map { |role| technician.has_role?(role) }).to eq([ true, true ])
        expect(technician).to be_mfa_enrolled
        expect([ CareLines::Access.panel?(technician, team), CareLines::Access.confirmer?(technician, team) ]).to eq([ true, false ])

        # 3: diabetes do José — consulta de hoje em dia, HbA1c e pés vencidos; aparece na busca ativa.
        diabetic = enrollment_of(jose, line("diabetes_c4"))
        expect(diabetic.source).to eq("suggestion")
        statuses = CareLines::Evaluation.enrollments([ diabetic ], today: today).fetch(diabetic.id).practices.index_by(&:key).transform_values(&:status)
        expect(statuses).to include("c4_a" => "ok", "c4_e" => "overdue", "c4_f" => "overdue")
        overdue = CareLines::Board.page(team: team, line_id: nil, status: "overdue", before: nil, limit: 50, today: today)
        expect(overdue[:rows].map(&:first)).to include(diabetic)

        # 4: inscrição ativa para contato e "Agendar"; quem marca (citizen_verifier) com painel na UBS.
        expect(CitizenVerificationPolicy.new(technician, nil).verify?).to be(true)
        expect(CitizenVerificationPolicy.new(nurse, nil).verify?).to be(false)

        # 5: gestante com sugestão PENDENTE (sem inscrição) — aceitar exige a DUM; a Ana já inscrita pela DUM.
        pregnancy = pending_for(juliana, line("pregnancy_c3"))
        expect([ pregnancy&.reason, pregnancy&.team_id, juliana.patient_id ]).to eq([ "declared", team.id, nil ])
        expect(CareLines::AcceptSuggestion.call(suggestion: pregnancy, by: doctor).reason).to eq(:anchor_required)
        expect(enrollment_of(ana, line("pregnancy_c3")).anchor_on).to eq(today - 70)
        expect(pending_for(ana, line("women_c7"))&.reason).to eq("age_sex")
        baby = enrollment_of(miguel, line("child_c2"))
        baby_statuses = CareLines::Evaluation.enrollments([ baby ], today: today).fetch(baby.id).practices.index_by(&:key).transform_values(&:status)
        expect(baby_statuses).to include("c2_a" => "overdue")

        # 6: idosa validada que nunca consultou, num bairro coberto só pela UBS, com age_sex pendente.
        expect(maria).to be_verification_level_verified
        expect(maria.age).to be >= 60
        expect([ maria.patient_id, Consultation.joins(:patient).where(patients: { cpf: maria.cpf }).count ]).to eq([ nil, 0 ])
        expect(NeighborhoodCoverage.where(neighborhood_id: maria.neighborhood_id).pluck(:health_unit_id)).to eq([ unit.id ])
        elderly = pending_for(maria, line("elderly_c6"))
        expect([ elderly&.reason, elderly&.team_id ]).to eq([ "age_sex", team.id ])

        # 7: linha própria de saúde mental; Rafael declarou e tem a sugestão declared.
        mental = CareLine.find_by!(declared_condition: "mental_health")
        expect([ mental.source, mental.name ]).to eq([ "custom", "Saúde mental — acompanhamento" ])
        expect(CitizenDeclaredCondition.current.where(citizen: rafael).map(&:condition)).to eq([ "mental_health" ])
        expect(pending_for(rafael, mental)&.reason).to eq("declared")

        # 8: a prévia de C4 e de C6 mostra números (estimativa).
        c4 = CareLines::Preview.call(team: team, indicator: "C4", today: today)
        c6 = CareLines::Preview.call(team: team, indicator: "C6", today: today)
        expect(c4[:denominator]).to be >= 1
        expect(c4[:score].to_f).to be > 0
        expect(c6[:denominator]).to be >= 3
        expect(c6[:score].to_f).to be > 0

        # 9 e 10: José validado e inscrito; saude-mental (repete em 30 dias) concluída há 45 dias: vencida.
        expect(jose).to be_verification_level_verified
        view = CareLines::CitizenView.call(citizen: jose, person: Timeline::Person.for_citizen(jose), today: today)
        expect(view[:lines].map { |l| l[:name] }).to eq([ "Pessoa com diabetes" ])
        expect(view[:overdue_triages]).to eq([ { protocol_name: "saude-mental", title: "Saúde mental",
                                                 last_done_at: (today - 45).iso8601 } ])

        # P18: última consulta há 25 meses; a equipe sai do território; age_sex pendente do paciente.
        last = osvaldo.patient.consultations.finalized_consultations.maximum(:finalized_at)
        expect(last).to be < 24.months.ago
        expect(last).to be > 26.months.ago
        expect(CareLines::TeamPopulation.patient_teams([ osvaldo.patient_id ])).to eq(osvaldo.patient_id => team.id)
        expect(pending_for(osvaldo, line("elderly_c6"))&.reason).to eq("age_sex")
        expect(pending_for(sebastiao, line("elderly_c6"))&.reason).to eq("age_sex")

        # D-api-06: 62 anos validado, sem bairro → sem equipe e sem sugestão (inscrição manual).
        expect([ antonio.age, antonio.neighborhood_id, antonio.patient_id ]).to eq([ 62, nil, nil ])
        expect(antonio).to be_verification_level_verified
        expect(CareLineSuggestion.where(citizen_id: antonio.id)).to be_empty
        # D-api-07: par só declarado no celular do José, CPF próprio.
        expect([ sandra.phone, sandra.verification_level_verified? ]).to eq([ jose.phone, false ])
        expect(sandra.cpf).not_to eq(jose.cpf)

        # Toda inscrição veio de sugestão aceita por quem confirma (nunca direto).
        expect(CareLineEnrollment.active_enrollments.joins(:care_line).pluck("care_lines.template_key"))
          .to match_array(%w[diabetes_c4 pregnancy_c3 child_c2])
        expect(CareLineEnrollment.where(source: "manual")).to be_empty
        # Telefones com o prefixo da semente; CPFs válidos.
        people = %i[jose ana miguel maria rafael antonio juliana osvaldo sebastiao sandra].map { |key| person(key) }
        expect(people.map(&:phone)).to all(start_with("+5541#{described_class::PHONE_PREFIX}"))
        expect(people.map { |c| CitizenIdentity::Cpf.normalize(c.cpf) }).to eq(people.map(&:cpf))
        expect(result[:people].size).to eq(10)
        expect(result[:pending]).to eq(CareLineSuggestion.pending_suggestions.where(team_id: team.id).count)
      end

      # 5: aceitar a sugestão da gestante COM a DUM cria o paciente e a inscrição.
      lmp = (today - 56).iso8601
      pregnant = CareLines::AcceptSuggestion.call(suggestion: pending_for(juliana, line("pregnancy_c3")), by: doctor, anchor_date: lmp)
      expect(pregnant).to be_ok
      expect(juliana.reload.patient_id).to be_present
      expect(enrollment_of(juliana, line("pregnancy_c3")).anchor_on).to eq(today - 56)

      # 6: aceitar a sugestão da idosa cria o paciente (Patients::Resolve).
      accepted = CareLines::AcceptSuggestion.call(suggestion: pending_for(maria, line("elderly_c6")), by: nurse)
      expect(accepted).to be_ok
      expect(maria.reload.patient_id).to be_present
    end

    it "logins de dev: a técnica entra, vê a sugestão e não aceita; quem marca recebe can_book; o José entra no wpda" do
      seed
      jose = person(:jose)
      hypertension = pending_for(jose, line("hypertension_c5"))
      diabetic = enrollment_of(jose, line("diabetes_c4"))

      # 2 e 4: técnica pela senha de dev.
      json_post "/session", email_address: "tecnica@curitiba.demo", password: "dev-password"
      expect(response).to have_http_status(:created)
      get "/care_lines/teams"
      expect(json_body["teams"].find { |t| t["id"] == team.id }&.fetch("can_confirm")).to be(false)
      get "/care_lines/suggestions", params: { team_id: team.id }
      expect(json_body["suggestions"].map { |s| s["id"] }).to include(hypertension.id)
      json_post "/care_lines/suggestions/#{hypertension.id}/accept", team_id: team.id
      expect([ response.status, json_body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
      json_post "/care_lines/enrollments/#{diabetic.id}/contacts", channel: "phone", outcome: "no_answer"
      expect(response).to have_http_status(:created)
      json_post "/care_lines/enrollments/#{diabetic.id}/appointment_request", {}
      expect(response).to have_http_status(:created)
      expect([ json_body.dig("request", "kind"), json_body["can_book"] ]).to eq([ "care_line", true ])

      # 4: a enfermeira pede; sem citizen_verifier, a tela diz "pedido enviado à recepção".
      json_post "/session", email_address: "enfermeira@curitiba.demo", password: "dev-password"
      expect(response).to have_http_status(:created)
      json_post "/care_lines/enrollments/#{diabetic.id}/appointment_request", {}
      expect(response).to have_http_status(:ok)
      expect(json_body["can_book"]).to be(false)

      # 1: a médica entra e confirma a hipertensão.
      json_post "/session", email_address: "profissional@curitiba.demo", password: "dev-password"
      get "/care_lines/teams"
      expect(json_body["teams"].find { |t| t["id"] == team.id }&.fetch("can_confirm")).to be(true)
      json_post "/care_lines/suggestions/#{hypertension.id}/accept", team_id: team.id
      expect(response).to have_http_status(:created)

      # 9: o José entra no wpda (celular + código), declara condição e vê "Meu acompanhamento".
      json_post "/citizen/otp", phone: jose.phone
      expect(response).to have_http_status(:accepted)
      json_post "/citizen/session", phone: jose.phone, code: OtpSender::Test.deliveries.last.fetch(:code)
      expect(response).to have_http_status(:created)
      json_post "/citizen/declared_conditions", citizen_id: jose.id, condition: "diabetes"
      expect(response).to have_http_status(:created)
      get "/citizen/care", params: { citizen_id: jose.id }
      expect(json_body["lines"].map { |l| l["name"] }).to eq([ "Pessoa com diabetes", "Pessoa com hipertensão" ])
      expect(json_body["overdue_triages"].map { |t| t["protocol_name"] }).to eq([ "saude-mental" ])
      # D-api-07: o par só declarado do mesmo celular não declara nem vê acompanhamento.
      get "/citizen/care", params: { citizen_id: person(:sandra).id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_verified" ])
    end

    it "a segunda rodada não muda nada" do
      first = seed
      tables = [ User, Membership, Professional, ProfessionalLink, HealthTeam, HealthTeamMember, Neighborhood, Citizen,
                 CitizenVerification, Patient, Attendance, Triage, Consultation, CareLine, CareLineEnrollment, CareLineSuggestion,
                 CitizenDeclaredCondition, CityFeature, CareLineTemplate, AppointmentRequest, DomainEvent, Conversation, PatientProblem,
                 NeighborhoodCoverage, PlatformEvent, Consent, ConsultationProblem, CitizenVerificationCode ]
      expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
    end

    it "sem o mantenedor de dev não liga nada" do
      allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
      result = nil
      expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
      expect(result).to include(switch: "desligado (sem mantenedor dev@local)", people: [])
      expect(CareLine.count).to eq(0)
    end

    it "sem o catálogo-base carregado falha antes de ligar, dizendo o que rodar" do
      allow(CareLineTemplate).to receive(:latest).and_return(CareLineTemplate.none)
      expect { seed }.to raise_error(/catálogo-base não carregado — rode bin\/rails care_lines:templates:load/)
      expect(CareLines::Gate.enabled?(Current.city)).to be(false)
    end

    it "sem o protocolo saude-mental ativo falha antes de ligar, dizendo o que rodar" do
      allow(ProtocolDefinition).to receive(:exists?).and_call_original
      allow(ProtocolDefinition).to receive(:exists?).with(name: "saude-mental", status: "active").and_return(false)
      expect { seed }.to raise_error(/protocolo saude-mental sem versão ativa — rode o TriageCatalogCrew/)
      expect(CareLines::Gate.enabled?(Current.city)).to be(false)
    end

    it "rotula o interruptor ligado mas não utilizável (prontuário desligado)" do
      maintainer = Maintainer.find_by!(email_address: "dev@local")
      Platform::Features.set!(city: Current.city, key: "care_lines", enabled: true, maintainer: maintainer)
      Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: maintainer)
      expect(described_class.send(:switch_label, City.find(city.id))).to start_with("ligado, não utilizável (falta: ")
    end

    it "fora de Curitiba não liga nada" do
      expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "desligado (só Curitiba liga)")
      expect(CareLine.count).to eq(0)
    end
  end
end
