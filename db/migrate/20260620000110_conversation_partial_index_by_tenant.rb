# Índice de conversa ativa passa de phone para (municipality_id, phone)
# nos estados awaiting_consent/consented (ADR-0021 emenda 0012).
class ConversationPartialIndexByTenant < ActiveRecord::Migration[8.1]
  def up
    remove_index :conversations, name: "index_conversations_on_phone"
    add_index :conversations, [:municipality_id, :phone],
              unique: true,
              where: "state IN ('awaiting_consent','consented','greeting')",
              name: "idx_conversations_active_per_tenant_phone"
  end

  def down
    remove_index :conversations, name: "idx_conversations_active_per_tenant_phone"
    add_index :conversations, :phone, unique: true, name: "index_conversations_on_phone"
  end
end
