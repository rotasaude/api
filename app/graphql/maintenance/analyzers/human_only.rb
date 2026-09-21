# Campos que SÓ sessão humana alcança (spec §7): gerenciar mantenedores,
# gerenciar tokens, ler auditoria e escrever protocolo numa cidade (Plano 5,
# Decisão 3: escrita por token de serviço é decisão própria). Lista única — um
# resolver não repete a regra, e a guarda de cobertura em analyzers_spec.rb força todo campo de raiz
# novo a entrar aqui ou em TOKEN_ALLOWED antes de ir para produção.
module Maintenance
  module Analyzers
    class HumanOnly < GraphQL::Analysis::Analyzer
      RESTRICTED = %w[
        maintainers maintenanceTokens auditEvents
        inviteMaintainer deactivateMaintainer createMaintenanceToken revokeMaintenanceToken
        saveProtocolDraft
      ].freeze

      # Campos de raiz que um token PODE usar. Existe para a guarda de
      # cobertura do spec: campo de raiz novo tem de entrar aqui ou em
      # RESTRICTED. `cities` entra aqui porque o próprio escopo do token já é
      # aplicado dentro do resolver (CityCatalogQuery#call, via
      # Credential#allows_city?) — barrar o campo aqui duplicaria a regra e
      # cegaria um token para o próprio catálogo que ele tem permissão de ler.
      # `city` entra pelo mesmo motivo: o escopo é aplicado dentro do resolver
      # de QueryType#city (Credential#allows_city?), não aqui.
      TOKEN_ALLOWED = %w[me cities city].freeze

      def initialize(subject)
        super
        @credential = subject.context[:credential]
        @touched = []
      end

      # `visitor.parent_type_definition` é o tipo DONO do campo (o gem empilha
      # o tipo de RETORNO do campo antes de chamar este hook — ver
      # graphql/analysis/visitor.rb#on_field). Comparar contra `schema.query`/
      # `schema.mutation` é como isolar campo de RAIZ de campo aninhado
      # (`errors { path message }` não deve contar).
      def on_enter_field(node, _parent, visitor)
        schema = visitor.query.schema
        parent_type = visitor.parent_type_definition

        @touched << node.name if parent_type == schema.query || parent_type == schema.mutation
      end

      def result
        return unless @credential&.token?

        forbidden = @touched & RESTRICTED
        return if forbidden.empty?

        # I1: `extensions` leva os campos recusados — nomes de campo do schema,
        # nunca segredo — para a controller auditar a recusa.
        GraphQL::AnalysisError.new("token de serviço não alcança: #{forbidden.uniq.join(', ')}",
                                   extensions: { "code" => Refusal::CODE, "refusedFields" => forbidden.uniq })
      end
    end
  end
end
