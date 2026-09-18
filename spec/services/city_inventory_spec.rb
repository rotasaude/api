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

    # consent_terms.version é STRING: MAX de string diria "9". Sem termo, a
    # tela mostra que não há termo (nil), não o fallback das credentials.
    it "reports the current consent term numerically, so \"10\" beats \"9\"" do
      CityConnection.with(healthy) do
        ConsentTerm.create!(version: "9", body: "termo", published_at: Time.current)
        ConsentTerm.create!(version: "10", body: "termo", published_at: Time.current)
      end

      expect(entry_for("saudavel")[:consent_version]).to eq("10")
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

  describe "the access data, which is the point of the screen" do
    # Asserção contra valor LITERAL, não contra CityPublicUrl. Comparar com a
    # mesma função que produz o valor prova consistência, não correção: a
    # primeira versão deste exemplo passava verde enquanto a tela mostrava o
    # wpda na porta do dashboard, porque os dois lados da igualdade tinham o
    # mesmo defeito. Um template errado tem de deixar isto vermelho.
    it "carries the public URL of each frontend, with the port each one really serves on" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
        .and_return("http://%{slug}.localhost:5175")
      allow(ENV).to receive(:[]).with("CITY_WPDA_BASE_TEMPLATE")
        .and_return("http://%{slug}.localhost:5176")

      entry = entry_for("saudavel")

      expect(entry[:urls][:dashboard]).to eq("http://saudavel.localhost:5175/dashboard/")
      expect(entry[:urls][:wpda]).to eq("http://saudavel.localhost:5176/wpda/")
    end

    # O link de impersonate tem de sair no HOST DA CIDADE, não no host da tela:
    # o cookie de sessão é host-only (write_session_cookie nunca seta `domain:`),
    # então um cookie gravado em localhost não vale em curitiba.localhost. A
    # porta é a da API, não a do dashboard — cookie ignora porta, e é isso que
    # faz o cookie gravado em :3030 valer no dashboard em :5175.
    #
    # Valor literal, de novo: comparar com a função que monta a URL provaria
    # consistência, não correção.
    it "points impersonation at the city host on the API port, because the cookie is host-only" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
        .and_return("http://%{slug}.localhost:5175")
      allow(ENV).to receive(:fetch).with("PUBLIC_PORT", anything).and_return("3030")

      expect(entry_for("saudavel")[:urls][:impersonate])
        .to eq("http://saudavel.localhost:3030/dev/impersonate")
    end

    # O modo de falha REAL observado em dev: a env var do wpda não chega ao
    # processo, CityPublicUrl cai no template público por design, e a tela passa
    # a apontar o wpda para a porta do dashboard — um link que abre a aplicação
    # errada sem erro nenhum.
    it "falls back to the shared template when the wpda one is absent, which is how dev broke" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
        .and_return("http://%{slug}.localhost:5175")
      allow(ENV).to receive(:[]).with("CITY_WPDA_BASE_TEMPLATE").and_return(nil)

      expect(entry_for("saudavel")[:urls][:wpda]).to eq("http://saudavel.localhost:5175/wpda/")
    end

    it "lists who can sign in to the city, with the role that decides what they see" do
      CityConnection.with(healthy) do
        user = User.create!(email_address: "admin@saudavel.demo", password: "senha-de-teste-123")
        Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
      end

      entry = entry_for("saudavel")

      expect(entry[:accounts])
        .to contain_exactly(hash_including(email: "admin@saudavel.demo", roles: [ "municipal_admin" ], active: true))
    end

    # Papel revogado é end-date, não DELETE (Membership é append-only). Quem
    # perdeu o papel não deve aparecer como quem ainda entra.
    it "does not credit a revoked role to the account that had it" do
      CityConnection.with(healthy) do
        user = User.create!(email_address: "exmembro@saudavel.demo", password: "senha-de-teste-123")
        Membership.create!(user: user, role: "viewer", granted_at: 1.day.ago, revoked_at: Time.current)
      end

      entry = entry_for("saudavel")

      expect(entry[:accounts]).to contain_exactly(hash_including(email: "exmembro@saudavel.demo", roles: []))
    end

    # A regra central da tela, aplicada ao dado de acesso — que é onde ela é
    # mais tentadora de quebrar. `otp_secret` é `encrypts`: é segredo cifrado,
    # da mesma classe do access_token já excluído. Senha é digest, e digest de
    # senha numa página é material de ataque offline, não diagnóstico.
    it "never carries password or MFA material, only whether MFA is required" do
      CityConnection.with(healthy) do
        User.create!(email_address: "admin@saudavel.demo", password: "senha-de-teste-123",
                     otp_enabled: true, otp_secret: "JBSWY3DPEHPK3PXP")
      end

      account = entry_for("saudavel")[:accounts].first
      serialized = described_class.call.to_s

      expect(account).to include(mfa: true)
      expect(account.keys).not_to include(:password_digest, :otp_secret, :password)
      expect(serialized).not_to include("JBSWY3DPEHPK3PXP")
      expect(serialized).not_to match(/\$2[aby]\$/) # nenhum digest bcrypt na saída
    end
  end

  # O console é da PLATAFORMA e não tem vínculo com cidade: repetir a mesma
  # lista dentro de cada seção sugeriria um vínculo que não existe. Por isso
  # sai por fora do inventário por cidade.
  describe ".console" do
    let!(:operator) do
      Operator.create!(email_address: "dev@local", password: "senha-de-teste-123",
                       otp_enabled: true, otp_secret: "JBSWY3DPEHPK3PXP")
    end

    it "carries the console URL and who signs in to it" do
      console = described_class.console

      expect(console[:url]).to be_present
      expect(console[:operators]).to contain_exactly(hash_including(email: "dev@local", active: true))
    end

    # Mesmo raciocínio de host-only do lado da cidade, aplicado ao console: o
    # cookie de operador (operator_session_id) também é host-only, então o link
    # tem de sair em admin.localhost — e na porta da API, porque é o Rails que
    # grava o cookie e cookie ignora porta.
    it "points console impersonation at the console host on the API port" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ALLOWED_ORIGINS", anything)
        .and_return("http://admin.localhost:5174,http://localhost:5174")
      allow(ENV).to receive(:fetch).with("PUBLIC_PORT", anything).and_return("3030")

      expect(described_class.console[:impersonate])
        .to eq("http://admin.localhost:3030/dev/impersonate_operator")
    end

    # Operador SEMPRE entra com TOTP (Operators::SessionsController exige), ao
    # contrário do usuário da cidade. Sem isso na tela, quem tentar entrar com
    # e-mail e senha conclui que a conta está quebrada.
    it "says that the console always requires TOTP" do
      expect(described_class.console[:mfa_required]).to be(true)
    end

    it "never carries the operator's MFA material" do
      expect(described_class.console.to_s).not_to include("JBSWY3DPEHPK3PXP")
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

    # Para cidade arquivada a URL não é só inútil, é ERRADA: CityResolution
    # checa servable? (status == "active") e devolve 404 para archived, então o
    # link prometeria uma página que o próprio servidor recusa. Não produzir é
    # mais honesto que produzir e esconder na view.
    it "offers no URLs at all, because the host no longer serves this city" do
      expect(entry_for("arquivada")[:urls]).to be_nil
    end
  end

  # Suspensa é diferente de arquivada, e a distinção é deliberada: o banco ainda
  # existe, city:resume a traz de volta, e o host responde 403 temporário em vez
  # de 404. Esconder a URL dela esconderia informação que volta a valer.
  describe "a suspended city" do
    let!(:suspended) do
      create(:city, slug: "suspensa", name: "Cidade Suspensa",
                    database_url: city_database_url("rota_saude_test_city_a"),
                    status: "suspended")
    end

    it "keeps its URLs" do
      expect(entry_for("suspensa")[:urls]).to include(:dashboard, :wpda)
    end
  end
end
