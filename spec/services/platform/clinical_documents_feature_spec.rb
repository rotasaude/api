require "rails_helper"

# ADR 0033 (spec §3): documentos clínicos atrás do interruptor
# clinical_documents, utilizável só com o prontuário utilizável.
RSpec.describe "Interruptor clinical_documents" do
  let(:city) { clinical_city! }

  def set(key, enabled) = Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)

  it "está no catálogo e exige o prontuário utilizável" do
    expect(Platform::Features::KEYS).to include("clinical_documents")
    set("clinical_documents", true)
    expect(Platform::Features.missing(city, "clinical_documents")).to eq([])
    expect(ClinicalDocuments::Gate.usable?(city)).to be(true)

    set("clinical_record", false)
    expect(Platform::Features.missing(city, "clinical_documents")).to eq([ "clinical_record_disabled" ])
    expect(ClinicalDocuments::Gate.usable?(city)).to be(false)
  end

  it "desligado ou sem cidade não é utilizável" do
    expect(ClinicalDocuments::Gate.usable?(city)).to be(false)
    expect(ClinicalDocuments::Gate.usable?(nil)).to be(false)
  end

  it "não depende da assinatura digital" do
    set("clinical_documents", true)
    expect(Platform::Features.enabled?(city, "digital_signature")).to be(false)
    expect(ClinicalDocuments::Gate.usable?(city)).to be(true)
  end
end
