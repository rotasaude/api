# Catálogo de triagens por perfil (ADR 0027; spec 2026-10-05 §3): o perfil
# cifrado do par em citizens, o catálogo da cidade (triage_offers), as
# sugestões (triage_suggestions, transição por trigger) e a contagem agregada
# de "oferecida" (triage_offer_daily_counts, sem coluna de pessoa). Só
# expansão. Os CHECKs vão na forma que o dump reproduz.
class AddTriageCatalog < ActiveRecord::Migration[8.1]
  def up
    add_column :citizens, :birth_date, :text
    add_column :citizens, :sex, :text
    add_column :citizens, :gender_identity, :text
    add_column :citizens, :profile_source, :string
    add_check_constraint :citizens,
                         "profile_source IS NULL OR profile_source::text = ANY (ARRAY['declared', 'verified']::text[])",
                         name: "ck_citizens_profile_source"
    add_check_constraint :citizens,
                         "(profile_source IS NULL AND birth_date IS NULL AND sex IS NULL) OR " \
                         "(profile_source IS NOT NULL AND birth_date IS NOT NULL AND sex IS NOT NULL)",
                         name: "ck_citizens_profile_complete"

    create_table :triage_offers, id: :uuid do |t|
      t.string :protocol_name, null: false
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 1
      t.jsonb :restriction
      t.date :available_from
      t.date :available_until
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :triage_offers, :protocol_name, unique: true
    add_check_constraint :triage_offers,
                         "available_from IS NULL OR available_until IS NULL OR available_until >= available_from",
                         name: "ck_triage_offers_period"
    add_check_constraint :triage_offers, "position >= 1 AND position <= 10000", name: "ck_triage_offers_position"

    create_table :triage_suggestions, id: :uuid do |t|
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: false
      t.references :source_triage, type: :uuid, null: false, foreign_key: { to_table: :triages }
      t.string :protocol_name, null: false
      t.string :status, null: false, default: "pending"
      t.references :taken_triage, type: :uuid, foreign_key: { to_table: :triages }
      t.timestamptz :created_at, null: false
      t.timestamptz :resolved_at
    end
    add_index :triage_suggestions, %i[citizen_id protocol_name], unique: true,
              where: "((status)::text = 'pending'::text)", name: "idx_triage_suggestions_one_pending"
    add_index :triage_suggestions, %i[citizen_id status], name: "idx_triage_suggestions_citizen_status"
    add_check_constraint :triage_suggestions, "status::text = ANY (ARRAY['pending', 'taken', 'expired']::text[])",
                         name: "ck_triage_suggestions_status"
    add_check_constraint :triage_suggestions, "(status::text = 'pending'::text) = (resolved_at IS NULL)",
                         name: "ck_triage_suggestions_resolved"
    add_check_constraint :triage_suggestions, "(status::text = 'taken'::text) = (taken_triage_id IS NOT NULL)",
                         name: "ck_triage_suggestions_taken"

    create_table :triage_offer_daily_counts do |t|
      t.date :day, null: false
      t.string :protocol_name, null: false
      t.integer :offered, null: false
    end
    add_index :triage_offer_daily_counts, %i[day protocol_name], unique: true,
              name: "idx_triage_offer_daily_counts_cell"
    add_check_constraint :triage_offer_daily_counts, "offered >= 1", name: "ck_triage_offer_daily_counts_offered"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :triage_offer_daily_counts
    drop_table :triage_suggestions
    drop_table :triage_offers
    remove_check_constraint :citizens, name: "ck_citizens_profile_complete"
    remove_check_constraint :citizens, name: "ck_citizens_profile_source"
    remove_column :citizens, :profile_source
    remove_column :citizens, :gender_identity
    remove_column :citizens, :sex
    remove_column :citizens, :birth_date
  end
end
