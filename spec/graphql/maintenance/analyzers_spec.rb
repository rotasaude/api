require "rails_helper"

# Spec §7: o que um token de serviço NÃO alcança, recusado ANTES de executar.
# Roda o schema direto (sem HTTP): o `context` é montado à mão, do jeito que
# `Maintenance::GraphqlController#execute` monta na requisição de verdade.
RSpec.describe "Maintenance analyzers" do
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "an-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def human_credential
    session = maintainer.maintainer_sessions.create!(user_agent: "spec", ip_address: "127.0.0.1",
                                                       mfa_verified_at: Time.current, last_seen_at: Time.current)
    Maintenance::Credential.session(session)
  end

  def token_credential(access:)
    token, = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: access,
                                     city_slugs: [], expires_at: 10.days.from_now)
    Maintenance::Credential.token(token)
  end

  def context_for(credential)
    { maintainer: credential.maintainer, credential: credential, request_id: SecureRandom.uuid }
  end

  def execute(query, credential:, variables: {})
    Maintenance::Schema.execute(query, context: context_for(credential), variables: variables).to_h
  end

  CREATE_MUTATION = <<~GQL
    mutation($name: String!, $access: String!, $expiresAt: ISO8601DateTime!, $code: String!) {
      createMaintenanceToken(name: $name, access: $access, expiresAt: $expiresAt, code: $code) {
        ok
        secretOnce
        errors { path message }
      }
    }
  GQL

  LIST_QUERY = "{ maintenanceTokens { id } }"

  def create_variables(access: "read")
    { name: "outro", access: access, expiresAt: 5.days.from_now.iso8601, code: "000000" }
  end

  # Item 1: token `read` + mutation → erro citando o escopo, nenhuma escrita.
  #
  # I1 (fix round 2): "nenhuma escrita" continua sendo a asserção CERTA aqui, e
  # agora ela tem um segundo propósito. A recusa passou a ser auditada (spec
  # §9), mas pela CONTROLLER, a partir do erro etiquetado — o analisador roda
  # na análise de toda query, inclusive de leitura, e não pode gravar nada. Um
  # `PlatformEvent` aparecendo neste exemplo, que executa o schema direto, seria
  # exatamente o efeito colateral que se quer manter fora do analisador; a
  # gravação é provada em spec/requests/maintenance/token_auth_spec.rb.
  it "refuses a mutation from a read token before execution, writing nothing itself" do
    credential = token_credential(access: "read")
    tokens_before = MaintenanceToken.count
    events_before = PlatformEvent.count

    result = execute(CREATE_MUTATION, credential: credential, variables: create_variables)

    expect(result["errors"]).to be_present
    expect(result["errors"].map { |e| e["message"] }).to include(a_string_matching(/leitura/))
    expect(result["data"]).to be_nil
    expect(MaintenanceToken.count).to eq(tokens_before)
    expect(PlatformEvent.count).to eq(events_before)
  end

  # I1: o erro CARREGA o que foi recusado, que é o que a controller audita.
  # Sem a etiqueta não há como distinguir, no resultado, uma recusa de escopo
  # de um erro qualquer de validação — e a auditoria da spec §9 não teria como
  # existir sem reimplementar a regra fora dos analisadores.
  it "tags the refusal with the refused root fields, for the audit trail" do
    write_scope = execute(CREATE_MUTATION, credential: token_credential(access: "read"),
                          variables: create_variables)
    human_only = execute(LIST_QUERY, credential: token_credential(access: "read_write"))

    [ write_scope, human_only ].each do |result|
      extensions = result["errors"].filter_map { |e| e["extensions"] }
      expect(extensions.map { |e| e["code"] }).to include(Maintenance::Analyzers::Refusal::CODE)
    end

    expect(Maintenance::Analyzers::Refusal.refused_fields(write_scope)).to eq(%w[createMaintenanceToken])
    expect(Maintenance::Analyzers::Refusal.refused_fields(human_only)).to eq(%w[maintenanceTokens])
  end

  # Item 2: token `read_write` + mutation de token → recusado por HumanOnly
  # (WriteScope não entra aqui: read_write não é read_only?).
  it "refuses a read_write token managing tokens, writing nothing itself" do
    credential = token_credential(access: "read_write")
    tokens_before = MaintenanceToken.count
    events_before = PlatformEvent.count

    result = execute(CREATE_MUTATION, credential: credential, variables: create_variables)

    expect(result["errors"]).to be_present
    expect(result["errors"].map { |e| e["message"] }).to include(a_string_matching(/token de serviço não alcança/))
    expect(result["data"]).to be_nil
    expect(MaintenanceToken.count).to eq(tokens_before)
    expect(PlatformEvent.count).to eq(events_before)
  end

  # Item 3: token `read_write` + mutation NÃO restrita → permitido. Nesta
  # fatia as quatro mutations existentes (inviteMaintainer,
  # deactivateMaintainer, createMaintenanceToken, revokeMaintenanceToken)
  # estão TODAS em HumanOnly::RESTRICTED — não sobra nenhuma mutation de token
  # para provar o caminho positivo. Só o negativo é provado (acima e no item
  # 2); quando esta fatia ganhar uma mutation não restrita, acrescente aqui o
  # positivo simétrico.

  # Item 4: token + campo de raiz restrito de Query → recusado. `auditEvents`
  # ainda não existe (a Task 6 o acrescenta) — a classificação dele já está em
  # RESTRICTED (guarda de cobertura abaixo cobre isso); a recusa em execução
  # ganha exemplo próprio quando o campo existir.
  it "refuses a token reading maintenanceTokens" do
    credential = token_credential(access: "read")

    result = execute(LIST_QUERY, credential: credential)

    expect(result["errors"]).to be_present
    expect(result["data"]).to be_nil
  end

  # Item 5: sessão humana → tudo permitido. Prova positiva de verdade: a query
  # restrita roda sem erro de análise, e a mutation restrita CHEGA no
  # resolver — o erro que volta é de NEGÓCIO (TOTP errado), não de análise.
  it "lets a human session reach every root field, running the resolver" do
    credential = human_credential

    list_result = execute(LIST_QUERY, credential: credential)
    expect(list_result["errors"]).to be_blank

    mutation_result = execute(CREATE_MUTATION, credential: credential, variables: create_variables)
    expect(mutation_result["errors"]).to be_blank
    expect(mutation_result.dig("data", "createMaintenanceToken", "ok")).to be(false)
    expect(mutation_result.dig("data", "createMaintenanceToken", "errors").first["path"]).to eq("code")
  end

  # Item 6: guarda de cobertura — todo campo de raiz de Query e de Mutation
  # está em RESTRICTED ou em TOKEN_ALLOWED. Um campo de raiz novo que não seja
  # classificado num dos dois quebra este exemplo.
  it "classifies every root field as RESTRICTED or TOKEN_ALLOWED" do
    root_fields = Maintenance::Schema.query.fields.keys + Maintenance::Schema.mutation.fields.keys
    classified = Maintenance::Analyzers::HumanOnly::RESTRICTED + Maintenance::Analyzers::HumanOnly::TOKEN_ALLOWED

    expect(root_fields).to all(be_in(classified))
  end

  # Item 7: guarda do escopo por cidade (decisão 1). Nenhum campo de raiz
  # aceita hoje um argumento `slug`/`citySlug`. O dia em que o Plano 4
  # acrescentar `city(slug:)`, este exemplo falha — de propósito: é o lembrete
  # de que ligar `Credential#allows_city?` é responsabilidade de quem escrever
  # aquele campo, não algo que os analisadores desta task já resolvem.
  it "has no root field with a city-scoped argument yet" do
    root_fields = Maintenance::Schema.query.fields.merge(Maintenance::Schema.mutation.fields)

    city_args = root_fields.flat_map { |_name, field| field.arguments.keys }
                           .select { |name| %w[slug citySlug].include?(name) }

    expect(city_args).to be_empty
  end
end
