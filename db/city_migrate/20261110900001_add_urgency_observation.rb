# Módulo 32b (ADR 0050; contrato §1 e §11; plano, Desvio 1): a observação da
# UPA. Leitos da UPA (rótulo único por unidade, nunca apagados) e as estadias
# (leito x encontro): um ocupante por leito — exclusion GiST sobre
# tsrange(started_at, ended_at ou infinito), meio-aberta, de modo que quem sai
# e quem entra no mesmo instante não se cruzam — e uma estadia aberta por
# encontro. A estadia fechada nunca muda; a aberta só recebe o fechamento.
# Nenhuma coluna cifrada nem `patient_id`: a fusão do provisório não toca
# estas tabelas. Triggers em db/city_triggers.sql (o dump não representa
# trigger). Irreversível.
class AddUrgencyObservation < ActiveRecord::Migration[8.1]
  # Espelho de Urgency::Catalog::STAY_END_KINDS no dia desta migração (a
  # migração não lê código da aplicação).
  STAY_END_KINDS = %w[bed_change observation_ended outcome].freeze

  def up
    create_table :urgency_beds, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :label, limit: 20, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :urgency_beds, %i[health_unit_id label], unique: true, name: "idx_urgency_beds_label"
    add_check_constraint :urgency_beds, "char_length(btrim(label::text)) BETWEEN 1 AND 20", name: "ck_urgency_beds_label"

    create_table :urgency_bed_stays, id: :uuid do |t|
      t.references :urgency_encounter, type: :uuid, null: false, foreign_key: true, index: false
      t.references :urgency_bed, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.string :end_kind
      t.references :started_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :urgency_bed_stays, :urgency_encounter_id, unique: true, where: "ended_at IS NULL",
                                                         name: "idx_urgency_bed_stays_open_encounter"
    add_index :urgency_bed_stays, %i[health_unit_id started_at], name: "idx_urgency_bed_stays_unit_started"
    add_index :urgency_bed_stays, %i[urgency_encounter_id started_at], name: "idx_urgency_bed_stays_encounter_started"
    add_check_constraint :urgency_bed_stays,
                         "(ended_at IS NULL) = (end_kind IS NULL) AND (ended_at IS NULL) = (ended_by_user_id IS NULL)",
                         name: "ck_urgency_bed_stays_closing"
    add_check_constraint :urgency_bed_stays, "ended_at IS NULL OR ended_at >= started_at", name: "ck_urgency_bed_stays_times"
    add_check_constraint :urgency_bed_stays,
                         "end_kind IS NULL OR end_kind::text = ANY (ARRAY[#{STAY_END_KINDS.map { |k| "'#{k}'::text" }.join(', ')}]::text[])",
                         name: "ck_urgency_bed_stays_end_kind"
    add_exclusion_constraint :urgency_bed_stays,
                             "urgency_bed_id WITH =, tsrange(started_at, COALESCE(ended_at, 'infinity'::timestamp without time zone)) WITH &&",
                             using: :gist, name: "excl_urgency_bed_stays_bed"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
