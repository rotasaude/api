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
    "Query" => %w[me maintainers maintenanceTokens auditEvents cities city],
    "Maintainer" => %w[id emailAddress active enrolled createdAt],
    "Mutation" => %w[inviteMaintainer deactivateMaintainer createMaintenanceToken revokeMaintenanceToken
                     saveProtocolDraft submitProtocolForReview publishProtocol
                     activateProtocol retireProtocol revertProtocolActivation],
    "InviteMaintainerPayload" => %w[ok errors],
    "DeactivateMaintainerPayload" => %w[ok errors],
    "MaintenanceToken" => %w[id maintainerId name access citySlugs expiresAt revokedAt lastUsedAt],
    "CreateMaintenanceTokenPayload" => %w[ok errors secretOnce],
    "RevokeMaintenanceTokenPayload" => %w[ok errors],
    "SaveProtocolDraftPayload" => %w[ok errors],
    "SubmitProtocolForReviewPayload" => %w[ok errors],
    "PublishProtocolPayload" => %w[ok errors],
    "ActivateProtocolPayload" => %w[ok errors],
    "RetireProtocolPayload" => %w[ok errors],
    "RevertProtocolActivationPayload" => %w[ok errors revertedToVersion],
    "AuditEvent" => %w[name module outcome occurredAt maintainerId login correlationId],
    "UserError" => %w[path message],
    "CitySummary" => %w[slug name uf status schemaVersion schemaBehind createdAt],
    "City" => %w[slug name uf status schemaVersion schemaBehind createdAt channel
                 profile consentTermVersion protocols protocolVersions alertRecipients accounts counts operations],
    "CityChannel" => %w[phoneNumberId wabaId displayPhoneNumber active],
    "CityProfile" => %w[name uf ibgeCode],
    "ProtocolDefinition" => %w[name version status],
    "ProtocolVersion" => %w[name version status publicationSignatures publicationMissing
                            activationSignatures activationMissing eligibleReviewers revertible
                            revertTargetVersion],
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
  ].freeze

  # Task 5: strip_comments/code_only/city_mutation_fields vêm de
  # spec/support/maintenance_city_mutations.rb — código sem comentário, sempre
  # da mesma forma que as outras guardas deste projeto usam (uma delas foi
  # enganada por comentário antes: ver o controlador desta task).
  include MaintenanceCityMutationSpecHelpers

  def declared_types
    Maintenance::Schema.types
                       .reject { |name, _type| name.start_with?("__") }
                       .select { |_name, type| type.respond_to?(:fields) && type.kind.fields? }
  end

  # M3 (achado na revisão final do Plano 4): phoneNumberId/displayPhoneNumber
  # moravam em ALLOWED_NAMES — isenção por NOME, em QUALQUER tipo. Isso isenta
  # um `phoneNumberId` que apareça amanhã num tipo que NÃO seja o canal da
  # própria cidade (ex.: um campo de cidadão disfarçado). Mesmo padrão de
  # `content_exempt_fields`/P11 abaixo: a isenção é do PAR "Type.field", nunca
  # do nome sozinho — só CityChannel.phoneNumberId e
  # CityChannel.displayPhoneNumber (ruling P3, Task 2) ficam de fora: o número
  # institucional de WhatsApp Business da cidade, mostrado a cidadãos e já
  # publicado em /maintenance — não é telefone de CIDADÃO, que é o que as
  # restrições globais proíbem.
  def forbidden_name_exempt_fields
    %w[CityChannel.phoneNumberId CityChannel.displayPhoneNumber]
  end

  def forbidden_name_offenders(type_name, type)
    [ type_name, *type.fields.keys ].reject { |name| ALLOWED_NAMES.include?(name) }
                                     .select { |name| name.match?(FORBIDDEN_NAME) }
                                     .reject { |name| forbidden_name_exempt_fields.include?("#{type_name}.#{name}") }
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
    offenders = declared_types.flat_map { |type_name, type| forbidden_name_offenders(type_name, type) }

    expect(offenders).to be_empty
  end

  # Auto-teste da isenção (M3): o PAR "CityChannel.phoneNumberId" está isento,
  # mas o mesmo nome de campo, sozinho, continua proibido em QUALQUER outro
  # tipo — senão a isenção seria, de fato, uma entrada em ALLOWED_NAMES
  # disfarçada, exatamente o problema que motivou trocar uma pela outra.
  it "exempts only CityChannel's own phoneNumberId/displayPhoneNumber, never the bare field name" do
    # "AnotherType", não "AnotherTypeWithPhoneNumberId": o NOME do tipo
    # sintético não pode, ele mesmo, conter um fragmento proibido — senão o
    # tipo entraria na lista de ofensores e o teste provaria a coisa errada.
    offender_type = Class.new(Maintenance::Types::BaseObject) do
      graphql_name "AnotherType"
      field :phone_number_id, String, null: true
    end

    expect(forbidden_name_offenders("AnotherType", offender_type)).to eq([ "phoneNumberId" ])
    expect(forbidden_name_offenders("CityChannel", Maintenance::Schema.types.fetch("CityChannel"))).to be_empty
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
  #
  # CityChannel.phoneNumberId/displayPhoneNumber (M3) entram aqui TAMBÉM: o
  # fragmento "phone" está em content_fragments (conteúdo de cidadão), não só
  # em FORBIDDEN_FRAGMENTS (segredo) — a mesma isenção qualificada por tipo
  # de forbidden_name_exempt_fields vale para as duas guardas, ou o campo
  # passaria numa e quebraria na outra.
  def content_exempt_fields = (%w[UserError.message] + forbidden_name_exempt_fields).freeze

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
    # I1 (achado na revisão final do Plano 4): a varredura original só olhava
    # app/graphql/maintenance/ — um campo de raiz futuro apoiado num objeto de
    # app/queries/maintenance/ ou app/services/maintenance/ que percorresse
    # cidades (ou chamasse CityInventory) contornaria o escopo de
    # city(slug:) com toda guarda verde. As três árvores são "alcançáveis pela
    # API de manutenção" — é onde um segundo caminho poderia nascer.
    def city_reachable_trees
      %w[app/graphql/maintenance app/queries/maintenance app/services/maintenance]
    end

    def city_reachable_files
      city_reachable_trees.flat_map { |tree| Dir.glob(Rails.root.join(tree, "**/*.rb")) }
                           .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
    end

    # Cada chamada só é permitida nos arquivos que a encerram: CityReader
    # (leitura) e CityWriter (escrita, Plano 5) são os dois que chamam
    # CityConnection.with de verdade; CityType
    # (app/graphql/maintenance/types/city_type.rb) é quem chama
    # CityReader.call, e a base CityMutation
    # (app/graphql/maintenance/mutations/city_mutation.rb) é quem chama
    # CityWriter.call. Isentar um arquivo inteiro para TODAS as chamadas (como
    # uma versão anterior desta guarda fazia) deixaria um terceiro arquivo
    # livre para chamar CityConnection.with direto, contanto que ficasse fora
    # da lista — qualificar por PAR (chamada, arquivo) fecha isso.
    def allowed_call_sites
      {
        "CityConnection.with" => %w[app/queries/maintenance/city_reader.rb app/queries/maintenance/city_writer.rb],
        "CityReader.call" => %w[app/graphql/maintenance/types/city_type.rb],
        "CityWriter.call" => %w[app/graphql/maintenance/mutations/city_mutation.rb]
      }
    end

    def call_site_offenders(files)
      files.filter_map do |relative, content|
        offends = allowed_call_sites.any? do |pattern, allowed_files|
          content.include?(pattern) && allowed_files.exclude?(relative)
        end
        relative if offends
      end
    end

    def city_connection_call_offenders
      call_site_offenders(city_reachable_files.map { |relative| [ relative, File.read(Rails.root.join(relative)) ] })
    end

    it "calls CityConnection.with / CityReader.call / CityWriter.call only from the files that own each" do
      expect(city_connection_call_offenders).to be_empty
    end

    # Auto-teste da guarda: uma escrita que abrisse a cidade por fora da base
    # (uma mutation chamando CityWriter.call direto, sem o escopo e a
    # auditoria de CityMutation) é pega — e o mesmo texto na base, não.
    it "catches a stray CityWriter.call outside the CityMutation base" do
      stray = "Maintenance::CityWriter.call(city) { Protocols::SaveDraft.call(definition: d, by: a) }"

      expect(call_site_offenders([ [ "app/graphql/maintenance/mutations/stray.rb", stray ] ]))
        .to eq([ "app/graphql/maintenance/mutations/stray.rb" ])
      expect(call_site_offenders([ [ "app/graphql/maintenance/mutations/city_mutation.rb", stray ] ])).to be_empty
    end

    # A mesma varredura, pelo nome de quem NUNCA deveria aparecer em CÓDIGO
    # destas árvores: CityInventory é a leitura equivalente da tela
    # /maintenance (dev-only, ver global-constraints.md) — chamá-la da API de
    # manutenção acoplaria as duas e abriria um caminho que não passa por
    # city(slug:) nem pelo escopo do token. Só linha de CÓDIGO conta — um
    # comentário explicando "mesma escolha/lista de CityInventory" (como já
    # existem em city_type.rb e city_reader.rb) é documentação, não a
    # referência que esta guarda existe para recusar.
    def city_inventory_offenders
      city_reachable_files.select { |relative| code_only(Rails.root.join(relative)).include?("CityInventory") }
    end

    it "never references CityInventory from the maintenance API trees" do
      expect(city_inventory_offenders).to be_empty
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

    # A metade que nem o scan de arquivo nem o fecho de tipos provam: que
    # RESOLVER a query de verdade, hoje, não abre conexão nenhuma fora de
    # `city`. Roda CADA campo de raiz (exceto `city`, que É o caminho) por si
    # só, com um token de serviço — a mesma credencial que um campo futuro
    # despistado precisaria aceitar para vazar. `FIELD_SELECTIONS` obriga
    # quem acrescentar um campo de raiz sem argumento a decidir a seleção
    # mínima aqui (mesmo espírito de EXPECTED_TYPES): um campo esquecido
    # levanta, não passa em silêncio.
    context "every non-city root Query field, run through a service token" do
      let(:password) { "s3nha-forte-1" }
      let!(:maintainer) do
        Maintainer.create!(email_address: "1p-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                           otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
      end

      def token_credential(maintainer)
        token, = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                         city_slugs: [], expires_at: 10.days.from_now)
        Maintenance::Credential.token(token)
      end

      def execute(query, credential:)
        Maintenance::Schema.execute(query, context: { maintainer: credential.maintainer, credential: credential,
                                                       request_id: SecureRandom.uuid }).to_h
      end

      # Seleção mínima por campo — só os que hoje existem em Query além de
      # `city`. Nenhum deles exige argumento (audit_events só tem opcionais),
      # então nenhum precisa ser pulado; um campo de raiz futuro sem entrada
      # aqui quebra `root_query_field_names` abaixo, de propósito.
      def field_selections
        { "me" => "{ id }", "maintainers" => "{ id }", "maintenanceTokens" => "{ id }", "auditEvents" => "{ name }",
          "cities" => "{ slug }" }
      end

      def root_query_field_names
        Maintenance::Schema.types.fetch("Query").fields.keys - [ "city" ]
      end

      it "opens no city connection, whether the token reaches the field or is refused before it" do
        allow(CityConnection).to receive(:with).and_call_original
        credential = token_credential(maintainer)

        root_query_field_names.each do |field_name|
          selection = field_selections.fetch(field_name) do
            raise "add a minimal selection for the new root Query field #{field_name.inspect} to " \
                  "field_selections above, so this guard actually exercises it"
          end

          execute("{ #{field_name} #{selection} }", credential: credential)
        end

        expect(CityConnection).not_to have_received(:with)
      end
    end
  end

  # Task 5, Step 1 — toda mutation de cidade é auditada e passa por command.
  #
  # As três coisas que o brief pede, lidas do ARQUIVO da classe (código sem
  # comentário, ver code_only acima — uma guarda satisfeita por comentário não
  # serve, e este projeto já foi enganado assim uma vez):
  #   1. chama `in_city(`;
  #   2. o `event:` que ela passa está em MaintenanceAudit::NAMES (nome errado
  #      ou ausente falha aqui, não só em runtime dentro de MaintenanceAudit.record);
  #   3. nenhuma das formas de persistência direta que uma mutation de cidade
  #      não deveria usar (a escrita é sempre command → CityWriter, nunca
  #      ActiveRecord direto no resolver).
  context "every city mutation is audited and passes through a command" do
    # M1 (fix round 1, achado do revisor): a forma anterior casava `\bNOME\b`
    # dos dois lados — e "_" É caractere de palavra em Ruby regex, então
    # `update_columns`, `delete_all`, `destroy_all` e `insert_all` nunca
    # fechavam a fronteira direita (o "_columns"/"_all" que vem depois é tudo
    # caractere de palavra) e passavam ilesos. A lista agora tem uma entrada
    # por IDENTIFICADOR Ruby de verdade, não por raiz: `\bNOME\b` sozinho já
    # pega a forma com `!` de graça, porque "!" NÃO é caractere de palavra —
    # fecha a fronteira do lado direito sozinho ("update" casa "update!",
    # "create" casa "create!", "insert" casa "insert!" etc.). Só as formas com
    # sufixo que É caractere de palavra (`_all`, `_column(s)`,
    # `_attribute(s)`, `_by`) precisam de entrada própria — e essa entrada,
    # por ter o mesmo motivo (o que vem depois do sufixo é "(", espaço ou "!",
    # nunca outro caractere de palavra), também cobre a forma com `!` do
    # sufixo de graça (`insert_all!` casa em `\binsert_all\b`).
    #
    # `find_or_create_by`/`create_or_find_by` (e as formas com `!`) entram
    # como identificador PRÓPRIO — não por conterem a palavra "create": dentro
    # de `find_or_create_by`, "create" está colado por "_" dos dois lados, e
    # `\bcreate\b` não teria fronteira nenhuma ali (mesma razão de
    # `update_columns` acima). Sem a entrada própria, um finder que cria na
    # ausência passaria como leitura.
    #
    # `toggle!`/`increment!`/`decrement!` são a única exceção OPOSTA: a forma
    # SEM `!` (`toggle`, `increment`, `decrement`) só muda o atributo em
    # memória — não persiste —, então exigir o `!` na própria regex evita
    # marcar a forma que não é escrita.
    def persistence_call_names
      %w[
        update update_all update_column update_columns update_attribute update_attributes
        save create find_or_create_by create_or_find_by
        insert insert_all upsert upsert_all
        destroy destroy_all destroy_by
        delete delete_all delete_by
        touch
      ]
    end

    # Métodos, não constante (P1): uma constante definida dentro de um bloco
    # `context` vaza para Object. A lista de NOMES é fixa
    # (persistence_call_names acima); o array de Regexp é reconstruído a cada
    # chamada.
    def persistence_patterns
      persistence_call_names.map { |name| /\b#{Regexp.escape(name)}\b/ } +
        [ /\btoggle!/, /\bincrement!/, /\bdecrement!/ ]
    end

    # Não-guloso até o primeiro `event:` depois de `in_city(` — a ordem dos
    # kwargs nas seis mutations sempre põe `event:` cedo, mas o regex não
    # depende disso: só do primeiro `event: "..."` que aparecer depois do
    # `in_city(` de verdade.
    def in_city_event(code)
      code.match(/in_city\(.*?event:\s*"([^"]+)"/m)&.captures&.first
    end

    def mutation_offenders
      city_mutation_fields.filter_map do |name, field|
        path = field.resolver.instance_method(:resolve).source_location.first
        code = code_only(path)

        reasons = []
        reasons << "não chama in_city(" unless code.include?("in_city(")

        event = in_city_event(code)
        if event.nil? || MaintenanceAudit::NAMES.exclude?(event)
          reasons << "evento #{event.inspect} não está em MaintenanceAudit::NAMES"
        end

        offending_calls = persistence_patterns.select { |pattern| code.match?(pattern) }
        reasons << "persiste direto (#{offending_calls.map(&:source).join(', ')})" if offending_calls.any?

        "#{name}: #{reasons.join('; ')}" if reasons.any?
      end
    end

    it "calls in_city with a declared audit event, and never persists on its own" do
      expect(mutation_offenders).to be_empty
    end

    # Auto-teste: prova que o CAMINHO (código sem comentário) pega uma escrita
    # direta e um evento fora da lista, e que um `update!` só em COMENTÁRIO —
    # explicando, por exemplo, "não fazemos protocol.update! aqui" — não conta.
    it "ignores a persistence call mentioned only in a comment, but catches a real one" do
      commented = <<~RUBY
        # nunca protocol.update!(status: "active") aqui
        in_city(event: "maintenance.protocol.draft_saved") { }
      RUBY
      real = <<~RUBY
        in_city(event: "maintenance.protocol.draft_saved") { }
        protocol.update!(status: "active")
      RUBY

      expect(persistence_patterns.none? { |p| strip_comments(commented).match?(p) }).to be(true)
      expect(persistence_patterns.any? { |p| strip_comments(real).match?(p) }).to be(true)
    end

    # M1 (fix round 1) — auto-teste permanente: uma linha de exemplo por
    # variante da lista, incluindo as quatro que o revisor confirmou que a
    # forma anterior deixava passar (`update_columns`, `delete_all`,
    # `destroy_all`, `insert_all`) e as duas formas com `!` que dependem da
    # fronteira "palavra → não-palavra" em vez de entrada própria
    # (`update!`, `create!`). Cada linha é o tipo de chamada que apareceria
    # de verdade num resolver que tentasse persistir por fora do command.
    def flagged?(source) = persistence_patterns.any? { |pattern| source.match?(pattern) }

    {
      "update(" => 'protocol.update(status: "draft")',
      "update!" => 'protocol.update!(status: "draft")',
      "update_all" => 'ProtocolDefinition.where(name: n).update_all(status: "active")',
      "update_column" => 'protocol.update_column(:status, "active")',
      "update_columns" => 'protocol.update_columns(status: "active", version: 2)',
      "update_attribute" => 'protocol.update_attribute(:status, "active")',
      "update_attributes" => 'protocol.update_attributes(status: "active")',
      "save" => "protocol.save",
      "save!" => "protocol.save!",
      "create(" => 'ProtocolDefinition.create(name: n, version: v)',
      "create!" => 'ProtocolDefinition.create!(name: n, version: v)',
      "find_or_create_by" => 'ProtocolDefinition.find_or_create_by(name: n, version: v)',
      "find_or_create_by!" => 'ProtocolDefinition.find_or_create_by!(name: n, version: v)',
      "create_or_find_by" => 'ProtocolDefinition.create_or_find_by(name: n, version: v)',
      "insert" => "ProtocolDefinition.insert(attrs)",
      "insert!" => "ProtocolDefinition.insert!(attrs)",
      "insert_all" => "ProtocolDefinition.insert_all([attrs])",
      "insert_all!" => "ProtocolDefinition.insert_all!([attrs])",
      "upsert" => "ProtocolDefinition.upsert(attrs)",
      "upsert_all" => "ProtocolDefinition.upsert_all([attrs])",
      "destroy" => "version.destroy",
      "destroy!" => "version.destroy!",
      "destroy_all" => "version.destroy_all",
      "destroy_by" => "ProtocolDefinition.destroy_by(name: n)",
      "delete" => "version.delete",
      "delete_all" => "ProtocolDefinition.where(name: n).delete_all",
      "delete_by" => "ProtocolDefinition.delete_by(name: n)",
      "toggle!" => "protocol.toggle!(:featured)",
      "increment!" => "protocol.increment!(:views)",
      "decrement!" => "protocol.decrement!(:views)",
      "touch" => "protocol.touch"
    }.each do |label, source|
      it "flags a #{label} call as persistence" do
        expect(flagged?(source)).to be(true)
      end
    end

    # A metade oposta: a forma SEM `!` de toggle/increment/decrement não
    # persiste (só muda o atributo em memória) — exigir o "!" evita marcar
    # exatamente essa forma.
    it "does not flag the bang-less form of toggle/increment/decrement, which does not persist" do
      expect(flagged?("protocol.toggle(:featured)")).to be(false)
      expect(flagged?("protocol.increment(:views)")).to be(false)
      expect(flagged?("protocol.decrement(:views)")).to be(false)
    end

    # Leitura que não pode disparar a guarda — inclui `find_by`/`where` (as
    # próprias mutations os usam por dentro dos commands, nunca no resolver,
    # mas a guarda tem de continuar limpa se algum dia aparecessem aqui) e o
    # identificador `updated_at`, que CONTÉM "update" como substring mas não é
    # chamada nenhuma — só um nome de coluna.
    it "does not flag a read, or 'updated_at' as a bare identifier" do
      read = 'ProtocolDefinition.where(name: n).find_by(version: v)'
      identifier = "protocol.updated_at"

      expect(flagged?(read)).to be(false)
      expect(flagged?(identifier)).to be(false)
    end

    it "catches an event that is not declared in MaintenanceAudit::NAMES" do
      undeclared = <<~RUBY
        in_city(city_slug: city_slug, event: "maintenance.protocol.made_up", module_name: "protocol") { }
      RUBY

      expect(in_city_event(undeclared)).to eq("maintenance.protocol.made_up")
      expect(MaintenanceAudit::NAMES.exclude?(in_city_event(undeclared))).to be(true)
    end
  end

  # Task 5, Step 2 — o mantenedor nunca assina nem cria quem aprova (Decisão 1,
  # global-constraints.md). Duas metades: nenhum arquivo da API de manutenção
  # chama os três commands de aprovação, e nenhum campo de Mutation tem
  # "sign"/"signature" no nome — o segundo pega um nome que escondesse uma
  # assinatura atrás de um verbo diferente, sem chamar Sign de verdade.
  context "the maintainer never signs nor creates who approves" do
    def forbidden_approval_calls = %w[Protocols::Sign GrantRole InviteMember]

    def maintenance_api_files
      Dir.glob(Rails.root.join("app/graphql/maintenance/**/*.rb")).map(&:to_s)
    end

    # Casa `call` só quando NÃO é seguido de caractere de identificador — sem
    # isso, "Protocols::Sign" (regra 1) também batia dentro de
    # "Protocols::Signatures", o módulo de LEITURA que CityType passou a
    # chamar (protocolVersions, spec de assinaturas §5) e que nunca assina
    # nem cria quem aprova.
    def approval_hits(code) = forbidden_approval_calls.select { |call| code.match?(/#{Regexp.escape(call)}(?!\w)/) }

    def signish(field_names) = field_names.select { |name| name.match?(/sign/i) }

    def approval_call_offenders
      maintenance_api_files.filter_map do |path|
        hits = approval_hits(code_only(path))
        next if hits.empty?

        "#{Pathname.new(path).relative_path_from(Rails.root)}: #{hits.join(', ')}"
      end
    end

    it "never calls Protocols::Sign, GrantRole or InviteMember from the maintenance API" do
      expect(approval_call_offenders).to be_empty
    end

    it "publishes no Mutation field named after signing" do
      expect(signish(Maintenance::Schema.mutation.fields.keys)).to be_empty
    end

    # Auto-teste: passa pelos MESMOS métodos da guarda de verdade
    # (approval_hits / signish) — um detector quebrado quebra os dois. Prova
    # que a chamada é pega dentro de código de verdade e não num comentário,
    # e que um nome de campo que só CONTÉM "Signature" é pego no meio de
    # nomes que não assinam.
    it "catches a stray approval call and a field name that merely contains 'signature'" do
      stray = <<~RUBY
        # Protocols::Sign nunca é chamado daqui
        GrantRole.call(user: u, role: "protocol_reviewer")
      RUBY

      expect(approval_hits(strip_comments(stray))).to eq([ "GrantRole" ])
      expect(signish(%w[publishProtocol approveWithSignature retireProtocol])).to eq([ "approveWithSignature" ])
    end

    # Regressão do fix round 1: a troca de `include?` por regex com lookahead
    # negativo (para não confundir "Protocols::Sign" com "Protocols::Signatures",
    # ver comentário em `approval_hits`) precisa continuar pegando uma chamada
    # DE VERDADE ao command de assinatura, com ou sem `::` no início e em
    # qualquer forma de invocação (`.call`, `.new`) — e continuar deixando
    # passar o módulo de leitura que `CityType#protocol_versions` chama.
    it "still catches a real Protocols::Sign call, prefixed or not, and still ignores Protocols::Signatures" do
      expect(approval_hits("Protocols::Sign.call(protocol: p)")).to eq([ "Protocols::Sign" ])
      expect(approval_hits("::Protocols::Sign.new")).to eq([ "Protocols::Sign" ])
      expect(approval_hits('Protocols::Signatures.missing(p, purpose: "publication")')).to eq([])
    end
  end
end
