# Janela comum dos fornecedores (ADR 0035; spec §4): período [from, to],
# "estritamente depois do cursor" na ordem total occurred_at DESC, kind ASC,
# id ASC, e a mesma ordem no SQL. Para um fornecedor de kind K e o cursor
# (t, k, i): K antes de k → só o que é mais antigo que t; K depois de k → t
# também entra; K igual → mais antigo que t, ou t com id maior que i.
module Timeline
  module Sources
    module Window
      module_function

      def apply(scope, kind:, column:, id_column:, before:, from:, to:)
        scope = scope.where("#{column} >= ?", from) if from
        scope = scope.where("#{column} <= ?", to) if to
        scope = after(scope, kind, column, id_column, before) if before
        scope.reorder(Arel.sql("#{column} DESC, #{id_column} ASC"))
      end

      def after(scope, kind, column, id_column, before)
        if kind < before.kind
          scope.where("#{column} < ?", before.at)
        elsif kind > before.kind
          scope.where("#{column} <= ?", before.at)
        else
          scope.where("#{column} < :at OR (#{column} = :at AND #{id_column} > :id)", at: before.at, id: before.id)
        end
      end
      private_class_method :after
    end
  end
end
