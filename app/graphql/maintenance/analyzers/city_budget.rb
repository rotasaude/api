# Teto de cidades por operação (spec §8: "até 5 cidades por operação").
#
# Cada `city(slug:)` abre UMA conexão com o banco daquela cidade. Sem teto, uma
# query de vinte campos de cidade abre vinte conexões numa requisição — foi
# esgotamento de conexões que derrubou a suíte inteira no Plano 5 do banco por
# cidade, e ali era um worker, não a internet pública.
#
# Conta na ANÁLISE, antes de executar: alias e fragmento contam igual, porque o
# custo é por campo resolvido, não por slug distinto.
module Maintenance
  module Analyzers
    class CityBudget < GraphQL::Analysis::Analyzer
      MAX_CITIES = 5
      CODE = "CITY_BUDGET_EXCEEDED"

      def initialize(subject)
        super
        @city_fields = 0
      end

      def on_enter_field(node, _parent, visitor)
        return unless node.name == "city"
        return unless visitor.query.schema.query == visitor.parent_type_definition

        @city_fields += 1
      end

      def result
        return if @city_fields <= MAX_CITIES

        GraphQL::AnalysisError.new("operação toca #{@city_fields} cidades; o teto é #{MAX_CITIES}",
                                   extensions: { "code" => CODE })
      end
    end
  end
end
