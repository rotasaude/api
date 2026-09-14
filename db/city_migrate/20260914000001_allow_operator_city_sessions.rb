# Sessão da cidade aceita um operador da plataforma no lugar de um usuário
# (grant assinado, Plano 3B — spec banco-por-cidade §5). Exatamente um ator por
# sessão. O operador NÃO existe no banco da cidade: operator_id é só o id da
# conta de plataforma, sem chave estrangeira.
class AllowOperatorCitySessions < ActiveRecord::Migration[8.1]
  def change
    change_column_null :sessions, :user_id, true
    add_column :sessions, :operator_id, :uuid
    add_index :sessions, :operator_id, name: "index_sessions_on_operator_id"
    add_check_constraint :sessions, "(user_id IS NULL) <> (operator_id IS NULL)", name: "ck_sessions_exactly_one_actor"
  end
end
