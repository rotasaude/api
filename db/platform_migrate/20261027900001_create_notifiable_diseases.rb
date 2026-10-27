# Lista de notificação compulsória versionada (módulo 25; ADR 0043). Versão
# nova é linha nova: nenhuma versão nem doença muda ou some (trigger em
# db/platform_triggers.sql). Dado público, sem pessoa. Irreversível.
class CreateNotifiableDiseases < ActiveRecord::Migration[8.1]
  def up
    create_table :notifiable_disease_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer :version, null: false
      t.string :ordinance, limit: 200, null: false
      t.date :effective_from, null: false
      t.string :notes, limit: 500
      t.jsonb :sources
      t.uuid :published_by_maintainer_id
      t.datetime :created_at, null: false
      t.index :version, unique: true, name: "idx_notifiable_disease_versions_version"
      t.check_constraint "version >= 1", name: "ck_notifiable_disease_versions_version"
    end

    create_table :notifiable_diseases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :list_version, type: :uuid, null: false, index: false,
                                  foreign_key: { to_table: :notifiable_disease_versions }
      t.string :code, limit: 48, null: false
      t.string :name, limit: 120, null: false
      t.string :deadline, null: false
      t.jsonb :cid10, null: false
      t.jsonb :ciap2, null: false
      t.integer :repeat_after_days, null: false
      t.string :sinan_form, limit: 60
      t.string :notes, limit: 300
      t.jsonb :sources, null: false
      t.index %i[list_version_id code], unique: true, name: "idx_notifiable_diseases_version_code"
      t.check_constraint "code::text ~ '^[a-z][a-z0-9_]{1,47}$'::text AND code::text !~ '^local_'::text", name: "ck_notifiable_diseases_code"
      t.check_constraint "deadline::text = ANY (ARRAY['immediate'::text, 'weekly'::text])", name: "ck_notifiable_diseases_deadline"
      t.check_constraint "repeat_after_days >= 1 AND repeat_after_days <= 36500", name: "ck_notifiable_diseases_repeat"
      t.check_constraint "jsonb_typeof(cid10) = 'array'::text AND jsonb_typeof(ciap2) = 'array'::text", name: "ck_notifiable_diseases_codes"
    end
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
