# spec/services/medications/catmat/client_spec.rb
require "rails_helper"

# ADR 0033 (spec §3): a API aberta do Compras.gov, classe 6505, paginada.
# Falha passageira tenta de novo; falha que dura vira Unavailable; fonte que
# encolhe ou muda no meio vira Incomplete — nunca um catálogo pela metade.
RSpec.describe Medications::Catmat::Client do
  let(:client) { described_class.new(sleeper: ->(_seconds) {}) }

  it "lê todas as páginas com os parâmetros da classe 6505" do
    stub_catmat!
    rows = client.fetch_all
    expect(rows.size).to eq(17)
    expect(rows.first).to have_attributes(catmat_code: 268_856, pdm_code: 8922, pdm_name: "LOSARTANA POTÁSSICA",
                                          description: "LOSARTANA POTÁSSICA, DOSAGEM: 50 MG")
    expect(rows.first.updated_at).to eq(Time.utc(2021, 10, 16, 9, 43, 8, 30_221))
    expect(a_request(:get, MedicationHelpers::CATMAT_URL)
             .with(query: hash_including("codigoClasse" => "6505", "statusItem" => "true", "tamanhoPagina" => "500",
                                         "pagina" => "2"))).to have_been_made.once
  end

  it "falha passageira tenta de novo (até 2 vezes) e segue" do
    stub_catmat!
    page2 = { "resultado" => catmat_rows.last(8), "totalRegistros" => 17, "totalPaginas" => 2, "paginasRestantes" => 0 }
    # O stub mais recente vence: só a página 2 falha duas vezes e depois responde.
    stub_request(:get, MedicationHelpers::CATMAT_URL).with(query: hash_including("pagina" => "2"))
      .to_return({ status: 503, body: "indisponível" }, { status: 503, body: "indisponível" },
                 { status: 200, body: page2.to_json, headers: { "Content-Type" => "application/json" } })
    expect(client.fetch_all.size).to eq(17)
    expect(a_request(:get, MedicationHelpers::CATMAT_URL).with(query: hash_including("pagina" => "2"))).to have_been_made.times(3)
  end

  it "fora do ar depois das novas tentativas → Unavailable, sem o corpo na mensagem" do
    stub_catmat!(pages: { 2 => { status: 503, body: "segredo-do-corpo" } })
    expect { client.fetch_all }.to raise_error(described_class::Unavailable) { |e| expect(e.message).not_to include("segredo") }
  end

  it "timeout e JSON inválido → Unavailable" do
    stub_request(:get, MedicationHelpers::CATMAT_URL).to_timeout
    expect { client.fetch_all }.to raise_error(described_class::Unavailable)
    WebMock.reset!
    stub_request(:get, MedicationHelpers::CATMAT_URL).to_return(status: 200, body: "<html>")
    expect { client.fetch_all }.to raise_error(described_class::Unavailable)
  end

  it "página vazia antes do fim, total que muda ou lido ≠ total → Incomplete" do
    stub_catmat!(pages: { 2 => { "resultado" => [], "totalRegistros" => 17, "totalPaginas" => 2, "paginasRestantes" => 0 } })
    expect { client.fetch_all }.to raise_error(described_class::Incomplete)
    WebMock.reset!
    stub_catmat!(pages: { 2 => { "resultado" => catmat_rows.last(8), "totalRegistros" => 18, "totalPaginas" => 2,
                                 "paginasRestantes" => 0 } })
    expect { client.fetch_all }.to raise_error(described_class::Incomplete)
    WebMock.reset!
    stub_catmat!(catmat_rows.first(16), total: 17)
    expect { client.fetch_all }.to raise_error(described_class::Incomplete)
  end

  it "erro de leitura/protocolo e corpo que não é objeto JSON → Unavailable" do
    [ EOFError, IOError, Net::HTTPBadResponse, Timeout::Error ].each do |error|
      WebMock.reset!
      stub_request(:get, MedicationHelpers::CATMAT_URL).to_raise(error)
      expect { client.fetch_all }.to raise_error(described_class::Unavailable)
    end
    [ "null", "123", "[]", '"texto"' ].each do |body|
      WebMock.reset!
      stub_request(:get, MedicationHelpers::CATMAT_URL).to_return(status: 200, body: body)
      expect { client.fetch_all }.to raise_error(described_class::Unavailable)
    end
  end

  it "o FixtureClient devolve as mesmas linhas, sem rede" do
    rows = Medications::Catmat::FixtureClient.new(Rails.root.join("db/seeds/medications/catmat-dev.json")).fetch_all
    expect(rows.map(&:catmat_code)).to include(268_856, 384_258)
    expect(rows.size).to eq(17)
  end
end
