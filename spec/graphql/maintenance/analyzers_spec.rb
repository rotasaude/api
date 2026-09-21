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

  # O Plano 3 deixou aqui um alarme: "nenhum campo de raiz tem argumento de
  # cidade ainda". O Plano 4 criou `city(slug:)`, então o alarme cumpriu o
  # papel e vira a guarda definitiva — todo campo de raiz com argumento de
  # cidade PRECISA passar por Credential#allows_city?.
  #
  # Plano 5: em Mutation, o escopo não mora em cada resolver — mora na base
  # CityMutation (`in_city` → `refuse_out_of_scope!` → allows_city?). Então a
  # guarda exige, para todo campo de Mutation com `citySlug`, que a classe da
  # mutation herde de CityMutation, e que a base de fato consulte o escopo.
  it "routes every city-scoped root field through the credential's city scope" do
    city_argument = ->(field) { (field.arguments.keys & %w[slug citySlug]).any? }

    query_scoped = Maintenance::Schema.query.fields.select { |_name, field| city_argument.call(field) }
    expect(query_scoped.keys).to contain_exactly("city")
    query_scoped.each_key do |name|
      source = File.read(Rails.root.join("app/graphql/maintenance/types/query_type.rb"))
      expect(source).to match(/def #{name}\b.*?allows_city\?/m),
                        "#{name} aceita argumento de cidade e não consulta allows_city?"
    end

    mutation_scoped = Maintenance::Schema.mutation.fields.select { |_name, field| city_argument.call(field) }
    expect(mutation_scoped.keys).to include("saveProtocolDraft")
    mutation_scoped.each do |name, field|
      expect(field.resolver).to be < Maintenance::Mutations::CityMutation,
                                "#{name} aceita citySlug e não herda de CityMutation"
    end
    base = File.read(Rails.root.join("app/graphql/maintenance/mutations/city_mutation.rb"))
    expect(scope_checked_before_audit?(method_body(base, "in_city"))).to be(true),
                                                                       "in_city não consulta o escopo antes de auditar"
    expect(method_body(base, "refuse_out_of_scope!")).to include("allows_city?")
  end

  # Corpo de um método de CityMutation: da linha `def <nome>` até a próxima
  # linha `def ` na MESMA indentação (exclusive). Um regex preguiçoso sobre o
  # arquivo inteiro atravessava para o método seguinte — e casava
  # `refuse_out_of_scope!` na definição dele, não na chamada (fix round 1).
  def method_body(source, name)
    lines = source.lines
    start = lines.index { |line| line.match?(/\A\s*def #{Regexp.escape(name)}(?=[\s(]|$)/) }
    raise "def #{name} não encontrado" if start.nil?

    indent = lines[start][/\A\s*/]
    finish = lines[(start + 1)..].index { |line| line.start_with?("#{indent}def ") }
    lines[start...(finish ? start + 1 + finish : lines.size)].join
  end

  # Só CÓDIGO conta (um comentário citando o método não é chamada), e a
  # chamada de escopo tem de vir antes da tentativa gravada.
  def scope_checked_before_audit?(body)
    code = body.lines.reject { |line| line.strip.start_with?("#") }.join
    scope_at = code.index("refuse_out_of_scope!(")
    audit_at = code.index("audited(")

    !scope_at.nil? && !audit_at.nil? && scope_at < audit_at
  end

  it "catches an in_city that audits without consulting the scope first" do
    without_scope = <<~RUBY
      def in_city(city_slug:)
        audited(event: "x") { :ok }
      end

      def refuse_out_of_scope!(city_slug)
        credential.allows_city?(city_slug)
      end
    RUBY
    scope_after = <<~RUBY
      def in_city(city_slug:)
        audited(event: "x") { :ok }
        refuse_out_of_scope!(city_slug)
      end
    RUBY

    expect(scope_checked_before_audit?(method_body(without_scope, "in_city"))).to be(false)
    expect(scope_checked_before_audit?(method_body(scope_after, "in_city"))).to be(false)
  end

  # O comportamento, não só o texto: uma credencial que NÃO alcança a cidade
  # recebe CITY_OUT_OF_SCOPE antes de qualquer auditoria, validação ou
  # conexão — e a recusa leva a etiqueta que o controller audita
  # (Refusal::CODES / refusedFields). Humano alcança toda cidade e token é
  # barrado antes por HumanOnly; por isso a credencial é stubada aqui.
  describe "city scope on mutations" do
    def save_draft(city_slug, definition)
      <<~GQL
        mutation { saveProtocolDraft(citySlug: #{city_slug.to_json}, definition: #{definition}) { ok errors { path } } }
      GQL
    end

    it "refuses a city outside the credential's scope before auditing or writing anything" do
      credential = human_credential
      allow(credential).to receive(:allows_city?).and_return(false)
      expect(Protocols::SaveDraft).not_to receive(:call)
      expect(CityConnection).not_to receive(:with)

      result = execute(save_draft("curitiba", '{name: "dengue", version: 1}'), credential: credential)

      expect(result.dig("data", "saveProtocolDraft")).to be_nil
      expect(result["errors"].map { |e| e.dig("extensions", "code") }).to eq([ "CITY_OUT_OF_SCOPE" ])
      expect(Maintenance::Analyzers::Refusal.refused_fields(result)).to eq([ "saveProtocolDraft" ])
      expect(PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")).to be_empty
    end

    it "answers CITY_OUT_OF_SCOPE before judging the slug or the definition" do
      credential = human_credential
      allow(credential).to receive(:allows_city?).and_return(false)

      result = execute(save_draft("Não É Slug", '"nem objeto"'), credential: credential)

      expect(result["errors"].map { |e| e.dig("extensions", "code") }).to eq([ "CITY_OUT_OF_SCOPE" ])
      expect(PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")).to be_empty
    end
  end

  # Plano 5, Decisão 7: uma mutation de cidade abre uma conexão como um
  # `city(slug:)` — conta no mesmo teto. Uma operação só tem UM tipo de raiz
  # (a análise visita só a operação selecionada), então o teto de mutation se
  # prova com mutations: 6 escritas de cidade numa operação são recusadas
  # antes de executar; 5 passam pelo analisador.
  describe "city budget on mutations" do
    def save_drafts(count)
      fields = Array.new(count) do |i|
        %(s#{i}: saveProtocolDraft(citySlug: "nenhuma", definition: {name: "x", version: 1}) { ok })
      end
      "mutation { #{fields.join(' ')} }"
    end

    it "counts every root Mutation field that takes citySlug toward the 5-city budget" do
      expect(Protocols::SaveDraft).not_to receive(:call)

      result = execute(save_drafts(6), credential: human_credential)

      expect(result["data"]).to be_nil
      expect(result["errors"].map { |e| e.dig("extensions", "code") }).to eq([ "CITY_BUDGET_EXCEEDED" ])
      expect(PlatformEvent.where(name: "maintenance.protocol.draft_saved")).to be_empty
    end

    it "lets five city writes through the analyzer" do
      result = execute(save_drafts(5), credential: human_credential)

      expect(result["errors"]).to be_nil
      expect(result["data"].values).to all(eq("ok" => false))
    end
  end

  # Task 5, Step 3 — step-up onde se aprova ou põe em uso (spec §7). Duas
  # listas EXPLÍCITAS, do mesmo espírito de HumanOnly::RESTRICTED/TOKEN_ALLOWED
  # acima: uma mutation de cidade nova que não esteja em nenhuma das duas faz
  # o exemplo de classificação falhar, antes de qualquer pergunta sobre
  # step-up de verdade.
  describe "step-up on the acts that approve or put a version in use" do
    STEP_UP_REQUIRED = %w[publishProtocol activateProtocol retireProtocol revertProtocolActivation].freeze
    STEP_UP_EXEMPT = %w[saveProtocolDraft submitProtocolForReview].freeze

    def city_mutation_fields
      Maintenance::Schema.mutation.fields.select { |_name, field| field.resolver < Maintenance::Mutations::CityMutation }
    end

    def code_only(path)
      File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
    end

    it "classifies every city mutation as requiring step-up or explicitly exempt" do
      unclassified = city_mutation_fields.keys - STEP_UP_REQUIRED - STEP_UP_EXEMPT

      expect(unclassified).to be_empty
    end

    it "declares argument :code and calls step_up! on every mutation that approves or activates" do
      city_mutation_fields.select { |name, _field| STEP_UP_REQUIRED.include?(name) }.each do |name, field|
        expect(field.arguments.keys).to include("code"), "#{name} does not declare argument :code"

        path = field.resolver.instance_method(:resolve).source_location.first
        expect(code_only(path)).to include("step_up!("), "#{name} does not call step_up!"
      end
    end

    it "asks for no step-up to save a draft or submit it for review" do
      city_mutation_fields.select { |name, _field| STEP_UP_EXEMPT.include?(name) }.each do |name, field|
        path = field.resolver.instance_method(:resolve).source_location.first
        expect(code_only(path)).not_to include("step_up!("), "#{name} unexpectedly calls step_up!"
      end
    end

    # Auto-teste da guarda de cobertura: uma mutation de cidade nova
    # ("archiveProtocol") que não entrasse em nenhuma das duas listas sobra na
    # subtração — é exatamente o que o exemplo de classificação acima checa
    # contra a lista de verdade.
    it "catches a new city mutation left off both lists" do
      known = STEP_UP_REQUIRED + STEP_UP_EXEMPT
      field_names_with_a_new_one = city_mutation_fields.keys + [ "archiveProtocol" ]

      expect(field_names_with_a_new_one - known).to eq([ "archiveProtocol" ])
    end
  end
end
