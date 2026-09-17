require "rails_helper"

# Levantamento de configuração de TODAS as cidades, para a tela de manutenção
# de development (GET /maintenance). A tela é dev-only e a rota nem existe em
# test — por isso a inteligência mora aqui, numa classe pura que a suíte
# alcança, e o controller fica com três linhas.
#
# Duas regras que estes exemplos existem para travar:
#
#   1. NADA de segredo e nada de dado de cidadão. database_url, encryption_key
#      e access_token são cifrados com a chave da PLATAFORMA e não têm por que
#      aparecer numa tela de configuração; telefone, mensagem e evidência de
#      consentimento são do cidadão. O inventário devolve configuração e
#      CONTAGEM, nunca conteúdo.
#
#   2. Uma cidade fora do ar não derruba o levantamento. É justamente quando
#      algo está quebrado que a tela precisa abrir — então a falha de uma
#      cidade vira uma linha marcada, com o motivo, ao lado das que
#      responderam.
RSpec.describe CityInventory do
  let!(:healthy) do
    create(:city, slug: "saudavel", name: "Cidade Saudável", uf: "PR",
                  database_url: city_database_url("rota_saude_test_city_a"),
                  status: "active", schema_version: CitySchema.expected_version.to_s)
  end

  def entry_for(slug) = described_class.call.find { |e| e[:slug] == slug }

  describe "the platform side, which costs no city connection" do
    it "lists the catalog fields of every registered city" do
      entry = entry_for("saudavel")

      expect(entry).to include(slug: "saudavel", name: "Cidade Saudável", uf: "PR", status: "active")
    end

    it "reports whether the city is behind the schema this code expects" do
      healthy.update!(schema_version: "1")

      entry = entry_for("saudavel")

      expect(entry[:behind]).to be(true)
      expect(entry[:expected_version]).to eq(CitySchema.expected_version)
    end

    it "includes the WhatsApp channel without its access token" do
      CityChannel.create!(city: healthy, phone_number_id: "PNID-1", waba_id: "WABA-1",
                          display_phone_number: "+55 41 99999-0001", access_token: "segredo-que-nao-pode-vazar")

      entry = entry_for("saudavel")

      expect(entry[:channel]).to include(phone_number_id: "PNID-1", waba_id: "WABA-1", active: true)
      expect(entry[:channel].keys).not_to include(:access_token)
    end
  end

  describe "the per-city side, which opens one connection per city" do
    it "reads the profile and the counts from inside the city database" do
      CityConnection.with(healthy) do
        CityProfile.create!(name: "Cidade Saudável", uf: "PR", ibge_code: "4106902")
        AlertRecipient.create!(channel: "email", destination: "alertas@saudavel.demo", escalation_order: 1)
        Conversation.create!(phone: "+5541988881111", state: "greeting")
      end

      entry = entry_for("saudavel")

      expect(entry[:profile]).to include(name: "Cidade Saudável", uf: "PR", ibge_code: "4106902")
      expect(entry[:alert_recipients]).to contain_exactly(hash_including(destination: "alertas@saudavel.demo"))
      expect(entry[:counts]).to include(conversations: 1)
    end

    # A contagem prova que a conversa existe; o telefone dela é dado do cidadão
    # e não tem lugar numa tela de configuração. Este exemplo falha se alguém
    # acrescentar "só mais um campo" ao levantamento.
    it "never carries citizen content, only counts" do
      CityConnection.with(healthy) { Conversation.create!(phone: "+5541988882222", state: "greeting") }

      serialized = described_class.call.to_s

      expect(serialized).not_to include("5541988882222")
    end
  end

  describe "a city that cannot be reached" do
    # A falha é INJETADA, não provocada por uma URL realmente inalcançável, por
    # duas razões que só apareceram ao rodar:
    #
    #   1. Uma URL ruim de verdade registra um pool de verdade, e o
    #      teardown_fixtures do harness (use_transactional_fixtures) opera sobre
    #      os pools inscritos — inclusive o que não conecta. O erro escapava do
    #      `around` e derrubava exemplos vizinhos, sem relação com a cidade.
    #
    #   2. A mensagem do PG não é contrato: se num dia ela não trouxer a
    #      credencial, o exemplo da redação passaria sem exercitar redação
    #      nenhuma. Controlando o texto, a senha está garantidamente lá e o
    #      exemplo só passa se CitySchema.redact tirá-la.
    let!(:broken) do
      create(:city, slug: "quebrada", name: "Cidade Quebrada",
                    database_url: city_database_url("rota_saude_test_city_a"),
                    status: "active", schema_version: CitySchema.expected_version.to_s)
    end

    before do
      allow(CityConnection).to receive(:with).and_call_original
      allow(CityConnection).to receive(:with).with(broken).and_raise(
        ActiveRecord::DatabaseConnectionError.new(
          'connection to server failed for "postgres://rota_city_quebrada:senha-secreta@10.0.0.9:5432/rota_saude_city_quebrada"'
        )
      )
    end

    it "marks it as unreachable instead of raising" do
      expect { described_class.call }.not_to raise_error

      expect(entry_for("quebrada")).to include(reachable: false)
    end

    it "still lists the healthy city alongside it" do
      expect(entry_for("saudavel")).to include(reachable: true)
    end

    # A mensagem de uma PG::ConnectionBad traz a URL de conexão INTEIRA, com a
    # senha do role da cidade. Sem redação, a tela de "não mostra segredo"
    # publicaria justamente o segredo, e só no caminho de erro — o menos
    # exercitado e o mais provável de passar despercebido.
    it "redacts the credentials out of the failure it reports" do
      entry = entry_for("quebrada")

      expect(entry[:error]).to be_present
      expect(entry[:error]).not_to include("senha-secreta")
    end
  end

  describe "a city with no database to reach" do
    let!(:archived) do
      create(:city, slug: "arquivada", name: "Cidade Arquivada",
                    database_url: "postgres://rota_city_arquivada:x@127.0.0.1:1/ja_apagado",
                    status: "archived")
    end

    # Offboarding apaga banco e role: tentar conectar é garantia de erro, e um
    # erro previsto não é diagnóstico nenhum. O skip é o que mantém a tela
    # legível conforme cidades saem.
    it "does not attempt a connection, and says why" do
      entry = entry_for("arquivada")

      expect(entry[:reachable]).to be(false)
      expect(entry[:skipped]).to be(true)
    end
  end
end
