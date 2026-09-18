# Recusa ANTES de executar (spec §7): um token `read` não roda mutation. A
# checagem é na análise da query, não no resolver, porque "não escreve" tem de
# valer para toda mutation — inclusive a que alguém acrescentar amanhã.
#
# `GraphQL::AnalysisError` devolvido por `result` vira erro de VALIDAÇÃO
# (`GraphQL::Query#valid?` fica falso): o mesmo mecanismo que já barra
# `max_depth`/`max_complexity` neste schema. Nenhum resolver roda — não há
# `data`, só `errors`.
module Maintenance
  module Analyzers
    class WriteScope < GraphQL::Analysis::Analyzer
      def initialize(subject)
        super
        @credential = subject.context[:credential]
        @touched = []
      end

      def analyze? = query.selected_operation&.operation_type == "mutation"

      # Os campos de RAIZ da mutation, pelo mesmo critério de HumanOnly.
      def on_enter_field(node, _parent, visitor)
        @touched << node.name if visitor.parent_type_definition == visitor.query.schema.mutation
      end

      def result
        return unless @credential&.read_only?

        # I1 (fix round 2): o erro CARREGA o que foi recusado, em `extensions`,
        # para que a controller possa auditar a recusa (spec §9: "uso recusado
        # de token … fora do escopo"). O analisador em si continua sem efeito
        # colateral nenhum — ele é chamado na análise, que roda para qualquer
        # query, e uma gravação aqui seria escrita em caminho de leitura.
        GraphQL::AnalysisError.new("token de leitura não executa mutation",
                                   extensions: { "code" => Refusal::CODE, "refusedFields" => @touched.uniq })
      end
    end
  end
end
