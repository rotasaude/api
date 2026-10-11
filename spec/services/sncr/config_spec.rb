# spec/services/sncr/config_spec.rb
require "rails_helper"

# ADR 0034 (spec §3; Desvio 2): credenciais da PLATAFORMA por ambiente —
# sncr.{base_url, auth_url, maintainer_cnpj} (o SNCR não tem client_id nem
# secret). O simulado só fora de produção, com FAKE_SNCR_URL. Nunca URL ou
# CNPJ em inspect.
RSpec.describe Sncr::Config do
  let(:creds) do
    { "base_url" => "https://api-gateway.prd.apps.anvisa.gov.br/api-sncr/api/v1/", "auth_url" => "https://sncr-api.apps.anvisa.gov.br/api/v1",
      "maintainer_cnpj" => "11.222.333/0001-81" }
  end

  it "real: as três chaves, sem barra final, CNPJ normalizado" do
    allow(described_class).to receive(:credentials).and_return(creds)
    real = described_class.real
    expect(real).to have_attributes(base_url: "https://api-gateway.prd.apps.anvisa.gov.br/api-sncr/api/v1",
                                    auth_url: "https://sncr-api.apps.anvisa.gov.br/api/v1",
                                    public_auth_url: "https://sncr-api.apps.anvisa.gov.br/api/v1",
                                    cnpj: "11222333000181", simulated: false)
    expect(real.inspect).not_to include("anvisa", "11222333000181")
    expect(described_class.configured?).to be(true)
  end

  it "faltando chave, CNPJ inválido ou http em produção: não configurado" do
    allow(described_class).to receive(:credentials).and_return(creds.except("auth_url"))
    expect(described_class.real).to be_nil
    allow(described_class).to receive(:credentials).and_return(creds.merge("maintainer_cnpj" => "11222333000182"))
    expect(described_class.real).to be_nil
    allow(described_class).to receive(:credentials).and_return(creds.merge("base_url" => "http://x.gov.br"))
    expect(described_class.real(env: "production")).to be_nil
    allow(described_class).to receive(:credentials).and_return({})
    expect(described_class.configured?).to be(false)
  end

  it "simulado só com o interruptor no catálogo do ambiente e FAKE_SNCR_URL; a cidade com sncr_mock usa só ele" do
    # Sem stub_sncr_mock!: ele monta o FakeSncr::App (Task 6); aqui só as variáveis importam.
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_SNCR_URL").and_return(ControlledPrescriptionHelpers::FAKE_SNCR_BASE)
    allow(ENV).to receive(:[]).with("FAKE_SNCR_PUBLIC_URL").and_return("http://localhost:8092/api/v1")
    expect(described_class.simulated).to have_attributes(base_url: ControlledPrescriptionHelpers::FAKE_SNCR_BASE,
                                                         public_auth_url: "http://localhost:8092/api/v1",
                                                         cnpj: described_class::SIMULATED_CNPJ, simulated: true)
    expect(described_class.simulated(env: "production")).to be_nil
    expect(described_class.simulated_available?).to be(true)

    allow(described_class).to receive(:credentials).and_return(creds)
    city = controlled_city!(mock: true)
    expect(described_class.for_city(city).simulated).to be(true)
    Platform::Features.set!(city: city, key: "sncr_mock", enabled: false, maintainer: ledi_maintainer!)
    expect(described_class.for_city(city).simulated).to be(false)
  end

  it "Checks.status: configurado, alcançável pela última conversa real, simulado disponível" do
    allow(described_class).to receive(:credentials).and_return(creds)
    SncrCheck.where(target: "real").delete_all
    expect(Sncr::Checks.status).to include(configured: true, reachable: false, last_check_at: nil)
    Sncr::Checks.record!(described_class.real, ok: true)
    expect(Sncr::Checks.status).to include(reachable: true, last_check_at: be_present)
  end
end
