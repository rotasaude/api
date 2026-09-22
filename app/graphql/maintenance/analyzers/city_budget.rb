# Teto de cidades por operação (spec §8: "até 5 cidades por operação").
#
# Cada `city(slug:)` abre UMA conexão com o banco daquela cidade. Sem teto, uma
# query de vinte campos de cidade abre vinte conexões numa requisição — foi
# esgotamento de conexões que derrubou a suíte inteira no Plano 5 do banco por
# cidade, e ali era um worker, não a internet pública.
#
# Conta na ANÁLISE, antes de executar: alias e fragmento contam igual, porque o
# custo é por campo resolvido, não por slug distinto.
#
# Plano 5 (Decisão 7): uma mutation de cidade (campo de raiz de Mutation com
# argumento `citySlug`) também abre uma conexão, e conta no mesmo teto. A
# análise só visita a operação selecionada, então na prática o teto vale para
# `city` numa query e para escritas de cidade numa mutation.
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
        return unless city_field?(node, visitor)

        # Conta mesmo dentro de @skip/@include: a análise não avalia variável
        # nenhuma, então não há como saber se a diretiva vai remover o campo em
        # tempo de execução. É de propósito — contar a mais é seguro (o pior
        # caso é recusar uma operação que teria ficado dentro do teto);
        # contar a menos deixaria passar uma que de fato abre mais conexões.
        @city_fields += 1
      end

      def result
        return if @city_fields <= MAX_CITIES

        GraphQL::AnalysisError.new("operação toca #{@city_fields} cidades; o teto é #{MAX_CITIES}",
                                   extensions: { "code" => CODE })
      end

      private

      # `parent_type_definition` é o tipo DONO do campo (ver HumanOnly);
      # `field_definition` é a definição do campo sendo visitado — nil para um
      # campo que não existe, que a validação já recusa.
      def city_field?(node, visitor)
        schema = visitor.query.schema
        parent_type = visitor.parent_type_definition

        if parent_type == schema.query
          node.name == "city"
        elsif parent_type == schema.mutation
          visitor.field_definition&.arguments&.key?("citySlug") || false
        else
          false
        end
      end
    end
  end
end
