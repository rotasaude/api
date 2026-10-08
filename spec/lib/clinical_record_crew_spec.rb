require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s

# Spec §9: interruptor e modo record em Curitiba (dev); cidadã validada com
# nome completo e social; consulta finalizada com T90 ativo e um adendo. O
# teste fixa o que quebra em silêncio: o prefixo de telefone, os recortes de
# terminologia e o corpo do rascunho; e roda a semente inteira no banco de
# teste (nunca no de dev).
RSpec.describe ClinicalRecordCrew do
  it "o prefixo do telefone não aparece em nenhum outro lib/*_crew.rb" do
    others = Dir[Rails.root.join("lib/*_crew.rb")].reject { |f| f.end_with?("/clinical_record_crew.rb") }
    expect(others.select { |f| File.read(f).include?(described_class::PHONE_PREFIX) }).to eq([])
  end

  it "os recortes de CIAP-2 e CID-10 importam pelo caminho real e trazem T90 e E11.9" do
    result = described_class.seed_platform!
    expect(result.values).to all(be(true).or(be(false)))
    expect(ClinicalTerms.find("ciap2", "T90")).to be_present
    expect(ClinicalTerms.find("cid10", "E11.9")).to be_present
    expect(described_class.seed_platform!).to eq(ciap2: false, cid10: false)
  end

  it "o rascunho da semente passa na validação dos itens" do
    Current.city = TEST_CITY_A
    described_class.seed_platform!
    patient = Patient.create!(cpf: verified_citizen!(1).cpf, birth_date: "1979-04-12", sex: "male")
    expect(Consultations::ItemsInput.call(described_class::DRAFT, patient: patient, cbo: "225125")).to be_ok
  ensure
    Current.reset
  end

  # Semente inteira no banco de teste, com o elenco que ela exige (mesmo setup
  # do ScreeningCrew), em vez de rodar db:seed no banco de dev.
  describe ".seed_current_city" do
    let!(:city) { clinical_city!(record_mode: "off", enabled: false) }

    before do
      create_default_protocol!
      admin = staff_with("admin@curitiba.demo", "municipal_admin")
      SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
      ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
      ScreeningCrew.seed_platform!
      ScreeningCrew.seed_current_city(slug: "curitiba", ddd: "41")
      described_class.seed_platform!
    end
    after do
      Rails.cache.clear
      Current.reset
    end

    def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41")

    it "sem o mantenedor de dev não liga nada nem consulta" do
      result = nil
      expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
      expect(result).to include(switch: "desligado (sem mantenedor)", consultation: "sem consulta")
      expect(ClinicalRecord::Gate.usable?(city)).to be(false)
      expect(Consultation.count).to eq(0)
    end

    it "liga o modo record e o interruptor, finaliza a consulta da médica com T90 e adendo; idempotente" do
      Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random,
                         otp_enabled_at: Time.current)
      result = seed
      expect(result).to eq(switch: "ligado", patient: "Luíza Alves", consultation: "finalizada com adendo")
      expect(City.find(city.id).record_mode).to eq("record")
      expect(ClinicalRecord::Gate.usable?(City.find(city.id))).to be(true)

      citizen = Citizen.find_by!(phone: "+5541#{described_class::PHONE_PREFIX}0001")
      expect(citizen).to be_verification_level_verified
      expect([ citizen.full_name, citizen.social_name ]).to eq([ "Luiz Fernando Alves Moreira", "Luíza Alves" ])
      expect(CitizenIdentity::Cpf.normalize(citizen.cpf)).to eq(citizen.cpf)

      consultation = citizen.reload.patient.consultations.finalized_consultations.sole
      expect(consultation.cbo_code).to eq("225125")
      expect(consultation.author_user.email_address).to eq("profissional@curitiba.demo")
      expect(consultation.addenda.count).to eq(1)
      expect(citizen.patient.problems.map { |p| [ p.terminology, p.code, p.status ] }).to eq([ %w[ciap2 T90 active] ])

      unit = HealthUnit.find_by!(name: described_class::UNIT)
      expect(Attendance.waiting.where(citizen: citizen, health_unit: unit).count).to eq(1)

      counts = [ Citizen.count, Patient.count, Consultation.count, ConsultationAddendum.count, Attendance.count ]
      expect(seed).to eq(result)
      expect([ Citizen.count, Patient.count, Consultation.count, ConsultationAddendum.count, Attendance.count ]).to eq(counts)
    end
  end
end
