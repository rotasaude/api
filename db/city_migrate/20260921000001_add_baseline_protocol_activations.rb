# Linha-base de ativação (spec de assinaturas §6, ADR-0016, decisão do usuário na fatia 2).
#
# Versões em uso antes das assinaturas não têm linha em protocol_activations,
# e sem uma linha ANTERIOR a primeira ativação assinada de cada cidade não
# seria reversível em emergência. Cada uma ganha uma linha `baseline`, de ator
# `system`, datada de quando entrou em uso. Ela só pode ser ALVO de reversão:
# Protocols::RevertActivation exige que a ativação atual seja `signed`.
#
# Irreversível: o trigger de acréscimo recusa DELETE, e desligá-lo para um
# rollback abriria a porta que ele existe para fechar.
class AddBaselineProtocolActivations < ActiveRecord::Migration[8.1]
  BACKFILL_SQL = <<~SQL.freeze
    INSERT INTO protocol_activations (id, protocol_definition_id, kind, actor_id, actor_kind, reason, created_at)
    SELECT gen_random_uuid(), pd.id, 'baseline', NULL, 'system', NULL, COALESCE(pd.activated_at, pd.updated_at)
    FROM protocol_definitions pd
    WHERE pd.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM protocol_activations pa
        JOIN protocol_definitions other ON other.id = pa.protocol_definition_id
        WHERE other.name = pd.name
      )
  SQL

  def up
    replace_check :ck_protocol_activations_kind,
                  "kind::text = ANY (ARRAY['signed'::text, 'emergency_revert'::text, 'baseline'::text])"
    replace_check :ck_protocol_activations_actor_kind,
                  "actor_kind::text = ANY (ARRAY['user'::text, 'maintainer'::text, 'system'::text])"
    replace_check :ck_protocol_activations_revert_reason,
                  "kind::text <> 'emergency_revert'::text OR reason IS NOT NULL AND length(btrim(reason)) > 0"

    change_column_null :protocol_activations, :actor_id, true
    add_check_constraint :protocol_activations,
                         "(kind::text = 'baseline'::text) = (actor_kind::text = 'system'::text)",
                         name: "ck_protocol_activations_system_is_baseline"
    add_check_constraint :protocol_activations,
                         "(kind::text = 'baseline'::text) = (actor_id IS NULL)",
                         name: "ck_protocol_activations_baseline_has_no_actor"

    execute BACKFILL_SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "linhas-base não se apagam: protocol_activations só aceita acréscimo (trigger rota_append_only)"
  end

  private

  def replace_check(name, expression)
    remove_check_constraint :protocol_activations, name: name.to_s
    add_check_constraint :protocol_activations, expression, name: name.to_s
  end
end
