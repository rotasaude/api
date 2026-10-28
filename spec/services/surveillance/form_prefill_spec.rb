require "rails_helper"

RSpec.describe Surveillance::FormPrefill do
  before { registry_city! }
  let(:patient) { surveillance_patient!(31) }

  it "converte a raça/cor do BPA para o Sinan; sem raça → 9" do
    { "01" => "1", "02" => "2", "03" => "4", "04" => "3", "05" => "5" }.each do |bpa, sinan|
      patient.update!(race_color: bpa)
      expect(described_class.for(patient)["race_color"]).to eq(sinan)
    end
    patient.update!(race_color: nil)
    expect(described_class.for(patient)["race_color"]).to eq("9")
  end

  it "endereço do paciente (UF da cidade), telefone do par validado só com dígitos e sem 55; zona e país vazios" do
    patient.update!(address_zip: "81020000", address_street: "Rua das Acácias", address_number: "SN",
                    address_complement: "casa 2", address_district: "Boqueirão")
    phone = Citizen.find_by!(patient_id: patient.id).phone.delete_prefix("+55")
    expect(described_class.for(patient)).to eq(
      "race_color" => "9", "residence_uf" => "PR", "residence_zip" => "81020000", "residence_street" => "Rua das Acácias",
      "residence_number" => "SN", "residence_complement" => "casa 2", "residence_neighborhood" => "Boqueirão", "phone" => phone
    )
  end

  it "sem endereço: nem UF" do
    expect(described_class.for(patient).keys).not_to include("residence_uf", "residence_street")
  end

  it "ocupação da última versão do cadastro individual ativo" do
    registration = registry_registration!(patient: patient)
    expect(described_class.for(patient)).not_to have_key("occupation_cbo")
    sociodemographic = registration.latest_version.sociodemographic.merge("ocupacao_codigo_cbo2002" => "622020")
    registry_new_version!(registration, sociodemographic: sociodemographic)
    expect(described_class.for(patient)["occupation_cbo"]).to eq("622020")
    registration.update_columns(exit_reason: "moved", exited_on: Time.zone.today)
    expect(described_class.for(patient)).not_to have_key("occupation_cbo")
  end

  it "só chaves da ficha (sinan-form.yml) e a chave de ocupação existe no dicionário do 24a" do
    expect(described_class.for(patient).keys - Surveillance::Form.keys).to be_empty
    expect(TerritoryRegistry::Dictionary.section("sociodemographic")).to have_key(described_class::OCCUPATION_KEY)
  end
end

RSpec.describe Surveillance::Form do
  it "carrega os campos da ficha uma vez, congelados" do
    expect(described_class.keys).to include("race_color", "residence_zip", "phone", "occupation_cbo", "residence_country")
    expect(described_class.keys).not_to include("full_name", "cns")
    expect(described_class.fields.fetch("race_color").fetch("domain")).to include("4" => "Parda")
    expect(described_class.fields).to be_frozen
    expect(described_class.fields.fetch("race_color")).to be_frozen
    expect(described_class.fields).to equal(described_class.fields)
  end
end
