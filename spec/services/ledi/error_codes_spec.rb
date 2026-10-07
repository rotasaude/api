require "rails_helper"

# api#43 (ADR 0030; spec §6): da resposta do PEC só ficam campo e código de
# listas fechadas — nunca valor, nome ou data do cidadão.
RSpec.describe Ledi::ErrorCodes do
  it "achata errosValidacao em campo (último segmento conhecido) e código pela mensagem" do
    body = { descricaoErro: "Erro de validação",
             errosValidacao: { "atendimentosIndividuais[0]" => { cpfCidadao: "CPF 12345678909 inválido",
                                                                  dataNascimento: "Data 10/05/1980 posterior ao atendimento" },
                               "headerTransport.ine" => "INE obrigatório",
                               "lotacao.cboCodigo_2002" => "CBO 322205 não permitido para o modelo",
                               "nomeEstranho" => "MARIA DA SILVA duplicada" } }.to_json
    expect(described_class.from_rejection(body)).to eq([
      { "field" => "cpfCidadao", "code" => "invalid" }, { "field" => "dataNascimento", "code" => "out_of_range" },
      { "field" => "ine", "code" => "required" }, { "field" => "cboCodigo_2002", "code" => "not_allowed" },
      { "field" => "other", "code" => "duplicate" }
    ])
  end

  it "sem errosValidacao usa a descrição só para classificar; corpo que não é JSON vira desconhecido" do
    expect(described_class.from_rejection({ descricaoErro: "Campo obrigatório ausente" }.to_json))
      .to eq([ { "field" => "other", "code" => "required" } ])
    expect(described_class.from_rejection("CNES 1234567 não pertence ao município")).to eq([ described_class::UNKNOWN ])
    expect(described_class.from_rejection(nil)).to eq([ described_class::UNKNOWN ])
  end

  it "nunca devolve valor: só chaves das listas fechadas, e no máximo 20" do
    body = { errosValidacao: (1..30).to_h { |i| [ "campo#{i}", "valor 529.982.247-25 inválido" ] } }.to_json
    codes = described_class.from_rejection(body)
    expect(codes.size).to be <= 20
    expect(described_class.valid?(codes)).to be(true)
    expect(codes.to_json).not_to include("529", "valor")
  end

  it "transporte e validação" do
    expect(described_class.transport("unreachable")).to eq([ { "field" => "transport", "code" => "unreachable" } ])
    expect(described_class.transport("qualquer")).to eq([ { "field" => "transport", "code" => "unknown" } ])
    expect(described_class.valid?([ { "field" => "cpfCidadao", "code" => "invalid" } ])).to be(true)
    expect(described_class.valid?([ { "field" => "cpfCidadao", "code" => "invalid", "value" => "x" } ])).to be(false)
    expect(described_class.valid?([ { "field" => "Maria", "code" => "invalid" } ])).to be(false)
  end
end
