require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/timeline_crew").to_s
require Rails.root.join("lib/pec_simulator").to_s

# Semente do módulo 20 no banco de teste (nunca no de dev), com o mesmo elenco
# da semente do prontuário: cidade, recepção e enfermeira com vínculo e CPF.
RSpec.describe TimelineCrew do
  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  # As contas da semente nascem como <papel>@<slug>.demo: o slug é o da cidade de teste.
  let(:slug) { city.slug }

  before do
    create_default_protocol!
    admin = staff_with("admin@#{slug}.demo", "municipal_admin")
    SignatureCrew.seed_current_city(slug: slug, password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: slug, password: "dev-password", admin: admin)
    ScreeningCrew.seed_platform!
    ScreeningCrew.seed_current_city(slug: slug, ddd: "41")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random,
                       otp_enabled_at: Time.current)
  end
  after do
    Rails.cache.clear
    Current.reset
  end

  it "sem o mantenedor de dev não liga nada" do
    Maintainer.where(email_address: "dev@local").destroy_all
    expect(described_class.seed_current_city(slug: slug, ddd: "41"))
      .to eq(switch: "desligado (sem mantenedor dev@local)")
    expect(Platform::Features.enabled?(city, "patient_timeline")).to be(false)
  end

  it "fora da cidade integrada só liga patient_timeline" do
    result = described_class.seed_current_city(slug: slug, ddd: "41")
    expect(result[:switch]).to start_with("patient_timeline ligado")
    expect(Platform::Features.enabled?(Current.city, "patient_timeline")).to be(true)
    expect(Platform::Features.enabled?(Current.city, "pec_external_view")).to be(false)
  end

  it "na cidade integrada: modo integrated, pec_external_view, configuração e CNES; idempotente" do
    stub_const("#{described_class}::INTEGRATED", slug)
    results = Array.new(2) { described_class.seed_current_city(slug: slug, ddd: "41") }
    expect(results.first).to eq(results.last)
    expect(City.find(Current.city.id).record_mode).to eq("integrated")
    expect(Timeline::Gate.pec_usable?(City.find(Current.city.id))).to be(true)
    expect(PecSetting.current.pec_origin).to eq("http://pec-sim.localhost:3040")
    expect(PecSetting.current.hmac_key).to eq("dev-pec-hmac-key-maringa-0123456789")
    expect(HealthUnit.where(cnes: "7700001").count).to eq(1)
    unit = HealthUnit.find_by!(cnes: "7700001")
    expect(Attendance.where(health_unit: unit, citizen: Citizen.find_by!(phone: "+5541#{ClinicalRecordCrew::PHONE_PREFIX}0001")).count).to eq(1)
    expect(results.last.to_s).not_to include("dev-pec-hmac-key")
  end

  it "a URL do simulador com os padrões da semente passa pela verificação do PEC" do
    stub_const("#{described_class}::INTEGRATED", slug)
    # O CPF dos profissionais vem do RecordModeCrew, que roda antes na semente.
    User.find_by!(email_address: "enfermeira@#{slug}.demo").professional.update!(cpf: ScreeningCrew.send(:cpf_for, "#{slug}:enfermeira"))
    described_class.seed_current_city(slug: slug, ddd: "41")
    city = City.find(Current.city.id)
    defaults = PecSimulator.defaults(city)
    expect(defaults.values_at(:professional, :citizen, :cnes)).to all(be_present)
    url = PecSimulator.signed_url(city: city, **defaults.slice(:professional, :citizen, :cnes))
    expect(url).to include("documento-cidadao=#{defaults[:citizen]}")
    timestamp = url[/pec_timestamp=(\d+)/, 1]
    expect(PecExternal::Signature.verify(url: url, key: described_class::DEFAULT_KEY, timestamp: timestamp)).to eq(:ok)
  end
end
