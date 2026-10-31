require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s
require Rails.root.join("lib/oral_health_crew").to_s

# Semente de dev do módulo 28 (ADR 0046) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o RegulationCrew (UBS, equipe, as
# pessoas das linhas de cuidado e da regulação). Cada exemplo prova o que a
# prova no navegador precisa achar sem preparo manual. Idempotente; a saída
# nunca leva dado de paciente.
RSpec.describe OralHealthCrew, type: :request do
  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  let(:ubs) { HealthUnit.find_by!(name: CareLinesCrew::UNIT) }
  let(:ceo) { HealthUnit.find_by!(name: "CEO Curitiba Centro") }

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
    described_class.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    RegulationCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.demo")

  def patient_of(crew, key)
    cpf = crew == :care_lines ? CareLinesCrew.cpf_for("curitiba", key) : RegulationCrew.cpf_for("curitiba", key)
    Citizen.find_by!(cpf: cpf).patient
  end

  def counts = [ Consultation.where(kind: "dental").count, DentalTreatmentPlan.count, DentalTreatmentPlanItem.count, DentalProsthesisOrder.count ]

  describe ".seed_platform!" do
    it "põe a SIGTAP odontológica no recorte de dev e o D82 na CIAP-2, e repetir não muda nada" do
      expect(SigtapSample::ORAL_HEALTH_CODES).to all(satisfy { |code| Terminology::Sigtap.compatible?(code, competence: Time.zone.today.strftime("%Y%m"))[:ok] })
      expect(ClinicalTerms.find("ciap2", "D82")).to be_present
      expect { described_class.seed_platform! }.not_to(change { TerminologyRelease.count })
    end
  end

  describe ".seed_current_city" do
    it "liga o interruptor, cria o CEO tipo II e a eSB associada à eSF, e vincula a equipe com o TOTP fixo" do
      result = seed
      esf = HealthTeam.find_by!(health_unit: ubs, kind: "70")
      aggregate_failures do
        expect(result[:switch]).to eq("ligado (dental_care)")
        expect(DentalCare::Gate.usable?(Current.city)).to be(true)
        expect(ceo).to have_attributes(kind: "ceo")
        expect(ceo.ceo_profile).to have_attributes(ceo_type: "II", specialties: DentalCare::Catalog::CEO_SPECIALTIES)
        esb = HealthTeam.find_by!(ine: "0001234571")
        expect(esb).to have_attributes(kind: "71", name: "eSB Jardim das Flores", health_unit_id: ubs.id, associated_team_id: esf.id)

        expect(result[:users].map { |u| [ u[:email], u[:role] ] }).to eq(
          [ %w[dentista@curitiba.demo health_professional], %w[asb@curitiba.demo health_professional],
            %w[endodontista@curitiba.demo health_professional] ]
        )
        expect(result[:users].map { |u| u[:otpauth_uri] }).to all(start_with("otpauth://totp/"))
        expect(%w[dentista asb endodontista].map { |prefix| user(prefix).otp_secret })
          .to eq(%w[DENTISTASEMENTEDEVCWBAORALHEALTH AUXILIARSAUDEBUCALDEVCWBORALHLTH ENDODONTISTASEMENTEDEVCWBORALHLT])
        expect(%w[dentista asb endodontista].map { |prefix| user(prefix).mfa_enrolled? }).to all(be(true))

        { "dentista" => [ "Fernanda Cristina Moreira", ubs, "223208" ], "asb" => [ "Juliana Aparecida Santos", ubs, "322430" ],
          "endodontista" => [ "Rodrigo Henrique Tavares", ceo, "223212" ] }.each do |prefix, (name, unit, cbo)|
          professional = user(prefix).professional
          expect(professional).to have_attributes(professional_name: name, council: "CRO", council_state: "PR")
          expect(Professionals::Cns.valid?(professional.cns)).to be(true)
          expect(professional.links.active.pluck(:health_unit_id, :cbo_code)).to eq([ [ unit.id, cbo ] ])
        end
        expect(esb.members.active.map { |m| m.professional.professional_name }).to match_array([ "Fernanda Cristina Moreira", "Juliana Aparecida Santos" ])
        expect(Consultations::Cbos.role("322430")).to eq(:auxiliary)
      end
    end

    it "cenário: registro inicial, planos, gestante, encaminhamento e CEO, produção do mês e prótese; repetir não duplica nada" do
      result = seed
      first = counts
      aggregate_failures do
        # Registro inicial de adulto.
        rafael = patient_of(:care_lines, :rafael)
        expect(DentalCare::Chart.call(rafael)[:teeth].to_h { |t| [ t[:tooth], t ] }.values_at(16, 26, 36).map { |t| t[:situation] || t.dig(:faces, "O") })
          .to all(be_present)
        expect(Consultation.where(patient_id: rafael.id, kind: "dental").sole).to have_attributes(baseline: true, status: "finalized")
        expect(DentalChartEvent.where(patient_id: rafael.id).pluck(:tooth, :situation)).to match_array([ [ 16, "restored" ], [ 26, "restored" ], [ 36, "extracted" ] ])

        # Plano aberto com baixa (selantes ficam para a auxiliar).
        antonio = patient_of(:care_lines, :antonio)
        plan = DentalTreatmentPlan.find_by!(patient_id: antonio.id)
        expect(plan).to have_attributes(status: "open", health_unit_id: ubs.id)
        expect(plan.items.group(:status).count).to eq("done" => 1, "planned" => 2)
        expect(plan.items.where(status: "planned").pluck(:procedure_code)).to eq(%w[0101020066 0101020066])

        # Plano com o rascunho que sugere o desfecho 15.
        maria = patient_of(:care_lines, :maria)
        expect(DentalTreatmentPlan.find_by!(patient_id: maria.id).items.group(:status).count).to eq("done" => 1, "planned" => 2)
        draft = Consultation.find_by!(patient_id: maria.id, kind: "dental", status: "draft")
        expect(DentalCare::Plans.suggest_completed?(draft)).to be(true)
        expect(draft.dental_outcomes).to eq([ 16 ])

        # Gestante: a prática c3_k cumprida.
        ana = patient_of(:care_lines, :ana)
        expect(Consultation.where(patient_id: ana.id, kind: "dental", status: "finalized").sole).to have_attributes(pregnant: true)

        # Encaminhamento (desfecho 3, pedido pendente) e primeira consulta no CEO.
        cristiane = patient_of(:regulation, :cristiane)
        referral = Consultation.joins(:attendance).find_by!(patient_id: cristiane.id, kind: "dental", attendances: { health_unit_id: ubs.id })
        expect(referral.dental_outcomes).to eq([ 3 ])
        expect(RegulationRequest.find_by!(consultation_id: referral.id, target_code: "223212")).to have_attributes(target_code: "223212", status: "pending")
        expect(EndodonticTreatment.find_by!(patient_id: cristiane.id)).to have_attributes(health_unit_id: ceo.id, tooth: 36, canals: 3, status: "in_progress")
        expect(DentalTreatmentPlan.find_by!(patient_id: cristiane.id, health_unit_id: ceo.id)).to have_attributes(status: "open")

        # Metas do CEO no mês: periodontia abaixo, endodontia com composição ok.
        goals = DentalCare::CeoGoals.call(unit: ceo, month: Time.zone.today.beginning_of_month).fetch(:specialties).index_by { |row| row[:key] }
        expect(goals["periodontics"]).to include(goal: 90, done: 40, met: false)
        expect(goals["endodontics"]).to include(goal: 60, met: false)
        expect(goals["endodontics"][:done]).to eq(20)
        expect(goals["endodontics"][:composition]).to include(ok: true, value: "50.00")

        # Prótese total maxilar recebida (laboratório terceiro, por nome).
        neusa = patient_of(:regulation, :neusa)
        expect(DentalProsthesisOrder.find_by!(patient_id: neusa.id)).to have_attributes(
          stage: "received", procedure_code: "0701070137", laboratory_name: "Laboratório de Prótese Dental Sorriso Ltda", care_provider_id: nil
        )
        expect(result[:prosthesis]).to eq("received" => 1)
        # Toda primeira consulta programática abre plano (e toda do CEO): os três com itens e os vazios.
        expect(result[:plans]).to eq("open" => 6)
      end

      seed
      expect(counts).to eq(first)
    end

    it "só e-mail, papel e otpauth na saída: nada de CPF, CNS nem nome de paciente" do
      result = seed
      lines = described_class.summary_lines(result, password: "dev-password").join("\n")
      names = [ [ :care_lines, :rafael ], [ :care_lines, :maria ], [ :regulation, :neusa ] ].map { |crew, key| (crew == :care_lines ? CareLinesCrew : RegulationCrew)::PEOPLE.fetch(key)[:name] }
      identifiers = Patient.pluck(:cpf, :cns).flatten.compact
      aggregate_failures do
        expect(lines).to include("dentista@curitiba.demo", "asb@curitiba.demo", "endodontista@curitiba.demo", "otpauth://totp/")
        names.each { |name| expect(lines).not_to include(name) }
        identifiers.each { |identifier| expect(lines).not_to include(identifier) }
        expect(result.except(:users).to_s).not_to match(/\d{11}/)
      end
    end

    it "fora de Curitiba e sem o mantenedor de dev: nada é ligado" do
      expect(described_class.seed_current_city(slug: "outra", ddd: "11", password: "x")).to include(switch: "fora", users: [])
      allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
      expect(seed).to include(switch: "desligado (sem mantenedor dev@local)", users: [])
      expect(Consultation.where(kind: "dental")).to be_empty
    end
  end
end
