# Adiciona os estados de lifecycle in_review/published ao protocol_definitions.
# C3 (refundação, Etapa 8): published ≠ active. `active` continua sendo o estado
# de vigência per-cidade, garantido pela unique parcial WHERE status='active'
# (já existente — idx_protocol_definitions_one_active_per_name_muni).
class ProtocolLifecycleStates < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :protocol_definitions, name: "ck_protocol_definitions_status"
    add_check_constraint :protocol_definitions,
                         "status IN ('draft','in_review','published','active','retired')",
                         name: "ck_protocol_definitions_status"
  end

  def down
    # Reversível: requer que nenhuma linha esteja em in_review/published.
    remove_check_constraint :protocol_definitions, name: "ck_protocol_definitions_status"
    add_check_constraint :protocol_definitions,
                         "status IN ('draft','active','retired')",
                         name: "ck_protocol_definitions_status"
  end
end
