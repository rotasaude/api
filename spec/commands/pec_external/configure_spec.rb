require "rails_helper"

RSpec.describe PecExternal::Configure do
  it "normaliza a origem: esquema e host minúsculos, sem porta padrão; recusa caminho, query, usuário" do
    expect(described_class.normalize_origin("HTTPS://PEC.Cidade.gov.br")).to eq("https://pec.cidade.gov.br")
    expect(described_class.normalize_origin("https://pec.cidade.gov.br:443/")).to eq("https://pec.cidade.gov.br")
    expect(described_class.normalize_origin("https://pec.cidade.gov.br:8443")).to eq("https://pec.cidade.gov.br:8443")
    expect(described_class.normalize_origin("http://pec-sim.localhost:3040")).to eq("http://pec-sim.localhost:3040")
    [ "https://pec.cidade.gov.br/esus", "https://pec.cidade.gov.br?x=1", "https://u:p@pec.cidade.gov.br", "ftp://pec",
      "pec.cidade.gov.br", "", "https://", 42, "https://#{'a' * 260}.br" ].each do |raw|
      expect(described_class.normalize_origin(raw)).to be_nil, raw.inspect
    end
    allow(Rota).to receive(:deployed?).and_return(true)
    expect(described_class.normalize_origin("http://pec.cidade.gov.br")).to be_nil
  end

  it "grava a origem e troca a chave sem nunca devolvê-la" do
    expect(described_class.set_origin(origin: "https://pec.cidade.gov.br")).to be_ok
    expect(described_class.set_origin(origin: "https://pec.cidade.gov.br/x").reason).to eq(:invalid_origin)
    expect(described_class.rotate_key(key: "curta").reason).to eq(:invalid_key)
    expect(described_class.rotate_key(key: "com espaço no meio 0123456789").reason).to eq(:invalid_key)
    result = described_class.rotate_key(key: "chave-nova-0123456789abcdef")
    expect(result).to be_ok
    expect(result.payload.to_s).not_to include("chave-nova")
    setting = PecSetting.current
    expect([ setting.pec_origin, setting.hmac_key, setting.hmac_key_configured? ])
      .to eq([ "https://pec.cidade.gov.br", "chave-nova-0123456789abcdef", true ])
    expect(described_class.set_origin(origin: nil)).to be_ok
    expect(PecSetting.current.pec_origin).to be_nil
  end
end
