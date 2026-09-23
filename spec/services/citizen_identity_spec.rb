require "rails_helper"

RSpec.describe CitizenIdentity do
  describe CitizenIdentity::Cpf do
    it "normaliza um CPF válido com ou sem pontuação" do
      expect(described_class.normalize("529.982.247-25")).to eq("52998224725")
      expect(described_class.normalize("52998224725")).to eq("52998224725")
    end

    it "recusa dígito verificador errado" do
      expect(described_class.normalize("529.982.247-24")).to be_nil
    end

    it "recusa sequência repetida, que passa na conta do dígito" do
      expect(described_class.normalize("111.111.111-11")).to be_nil
    end

    it "recusa tamanho errado e entrada vazia" do
      expect(described_class.normalize("5299822472")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end

    it "mascara mostrando só os dígitos do meio" do
      expect(described_class.mask("52998224725")).to eq("***.982.247-**")
    end
  end

  describe CitizenIdentity::Phone do
    it "normaliza celular com ou sem +55 para E.164" do
      expect(described_class.normalize("(41) 99876-5432")).to eq("+5541998765432")
      expect(described_class.normalize("+55 41 99876-5432")).to eq("+5541998765432")
    end

    it "recusa fixo (sem o 9), DDD inválido e tamanho errado" do
      expect(described_class.normalize("(41) 3333-4444")).to be_nil
      expect(described_class.normalize("(01) 99876-5432")).to be_nil
      expect(described_class.normalize("99876-5432")).to be_nil
    end

    it "mascara mostrando só os 4 últimos dígitos" do
      expect(described_class.mask("+5541998765432")).to eq("(**) *****-5432")
    end
  end
end
