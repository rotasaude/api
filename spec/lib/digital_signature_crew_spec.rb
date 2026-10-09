require "rails_helper"
require Rails.root.join("lib/digital_signature_crew").to_s

# Semente de dev (Task 18, R12): só Curitiba, os dois interruptores via dev@local;
# CPF válido a quem não tem. Roda no banco de teste (nunca db:seed em dev).
RSpec.describe DigitalSignatureCrew do
  let!(:city) { clinical_city! }
  after do
    Rails.cache.clear
    Current.reset
  end

  def maintainer! = Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  def feature?(key) = Platform::Features.enabled?(City.find(city.id), key)

  it "sem o mantenedor de dev, avisa e não liga" do
    result = nil
    expect { result = described_class.seed_current_city(slug: "curitiba") }.to output(/sem mantenedor de dev/).to_stderr
    expect(result[:switch]).to eq("desligado (sem mantenedor)")
    expect([ feature?("digital_signature"), feature?("signature_psc_mock") ]).to eq([ false, false ])
  end

  it "em Curitiba liga digital_signature e signature_psc_mock; profissional sem CPF ganha um válido; idempotente" do
    maintainer!
    doctor = doctor!(create_unit)
    doctor.professional.update_columns(cpf: nil)
    result = described_class.seed_current_city(slug: "curitiba")
    expect(result[:switch]).to eq("ligado")
    expect([ feature?("digital_signature"), feature?("signature_psc_mock") ]).to eq([ true, true ])
    expect(Signatures::Gate.usable?(City.find(city.id))).to be(true)
    cpf = doctor.professional.reload.cpf
    expect(CitizenIdentity::Cpf.normalize(cpf)).to eq(cpf)
    expect(described_class.seed_current_city(slug: "curitiba")).to include(switch: "ligado", professionals: [])
  end

  it "reexecução com profissional novo sem CPF não colide com CPF já semeado" do
    maintainer!
    unit = create_unit
    first = doctor!(unit)
    first.professional.update_columns(cpf: nil)
    described_class.seed_current_city(slug: "curitiba")
    second = doctor!(unit)
    second.professional.update_columns(cpf: nil)
    expect { described_class.seed_current_city(slug: "curitiba") }.not_to raise_error
    cpfs = [ first, second ].map { |u| u.professional.reload.cpf }
    expect(cpfs.uniq.size).to eq(2)
    expect(cpfs).to all(satisfy { |c| CitizenIdentity::Cpf.normalize(c) == c })
  end

  it "outra cidade fica intocada" do
    maintainer!
    expect(described_class.seed_current_city(slug: "maringa")).to eq(switch: "desligado (só Curitiba liga)", professionals: [])
    expect([ feature?("digital_signature"), feature?("signature_psc_mock") ]).to eq([ false, false ])
  end
end
