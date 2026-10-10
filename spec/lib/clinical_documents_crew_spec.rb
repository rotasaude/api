require "rails_helper"
require Rails.root.join("lib/clinical_documents_crew")

# Semente de dev do 19c: catálogo de fixture (sem chamar a API externa),
# listas Anvisa do repositório, e em Curitiba o interruptor, o CNPJ, a REMUME
# e um protocolo de enfermagem. Idempotente.
RSpec.describe ClinicalDocumentsCrew do
  before do
    clinical_city!
    Maintainer.create!(email_address: "dev@local", password: "dev-password", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    stub_const("Medications::AnvisaImport::DIR", anvisa_fixture_dir)
    city_profile!
    create_unit
    municipal_admin!
  end

  it "semeia a plataforma sem rede e a cidade, duas vezes sem duplicar" do
    expect(described_class.seed_platform!).to eq(anvisa: "importadas", catalog: "importado (recorte de dev)")
    expect(WebMock).not_to have_requested(:get, MedicationHelpers::CATMAT_URL)
    allow(Current.city).to receive(:slug).and_return("curitiba")
    2.times { described_class.seed_current_city(slug: "curitiba") }
    expect(ClinicalDocuments::Gate.usable?(Current.city)).to be(true)
    expect(Cnpj.normalize(CityProfile.current.cnpj)).to eq("76001234000115")
    expect(CityMedication.count).to eq(13)
    protocol = NursingProtocol.sole
    expect(protocol.current_version.items.count).to eq(4)
    expect(described_class.seed_platform!).to eq(anvisa: "já ativas", catalog: "já ativo")
  end
end
