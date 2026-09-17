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
      end

      def analyze? = query.selected_operation&.operation_type == "mutation"

      def result
        return unless @credential&.read_only?

        GraphQL::AnalysisError.new("token de leitura não executa mutation")
      end
    end
  end
end
