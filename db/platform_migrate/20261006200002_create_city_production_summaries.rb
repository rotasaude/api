# Contagens da fila LEDI por cidade e competência, publicadas pela cidade
# (Ledi::PublishProductionJob) para o console ler sem abrir banco de cidade
# (ADR 0028; padrão do ADR 0025). Só números; nada de ficha.
class CreateCityProductionSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :city_production_summaries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :city_id, null: false
      t.string :competence, limit: 6, null: false
      t.integer :accepted, null: false, default: 0
      t.integer :rejected, null: false, default: 0
      t.integer :pending, null: false, default: 0
      t.integer :sending, null: false, default: 0
      t.integer :failed, null: false, default: 0
      t.datetime :published_at, null: false
      t.index %i[city_id competence], unique: true, name: "idx_city_production_summaries_cell"
      t.check_constraint "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text",
                         name: "ck_city_production_summaries_competence"
    end
    add_foreign_key :city_production_summaries, :cities
  end
end
