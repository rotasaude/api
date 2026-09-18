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
end
