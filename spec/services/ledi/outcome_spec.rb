require "rails_helper"

# Spec §6.4: 2xx aceita; 400 recusa (não reenvia sozinho); sessão expirada
# (status observado na prova) pede relogin; 5xx e o resto tentam de novo.
RSpec.describe Ledi::Outcome do
  let(:json_400) do
    { descricaoErro: "Erro de validação",
      errosValidacao: { cnesDadoSerializado: "CNES 1234567 não pertence ao município" } }.to_json
  end

  before do
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return("já foi recebida")
    allow(Ledi::Observations).to receive(:session_expired_statuses).and_return([ 401, 302 ])
  end

  {
    [ 200, "" ] => :accepted, [ 201, "" ] => :accepted,
    [ 401, "" ] => :unauthorized, [ 302, "" ] => :unauthorized,
    [ 500, "erro" ] => :retry, [ 502, "" ] => :retry, [ 503, "" ] => :retry, [ 404, "" ] => :retry
  }.each do |(status, body), expected|
    it("#{status} → #{expected}") { expect(described_class.classify(status, body)).to eq(expected) }
  end

  it "400 com corpo JSON do PEC → recusa" do
    expect(described_class.classify(400, json_400)).to eq(:rejected)
  end

  it "400 com corpo em texto puro → recusa" do
    expect(described_class.classify(400, "CNES 1234567 não pertence ao município")).to eq(:rejected)
  end

  # Review Focus 1: o reenvio do mesmo uuid depois de um 200 perdido.
  it "duplicidade observada classifica como aceita" do
    body = { descricaoErro: "A ficha 1234567-abc já foi recebida.", errosValidacao: nil }.to_json
    expect(described_class.classify(400, body)).to eq(:accepted)
  end

  it "sem marcador observado, todo 400 é recusa" do
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return(nil)
    body = { descricaoErro: "A ficha já foi recebida.", errosValidacao: nil }.to_json
    expect(described_class.classify(400, body)).to eq(:rejected)
  end

  describe ".message" do
    it "junta descricaoErro e errosValidacao achatados (chaves aninhadas com ponto)" do
      body = { descricaoErro: "Erro de validação",
               errosValidacao: { cnesDadoSerializado: "valor inválido: 1",
                                 dadoSerializado: { headerTransport: { ine: "inválido" } },
                                 lista: [ "a", "b" ] } }.to_json
      expect(described_class.message(body)).to eq(
        "Erro de validação; cnesDadoSerializado: valor inválido: 1; " \
        "dadoSerializado.headerTransport.ine: inválido; lista: a; lista: b"
      )
    end

    it "aceita errosValidacao nulo" do
      body = { descricaoErro: "Erro na desserialização", errosValidacao: nil }.to_json
      expect(described_class.message(body)).to eq("Erro na desserialização")
    end

    it "devolve o corpo cru quando não é JSON" do
      expect(described_class.message("CNES 1234567 não pertence")).to eq("CNES 1234567 não pertence")
    end

    it "devolve o corpo cru quando o JSON não é objeto" do
      expect(described_class.message("[1,2]")).to eq("[1,2]")
    end

    it "devolve o corpo cru quando o JSON objeto não tem campos de erro conhecidos" do
      expect(described_class.message('{"erro":"x"}')).to eq('{"erro":"x"}')
      expect(described_class.message("{}")).to eq("{}")
    end

    it "trata nil" do
      expect(described_class.message(nil)).to eq("")
    end
  end
end
