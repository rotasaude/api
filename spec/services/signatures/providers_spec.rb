require "rails_helper"

# ADR 0032 (spec §3): credenciais da PLATAFORMA por PSC; sem as três chaves o
# PSC não está habilitado. Nada de segredo em inspect. Revisão do ADR: com o
# interruptor signature_psc_mock a cidade usa SÓ o PSC simulado; sem ele, só os
# reais do ambiente; em produção o simulado nunca existe.
RSpec.describe Signatures::Providers do
  let(:real_credentials) do
    { "vidaas" => { "client_id" => "a", "client_secret" => "SEGREDO-X", "base_url" => "https://v.test/" },
      "birdid" => { "client_id" => "b", "base_url" => "https://b.test" },
      "outro" => { "client_id" => "c", "client_secret" => "d", "base_url" => "https://o.test" } }
  end

  def psc_mock_on!(city)
    Platform::Features.set!(city: city, key: Signatures::PscMock::KEY, enabled: true, maintainer: ledi_maintainer!)
  end

  def fake_psc_env!(url: "https://psc-simulated.test/", public_url: "http://localhost:5190/")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_PSC_URL").and_return(url)
    allow(ENV).to receive(:[]).with("FAKE_PSC_PUBLIC_URL").and_return(public_url)
  end

  it "só os PSC do catálogo com client_id, client_secret e base_url" do
    allow(described_class).to receive(:credentials).and_return(real_credentials)
    expect(described_class.configured.map(&:key)).to eq([ "vidaas" ])
    expect(described_class.configured?("birdid")).to be(false)
    expect(described_class.find("outro")).to be_nil
    expect(described_class.find("vidaas").base_url).to eq("https://v.test")
    expect(described_class.find("vidaas").inspect).not_to include("SEGREDO-X")
  end

  it "o catálogo e a lista do ambiente são só os 5 reais (simulated fica de fora)" do
    expect(described_class::CATALOG).to eq(SignerCertificate::REAL_PROVIDERS)
    expect(described_class::CATALOG).not_to include("simulated")
    expect(described_class::LABELS).to include("simulated" => "PSC simulado")
  end

  it "redirect_uri: uma por cidade, a rota de retorno do dashboard dela" do
    city = clinical_city!
    expect(described_class.redirect_uri(city)).to eq("#{CityPublicUrl.dashboard(city)}signature/callback")
    expect(described_class.redirect_uri(city)).to end_with("/dashboard/signature/callback")
    expect(described_class.redirect_uri(city)).to start_with(CityPublicUrl.base(city))
  end

  it "a checagem fica na plataforma e nunca levanta" do
    described_class.record_check!("vidaas", ok: false)
    described_class.record_check!("vidaas", ok: true)
    expect(described_class.checks["vidaas"]).to have_attributes(last_check_ok: true)
    allow(SignatureProviderCheck).to receive(:upsert).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { described_class.record_check!("vidaas", ok: true) }.not_to raise_error
  end

  it "a tabela de checagens aceita simulated e recusa chave fora da lista" do
    described_class.record_check!("simulated", ok: true)
    expect(SignatureProviderCheck.find_by(provider: "simulated")).to have_attributes(last_check_ok: true)
    expect(described_class.checks).not_to have_key("simulated")
    expect(SignatureProviderCheck.record!("outro", ok: true)).to be_nil
    expect(SignatureProviderCheck.exists?(provider: "outro")).to be(false)
  end

  describe "resolução pela cidade (signature_psc_mock)" do
    before do
      allow(described_class).to receive(:credentials).and_return(real_credentials)
      fake_psc_env!
    end

    it "interruptor LIGADO: só o simulated, mesmo com credenciais reais no ambiente" do
      city = signature_city!
      psc_mock_on!(city)
      expect(described_class.for_city(city).map(&:key)).to eq([ "simulated" ])
      expect(described_class.configured.map(&:key)).to eq([ "simulated" ]) # Current.city = city
      expect(described_class.configured?("vidaas")).to be(false)
      expect(described_class.find("vidaas", city: city)).to be_nil
      simulated = described_class.find("simulated", city: city)
      expect(simulated).to have_attributes(base_url: "https://psc-simulated.test", authorize_base_url: "http://localhost:5190")
      expect(described_class.configured_in_environment?("vidaas")).to be(true) # o maintenance não olha cidade
      expect(described_class.configured_in_environment?("simulated")).to be(false)
      expect(Signatures::Psc::Client.for("simulated").inspect).to include("simulated")
      expect { Signatures::Psc::Client.for("vidaas") }.to raise_error(Signatures::Psc::Unavailable)
    end

    it "interruptor DESLIGADO: só os reais" do
      city = signature_city!
      expect(described_class.for_city(city).map(&:key)).to eq([ "vidaas" ])
      expect(described_class.find("simulated", city: city)).to be_nil
      expect(described_class.configured?("simulated", city: city)).to be(false)
      expect(described_class.configured?("vidaas", city: city)).to be(true)
      expect { Signatures::Psc::Client.for("simulated", city: city) }.to raise_error(Signatures::Psc::Unavailable)
    end

    it "sem cidade no contexto: só os reais" do
      expect(described_class.for_city(nil).map(&:key)).to eq([ "vidaas" ])
    end

    it "em produção o simulated nunca existe, nem com a linha do interruptor ligada" do
      city = signature_city!
      psc_mock_on!(city)
      expect(described_class.simulated(env: "production")).to be_nil
      expect(described_class.for_city(city, env: "production").map(&:key)).to eq([ "vidaas" ])
      expect(described_class.find("simulated", city: city, env: "production")).to be_nil
    end

    it "sem FAKE_PSC_URL o simulated não existe (interruptor ligado = nenhum PSC)" do
      fake_psc_env!(url: nil, public_url: nil)
      city = signature_city!
      psc_mock_on!(city)
      expect(described_class.simulated).to be_nil
      expect(described_class.for_city(city)).to eq([])
    end
  end

  it "o simulated usa o client_id/secret do FakePsc::App (sem carregar lib/fake_psc no app)" do
    expect(described_class::SIMULATED_CLIENT_ID).to eq(FakePsc::App::CLIENT_ID)
    expect(described_class::SIMULATED_CLIENT_SECRET).to eq(FakePsc::App::CLIENT_SECRET)
    expect(File.read(Rails.root.join("app/services/signatures/providers.rb"))).not_to match(/require.*fake_psc/)
  end
end
