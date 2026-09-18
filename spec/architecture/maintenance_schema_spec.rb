require "rails_helper"

# Guarda de schema pedida pela spec §10: "lista explícita de tipos e campos
# (campo novo quebra até ser declarado) e recusa de nomes proibidos".
#
# As duas metades têm propósitos diferentes:
#
#   1. A LISTA obriga quem acrescenta campo a declará-lo aqui — é o momento em
#      que alguém olha para o campo novo e pergunta se ele expõe segredo ou dado
#      de cidadão. Uma guarda que só recusa nomes proibidos não faz essa
#      pergunta: `notes` passa liso.
#   2. Os FRAGMENTOS recusam as famílias de nome que a spec §8 lista como "nunca
#      entram no schema" — segredo (digest, secret, token, key, url) e conteúdo
#      de cidadão (phone, body, raw, evidence, response, context).
RSpec.describe "Maintenance GraphQL schema" do
  # tipo => campos, em camelCase, exatamente como o schema publica.
  EXPECTED_TYPES = {
    "Query" => %w[me maintenanceTokens auditEvents cities city],
    "Maintainer" => %w[id emailAddress createdAt],
    "Mutation" => %w[inviteMaintainer deactivateMaintainer createMaintenanceToken revokeMaintenanceToken],
    "InviteMaintainerPayload" => %w[ok errors],
    "DeactivateMaintainerPayload" => %w[ok errors],
    "MaintenanceToken" => %w[id maintainerId name access citySlugs expiresAt revokedAt lastUsedAt],
    "CreateMaintenanceTokenPayload" => %w[ok errors secretOnce],
    "RevokeMaintenanceTokenPayload" => %w[ok errors],
    "AuditEvent" => %w[name module outcome occurredAt maintainerId login correlationId],
    "UserError" => %w[path message],
    "CitySummary" => %w[slug name uf status schemaVersion schemaBehind createdAt],
    "City" => %w[slug name uf status schemaVersion schemaBehind createdAt channel
                 profile consentTermVersion protocols alertRecipients accounts counts operations],
    "CityChannel" => %w[phoneNumberId wabaId displayPhoneNumber active],
    "CityProfile" => %w[name uf ibgeCode],
    "ProtocolDefinition" => %w[name version status],
    "AlertRecipient" => %w[channel destination escalationOrder],
    "CityAccount" => %w[login roles active mfaEnrolled],
    "CityCounts" => %w[users conversations triages inboundMessages reportSnapshots consents],
    "CityOperations" => %w[domainEvents reportSnapshots dashboardMetrics failedJobs],
    "DomainEvent" => %w[name occurredAt publishedAt],
    "ReportSnapshot" => %w[id createdAt expiresAt],
    "DashboardMetric" => %w[dimension period label value computedAt],
    "FailedJob" => %w[className failedAt errorClass]
  }.freeze

  FORBIDDEN_FRAGMENTS = %w[phone body raw evidence response context digest secret token key url].freeze
  # Cada fragmento carrega o próprio IGNORECASE: interpolar Regexp.union numa
  # literal `/.../i` embute `(?-mix:...)`, e o `-i` de dentro VENCE o `i` de
  # fora — `accessToken` escapava. Foi o auto-teste lá embaixo que pegou isso.
  FORBIDDEN_NAME = Regexp.union(FORBIDDEN_FRAGMENTS.map { |f| Regexp.new(f, Regexp::IGNORECASE) })

  # Nomes que CONTÊM fragmento proibido e mesmo assim são publicados, cada um
  # revisado: esta fatia administra tokens, e chamá-los de outra coisa esconderia
  # o que são. A lista é NOMINAL e exata — nunca por fragmento.
  ALLOWED_NAMES = %w[
    MaintenanceToken maintenanceTokens createMaintenanceToken revokeMaintenanceToken
    CreateMaintenanceTokenPayload RevokeMaintenanceTokenPayload secretOnce
    phoneNumberId displayPhoneNumber
  ].freeze
  # phoneNumberId/displayPhoneNumber (P3, Task 2): o número institucional de
  # WhatsApp Business da cidade — mostrado a cidadãos, já publicado em
  # /maintenance — não é telefone de cidadão. As restrições globais proíbem
  # telefone de CIDADÃO, não o canal da própria cidade.

  def declared_types
    Maintenance::Schema.types
                       .reject { |name, _type| name.start_with?("__") }
                       .select { |_name, type| type.respond_to?(:fields) && type.kind.fields? }
  end

  it "publishes exactly the declared types" do
    expect(declared_types.keys).to match_array(EXPECTED_TYPES.keys)
  end

  EXPECTED_TYPES.each do |type_name, fields|
    it "publishes exactly the declared fields of #{type_name}" do
      type = Maintenance::Schema.types.fetch(type_name)

      expect(type.fields.keys).to match_array(fields)
    end
  end

  it "publishes no type or field whose name is of a forbidden family" do
    offenders = declared_types.flat_map do |type_name, type|
      [ type_name, *type.fields.keys ].reject { |name| ALLOWED_NAMES.include?(name) }
                                       .select { |name| name.match?(FORBIDDEN_NAME) }
    end

    expect(offenders).to be_empty
  end

  # Auto-teste da guarda: um padrão quebrado (fragmento com typo, Regexp.union
  # vazia) deixaria o exemplo acima verde para sempre, sem recusar nada.
  it "matches the names it exists to refuse" do
    %w[accessToken passwordDigest otpSecret databaseUrl encryptionKey
       phoneNumber messageBody rawPayload consentEvidence triageResponse triageContext]
      .each { |name| expect(name).to match(FORBIDDEN_NAME) }

    %w[me id emailAddress createdAt slug status].each { |name| expect(name).not_to match(FORBIDDEN_NAME) }
  end

  # Task 5, Step 1 — guarda "sem conteúdo de cidadão".
  #
  # EXPECTED_TYPES já obriga declarar todo campo novo, e FORBIDDEN_FRAGMENTS já
  # recusa boa parte dos nomes de segredo. O que falta é a afirmação SEPARADA
  # de que NENHUM tipo novo de cidade publica CONTEÚDO: os fragmentos de
  # FORBIDDEN_FRAGMENTS não cobrem "message"/"text" (são fragmentos de SEGREDO
  # — digest, secret, token, key, url —, não de conteúdo de cidadão), então um
  # campo String chamado `messageText` ou `triageAnswerText` passaria ileso
  # pelos dois exemplos acima. Mascaramento de conteúdo de cidadão está
  # ADIADO (ver o registro de 2026-09-17 citado nas restrições globais do
  # plano) — até lá, ESTE exemplo é o que segura a porta.
  #
  # Método, não constante de topo (P1): uma constante aqui viveria em Object,
  # igual a EXPECTED_TYPES acima — comportamento herdado deste arquivo, não
  # repetido por escolha em código novo.
  def content_fragments = %w[body raw evidence response context phone message text].freeze
  def content_name = Regexp.union(content_fragments.map { |f| Regexp.new(f, Regexp::IGNORECASE) })

  # Ruling P11: exceção SEPARADA de ALLOWED_NAMES, e QUALIFICADA por tipo —
  # "Type.field", nunca o nome do campo sozinho. Isentar `message` por NOME
  # (em ALLOWED_NAMES, que é por fragmento em qualquer tipo) isentaria
  # `message` em todo tipo de cidade que vier a existir; isentar só o PAR
  # "UserError.message" isenta exatamente o campo revisado, e nenhum outro.
  #
  # UserError.message é o texto de validação que as PRÓPRIAS mutations desta
  # fatia escrevem (inviteMaintainer, deactivateMaintainer,
  # createMaintenanceToken, revokeMaintenanceToken — ex.: "e-mail já
  # cadastrado", "código inválido") — nunca conteúdo de cidadão. Revisado em
  # 2026-09-18 (ruling P11, achado ao rodar esta guarda pela primeira vez).
  def content_exempt_fields = %w[UserError.message].freeze

  # Só campo STRING importa aqui — um Int chamado `messageCount` não carrega
  # texto nenhum. `field.type.unwrap` despe NonNull/List e devolve o tipo
  # base (checado ao vivo contra graphql-ruby 2.6 antes de escrever isto:
  # `field.type.unwrap == GraphQL::Types::String` para um campo `String`,
  # não-nulo ou não).
  def string_offenders(type_name, type)
    type.fields.select { |_name, field| field.type.unwrap == GraphQL::Types::String }
        .keys
        .reject { |name| ALLOWED_NAMES.include?(name) }
        .select { |name| name.match?(content_name) }
        .map { |name| "#{type_name}.#{name}" }
        .reject { |qualified_name| content_exempt_fields.include?(qualified_name) }
  end

  it "publishes no String field named after citizen content, in any published type" do
    offenders = declared_types.flat_map { |type_name, type| string_offenders(type_name, type) }

    expect(offenders).to be_empty
  end

  # Auto-teste da guarda acima: prova que o CAMINHO DE CÓDIGO (não só a regex)
  # pega um campo sintético — um tipo de verdade, publicado com um campo
  # String de verdade chamado `messageText`, do jeito que graphql-ruby o
  # devolveria em `declared_types`.
  it "catches a synthetic String field named after citizen content" do
    offender_type = Class.new(Maintenance::Types::BaseObject) do
      graphql_name "SyntheticCitizenContentOffender"
      field :message_text, String, null: true
    end

    expect(string_offenders("SyntheticCitizenContentOffender", offender_type))
      .to eq([ "SyntheticCitizenContentOffender.messageText" ])
  end

  # Auto-teste da exceção (P11): a isenção é do PAR "UserError.message", não
  # do nome `message` sozinho. Um tipo sintético DIFERENTE com um campo
  # chamado exatamente `message` (mesmo nome, mesmo fragmento) continua sendo
  # pego — só assim a exceção não vira, de fato, uma entrada em ALLOWED_NAMES
  # disfarçada.
  it "exempts only the type-qualified UserError.message pair, never the bare field name" do
    offender_type = Class.new(Maintenance::Types::BaseObject) do
      graphql_name "AnotherTypeWithMessage"
      field :message, String, null: true
    end

    expect(string_offenders("AnotherTypeWithMessage", offender_type))
      .to eq([ "AnotherTypeWithMessage.message" ])
    expect(string_offenders("UserError", Maintenance::Schema.types.fetch("UserError"))).to be_empty
  end

  # Task 5, Step 2 — guarda do orçamento de CONEXÃO (não só de cidade).
  #
  # Analyzers::CityBudget já limita a 5 o número de OCORRÊNCIAS do campo
  # `city` por operação (alias e fragmento contam igual — ver o comentário
  # lá). O que falta é o número de vezes que isso abre `CityConnection.with`
  # de VERDADE: a Task 3 escolheu a estratégia POR CAMPO RESOLVIDO — um
  # `CityConnection.with` por campo de dentro do banco (`CityType#inside`),
  # não um por cidade — e a Task 4 resolve `counts` numa entrada e as quatro
  # listas de `operations` em OUTRA (um só `inside` cobre as quatro). Uma
  # operação no teto (5 ocorrências de `city`) pedindo `counts` e `operations`
  # em cada uma abre EXATAMENTE 10 conexões: nunca 5 ("uma por cidade", que
  # seria a estratégia que a Task 3 NÃO escolheu) nem mais que 10 (seria "uma
  # por sub-campo" — as quatro listas de `operations` abririam quatro cada).
  context "city connection budget" do
    let(:password) { "s3nha-forte-1" }
    let!(:maintainer) do
      Maintainer.create!(email_address: "sch-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    end

    # Sessão humana (nunca token): o que está sob teste aqui é a CONTAGEM de
    # conexão, não o escopo — um token exigiria arranjar city_slugs à parte,
    # sem acrescentar nada à pergunta que este exemplo faz.
    def human_credential(maintainer)
      session = maintainer.maintainer_sessions.create!(user_agent: "spec", ip_address: "127.0.0.1",
                                                        mfa_verified_at: Time.current, last_seen_at: Time.current)
      Maintenance::Credential.session(session)
    end

    # Roda o schema direto (sem HTTP), do mesmo jeito que
    # spec/graphql/maintenance/analyzers_spec.rb já faz — o `context` é
    # montado à mão, como Maintenance::GraphqlController#execute monta numa
    # requisição de verdade.
    def execute(query, credential:)
      Maintenance::Schema.execute(query, context: { maintainer: credential.maintainer, credential: credential,
                                                     request_id: SecureRandom.uuid }).to_h
    end

    # Mesmo arranjo de spec/requests/maintenance/cities_spec.rb: cidade de
    # harness registrada direto no catálogo de plataforma.
    def register_city!(test_city)
      return if City.exists?(slug: test_city.slug)

      City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                  database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                  schema_version: CitySchema.expected_version.to_s)
    end

    # Ruling P2/T5: nenhuma URL nova, nenhuma cidade nova — só TEST_CITY_A/B,
    # cada uma "reentrando" a MESMA sessão de banco que o `around` global já
    # abriu (spec/support/city_test_databases.rb), aliasada 5 vezes. O
    # orçamento é sobre OCORRÊNCIAS do campo `city`, não sobre slug distinto —
    # é a mesma regra que "counts aliases and fragments toward the same
    # budget" já prova do lado do analisador (spec/requests/maintenance/
    # city_spec.rb) — então 5 alias bastam para tocar o teto com conexões de
    # VERDADE, sem inventar banco nenhum.
    def city_budget_query(field_selection)
      slugs = [ TEST_CITY_A.slug, TEST_CITY_A.slug, TEST_CITY_A.slug, TEST_CITY_B.slug, TEST_CITY_B.slug ]
      selections = slugs.each_with_index.map { |slug, i| %(c#{i}: city(slug: "#{slug}") { #{field_selection} }) }
      "{ #{selections.join(' ')} }"
    end

    before do
      register_city!(TEST_CITY_A)
      register_city!(TEST_CITY_B)
    end

    it "opens exactly one CityConnection.with per city-database field resolved, at the 5-city budget" do
      allow(CityConnection).to receive(:with).and_call_original

      result = execute(city_budget_query("counts { users } operations { failedJobs { className } }"),
                       credential: human_credential(maintainer))

      expect(result["errors"]).to be_nil
      expect(CityConnection).to have_received(:with).exactly(10).times
    end

    # A outra metade da mesma guarda: campo de PLATAFORMA (slug/status estão
    # na City, channel está em CityChannel — nenhum dos dois é dentro do banco
    # da cidade, ver comentário em CityType#channel) não abre conexão nenhuma,
    # nem uma vez, mesmo tocando o teto de 5 ocorrências do campo `city`.
    it "opens no city connection for platform-only fields (slug, status, channel)" do
      allow(CityConnection).to receive(:with).and_call_original

      result = execute(city_budget_query("slug status channel { active }"), credential: human_credential(maintainer))

      expect(result["errors"]).to be_nil
      expect(CityConnection).not_to have_received(:with)
    end
  end

  # Task 5, Step 3 — guarda do CAMINHO ÚNICO (ruling P5).
  #
  # O escopo do token é aplicado em `city(slug:)` (QueryType#city,
  # Credential#allows_city?) — é o ÚNICO ponto da fatia que decide se uma
  # cidade é alcançável. Um segundo caminho para o banco da cidade, em
  # QUALQUER outro resolver, contornaria esse escopo inteiro sem nunca passar
  # por `city(slug:)`. A guarda tem duas metades, porque nenhuma das duas
  # sozinha prova a outra: um arquivo pode não chamar CityConnection/CityReader
  # e ainda assim um TIPO alcançável por fora de City devolver um tipo que os
  # chama por trás (herança, delegação); e a checagem de alcançabilidade
  # sozinha não pegaria alguém que chamasse CityConnection.with direto, por
  # fora de CityReader, num arquivo qualquer da fatia.
  context "single path into a city database" do
    # Hoje, só CityType chama CityReader.call (que por sua vez chama
    # CityConnection.with — ver app/queries/maintenance/city_reader.rb). Task
    # 3/4 não extraíram nenhum helper compartilhado; se uma task futura
    # extrair um, o arquivo dele entra aqui.
    def city_subtree_files
      %w[app/graphql/maintenance/types/city_type.rb]
    end

    # Varre TODO app/graphql/maintenance/ por ocorrência textual das duas
    # chamadas que abrem o banco de uma cidade. CityReader.call já ENVOLVE
    # CityConnection.with, então bastam os dois nomes para cobrir tanto quem
    # chama CityReader quanto quem, um dia, tentasse pular CityReader e
    # chamar CityConnection direto.
    def city_connection_call_offenders
      pattern = /CityConnection\.with|CityReader\.call/
      allowed = city_subtree_files

      Dir.glob(Rails.root.join("app/graphql/maintenance/**/*.rb")).filter_map do |path|
        relative = Pathname.new(path).relative_path_from(Rails.root).to_s
        next if allowed.include?(relative)

        relative if File.read(path).match?(pattern)
      end
    end

    it "calls CityConnection.with / CityReader.call only from the city-subtree file(s)" do
      expect(city_connection_call_offenders).to be_empty
    end

    # Fecho transitivo dos tipos alcançados a partir dos campos de DENTRO do
    # banco de City. `channel` fica de fora de propósito: mora na PLATAFORMA
    # (ver comentário em CityType#channel), nunca abre conexão — incluí-lo
    # aqui obrigaria CityChannel a só ser alcançável por City, o que não é a
    # regra que este plano pede.
    def city_inner_field_names
      %w[profile counts operations protocols alertRecipients accounts]
    end

    def city_db_type_names
      city_type = Maintenance::Schema.types.fetch("City")
      seeds = city_type.fields.select { |name, _| city_inner_field_names.include?(name) }
                       .values.map { |field| field.type.unwrap.graphql_name }

      closure = Set.new
      queue = seeds.dup
      until queue.empty?
        name = queue.shift
        next unless closure.add?(name)

        type = Maintenance::Schema.types[name]
        next unless type.respond_to?(:fields) && type.kind.fields?

        type.fields.each_value { |field| queue << field.type.unwrap.graphql_name }
      end

      # Só tipo OBJETO importa: o fecho também alcança String/Int/Boolean/ID/…
      # (todo tipo devolve escalar em algum campo) — um escalar não é "alcança
      # o banco de cidade", é só o tipo de um valor, publicado em toda parte.
      closure.select { |name| (t = Maintenance::Schema.types[name]) && t.respond_to?(:fields) && t.kind.fields? }
    end

    # A metade que a checagem de arquivo, sozinha, não prova: nenhum tipo do
    # fecho acima pode ser devolvido por um campo de fora do próprio fecho (+
    # City). Cobre ROOT field (Query/Mutation) e qualquer outro tipo publicado
    # — sem depender de nome de arquivo, só de FORMA do schema.
    it "returns every city-database type only from within the City subtree" do
      city_types = city_db_type_names
      allowed_referrers = city_types + [ "City" ]

      offenders = declared_types.flat_map do |type_name, type|
        next [] if allowed_referrers.include?(type_name)

        type.fields.select { |_name, field| city_types.include?(field.type.unwrap.graphql_name) }
            .keys.map { |field_name| "#{type_name}.#{field_name}" }
      end

      expect(offenders).to be_empty
    end
  end
end
