require "rails_helper"

# Módulo 25, Task 11 (contrato §14): a validação da ficha enviada pelo PATCH.
RSpec.describe Surveillance::Form, ".validate" do
  def path_of(hash)
    result = described_class.validate(hash)
    expect(result).to be_failure
    expect(result.reason).to eq(:invalid_form)
    result.details.fetch(:path)
  end

  it "código fora do domínio → path form.<chave>" do
    expect(path_of("pregnancy" => "7")).to eq("form.pregnancy")
    expect(path_of("residence_zone" => "0")).to eq("form.residence_zone")
  end

  it "texto longo é recusado, nunca cortado" do
    expect(path_of("residence_street" => "x" * 61)).to eq("form.residence_street")
    expect(path_of("residence_number" => "1234567")).to eq("form.residence_number")
    expect(described_class.validate({ "residence_street" => "x" * 60 }).payload[:form]).to eq("residence_street" => "x" * 60)
  end

  it "chave desconhecida (inclusive cpf) → path form.<chave>" do
    expect(path_of("cpf" => "123")).to eq("form.cpf")
    expect(path_of("full_name" => "x")).to eq("form.full_name")
  end

  it "tipo errado (número, lista, objeto, booleano) → path form.<chave>" do
    expect(path_of("pregnancy" => 5)).to eq("form.pregnancy")
    expect(path_of("residence_street" => [ "a" ])).to eq("form.residence_street")
    expect(path_of("phone" => { "a" => 1 })).to eq("form.phone")
    expect(path_of("residence_zone" => true)).to eq("form.residence_zone")
  end

  it "ficha que não é objeto → path form" do
    expect(path_of("a")).to eq("form")
    expect(path_of(nil)).to eq("form")
  end

  it "telefone: pontuação sai, 10 a 11 dígitos" do
    expect(described_class.validate({ "phone" => "(41) 99999-0000" }).payload[:form]).to eq("phone" => "41999990000")
    expect(path_of("phone" => "999990000")).to eq("form.phone")
    expect(path_of("phone" => "419999900001")).to eq("form.phone")
    expect(path_of("phone" => "41 9999a0000")).to eq("form.phone")
  end

  it "CEP: 8 dígitos exatos, com ou sem hífen" do
    expect(described_class.validate({ "residence_zip" => "81020-000" }).payload[:form]).to eq("residence_zip" => "81020000")
    expect(path_of("residence_zip" => "8102000")).to eq("form.residence_zip")
  end

  it "geocampos: 1 a 8 dígitos" do
    expect(described_class.validate({ "residence_geo1" => "12345678" }).payload[:form]).to eq("residence_geo1" => "12345678")
    expect(path_of("residence_geo1" => "123456789")).to eq("form.residence_geo1")
  end

  it "UF em maiúsculas entre as 27; CBO com 6 dígitos" do
    expect(described_class.validate({ "residence_uf" => " pr " }).payload[:form]).to eq("residence_uf" => "PR")
    expect(path_of("residence_uf" => "XX")).to eq("form.residence_uf")
    expect(described_class.validate({ "occupation_cbo" => "622020" }).payload[:form]).to eq("occupation_cbo" => "622020")
    expect(path_of("occupation_cbo" => "6220")).to eq("form.occupation_cbo")
  end

  it "texto: espaços colapsados; vazio, só espaços e null viram ausentes" do
    form = { "residence_street" => "  Rua   das  Acácias ", "residence_complement" => "   ", "residence_reference" => "",
             "residence_district" => nil, "pregnancy" => "" }
    expect(described_class.validate(form).payload[:form]).to eq("residence_street" => "Rua das Acácias")
  end

  it "ficha vazia é válida; chaves simbólicas são aceitas" do
    expect(described_class.validate({}).payload[:form]).to eq({})
    expect(described_class.validate({ race_color: "4" }).payload[:form]).to eq("race_color" => "4")
  end

  it "o limite do texto vale depois do squish" do
    expect(described_class.validate({ "residence_number" => "  12   34  " }).payload[:form]).to eq("residence_number" => "12 34")
  end

  it "o caminho é o único dado da recusa (nunca o valor)" do
    result = described_class.validate({ "residence_street" => "Segredo " * 20 })
    expect(result.details.keys).to eq([ :path ])
    expect(result.to_h.to_s).not_to include("Segredo")
  end
  describe "bloco do animal (módulo 35b, Q16)" do
    let(:animal) do
      { "animal_species" => "dog", "animal_condition" => "healthy", "animal_observable" => "true",
        "exposure_on" => Time.zone.today.iso8601, "animal_tutor_name" => "Tutor Fulano", "animal_tutor_phone" => "(41) 99999-0000",
        "animal_address" => "Rua das Flores, 100" }
    end

    def path_for(hash, disease)
      result = described_class.validate(hash, disease_code: disease)
      expect(result).to be_failure
      expect(result.reason).to eq(:invalid_form)
      result.details.fetch(:path)
    end

    it "animal_species em dengue → invalid_form path form.animal_species" do
      expect(path_for({ "animal_species" => "dog" }, "dengue")).to eq("form.animal_species")
      expect(path_for({ "animal_species" => "dog" }, nil)).to eq("form.animal_species")
    end

    it "acidente_animal_raiva com os sete campos válidos → ok, telefone só dígitos" do
      result = described_class.validate(animal, disease_code: "acidente_animal_raiva")
      expect(result).to be_ok
      expect(result.payload[:form]).to include("animal_tutor_phone" => "41999990000", "animal_observable" => "true")
    end

    it "animal_observable \"true\" com bat → path form.animal_observable; false com bat passa" do
      expect(path_for(animal.merge("animal_species" => "bat"), "acidente_animal_raiva")).to eq("form.animal_observable")
      expect(described_class.validate(animal.merge("animal_species" => "bat", "animal_observable" => "false"),
                                      disease_code: "acidente_animal_raiva")).to be_ok
    end

    it "animal_observable \"true\" sem animal_species → path form.animal_observable; \"false\" sem espécie passa" do
      expect(path_for({ "animal_observable" => "true" }, "acidente_animal_raiva")).to eq("form.animal_observable")
      expect(described_class.validate({ "animal_observable" => "false" }, disease_code: "acidente_animal_raiva")).to be_ok
    end

    it "exposure_on amanhã ou inexistente → path form.exposure_on; JSON true em boolean → path form.animal_observable" do
      expect(path_for({ "exposure_on" => (Time.zone.today + 1).iso8601 }, "acidente_animal_raiva")).to eq("form.exposure_on")
      expect(path_for({ "exposure_on" => "2026-02-30" }, "acidente_animal_raiva")).to eq("form.exposure_on")
      expect(path_for({ "exposure_on" => "01/02/2026" }, "acidente_animal_raiva")).to eq("form.exposure_on")
      expect(path_for({ "animal_observable" => true }, "acidente_animal_raiva")).to eq("form.animal_observable")
      expect(path_for({ "animal_observable" => "sim" }, "acidente_animal_raiva")).to eq("form.animal_observable")
    end

    it "telefone de 9 dígitos e endereço curto → path do campo" do
      expect(path_for({ "animal_tutor_phone" => "419999900" }, "acidente_animal_raiva")).to eq("form.animal_tutor_phone")
      expect(path_for({ "animal_address" => "Rua 1" }, "acidente_animal_raiva")).to eq("form.animal_address")
    end
  end
end
