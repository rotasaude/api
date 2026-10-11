# spec/services/sncr/client_spec.rb
require "rails_helper"

# ADR 0034 (spec §3; Desvios 1–3): o api monta o login, troca o session_id
# pelo token no servidor (Origin do host da cidade) e pede o bloco com os
# nomes reais do Manual; cada recusa vira um erro com nome; o token nunca
# aparece em inspect; toda chamada registra a checagem.
RSpec.describe Sncr::Client do
  before do
    controlled_city!(mock: false)
    stub_sncr_real!
  end

  let(:client) { described_class.for(Current.city) }
  let(:callback) { "#{CityPublicUrl.dashboard(Current.city)}sncr/callback" }
  let(:origin) { CityPublicUrl.base(Current.city) }

  def token = client.exchange(session_id: fake_sncr.approve!(callback), origin: origin)
  def block(kind: "rce", registration: "12345", uf: "PR", token: self.token)
    client.request_block(token: token, kind: kind, council: "CRM", registration: registration, uf: uf)
  end

  it "monta o login no auth público com client_url e state" do
    url = client.login_url(client_url: callback, state: "st-1")
    expect(url).to start_with("#{ControlledPrescriptionHelpers::SNCR_REAL_AUTH}/auth/login?")
    expect(URI.decode_www_form(URI(url).query).to_h).to eq("client_url" => callback, "state" => "st-1")
    expect(client).to have_attributes(simulated?: false, provider: "sncr")
  end

  it "troca o session_id no servidor e pede o bloco: 1.000 números no mesmo prefixo" do
    result = block
    expect(result.quantity).to eq(1000)
    numbers = Sncr::Numbers.expand(result.first, result.last, result.quantity)
    expect(numbers.size).to eq(1000)
    expect(numbers).to all(match(SncrNumber::FORMAT))
    expect(result.inspect).not_to include(result.first)
    expect(token.inspect).not_to include(*fake_sncr.issued_tokens)
    expect(SncrCheck.last("real")).to have_attributes(last_check_ok: true)
  end

  it "session_id vencido, repetido ou de outro Origin" do
    session_id = fake_sncr.approve!(callback)
    client.exchange(session_id: session_id, origin: origin)
    expect { client.exchange(session_id: session_id, origin: origin) }.to raise_error(described_class::Expired)
    expect { client.exchange(session_id: fake_sncr.approve!(callback), origin: "http://outra.localhost:5189") }
      .to raise_error(described_class::Unavailable)
    late = fake_sncr.approve!(callback)
    fake_sncr.clock = -> { Time.now + 31 }
    expect { client.exchange(session_id: late, origin: origin) }.to raise_error(described_class::Expired)
  end

  it "token vencido, limite do mês, esgotamento, inscrição divergente" do
    fresh = token
    fake_sncr.clock = -> { Time.now + 31 }
    expect { block(token: fresh) }.to raise_error(described_class::Expired)
    fake_sncr.clock = -> { Time.now }
    3.times { block }
    expect { block }.to raise_error(described_class::LimitReached)
    fake_sncr.exhausted_ufs << "SC"
    expect { block(uf: "SC") }.to raise_error(described_class::Exhausted)
    fake_sncr.mismatch_documents << "777"
    expect { block(registration: "777") }.to raise_error(described_class::RegistrationMismatch)
  end

  it "queda, recusa de conexão e resposta sem bloco válido: Unavailable, checagem falsa" do
    fake_sncr.failures << 503
    expect { token }.to raise_error(described_class::Unavailable)
    expect(SncrCheck.last("real")).to have_attributes(last_check_ok: false)
    fake_sncr.failures << :refused
    expect { token }.to raise_error(described_class::Unavailable)
    fresh = token
    stub_request(:post, "#{ControlledPrescriptionHelpers::SNCR_REAL_BASE}/numeracoes/receita-especial-retencao")
      .to_return(status: 201, body: { inicio: "2610.1-41.0000001", fim: "2610.2-41.0001000", quantidade: 1000 }.to_json)
    expect { block(token: fresh) }.to raise_error(described_class::Unavailable)
  end

  it "sem configuração: Unavailable; com sncr_mock, o simulado" do
    allow(Sncr::Config).to receive(:credentials).and_return({})
    expect { described_class.for(Current.city) }.to raise_error(described_class::Unavailable)
    stub_sncr_mock!
    Platform::Features.set!(city: Current.city, key: "sncr_mock", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.for(Current.city)).to have_attributes(simulated?: true, provider: "sncr_simulated")
  end

  it "Numbers.expand recusa prefixos diferentes, faixa invertida ou maior que 1.000" do
    expect(Sncr::Numbers.expand("2610.1-41.0000001", "2610.1-41.0000003", 3)).to eq(%w[2610.1-41.0000001 2610.1-41.0000002 2610.1-41.0000003])
    expect(Sncr::Numbers.expand("2610.1-41.0000001", "2610.2-41.0000003", 3)).to be_nil
    expect(Sncr::Numbers.expand("2610.1-41.0000005", "2610.1-41.0000001", 5)).to be_nil
    expect(Sncr::Numbers.expand("2610.1-41.0000001", "2610.1-41.0001001", 1001)).to be_nil
    expect(Sncr::Numbers.expand("2610.1-41.0000001", "2610.1-41.0000003", 1000)).to be_nil
  end
end
