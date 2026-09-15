require Rails.root.join("db/solid_queue_tables").to_s

# A fila da cidade mora no banco dela (spec banco-por-cidade §1: o payload de
# ProcessInboundMessageJob e SendWhatsappJob carrega telefone e mensagem).
# Plano 5. Aditiva.
class CreateSolidQueueTables < ActiveRecord::Migration[8.1]
  def change
    SolidQueueTables.create(self)
  end
end
