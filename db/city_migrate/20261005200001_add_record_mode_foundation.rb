# db/city_migrate/20261005200001_add_record_mode_foundation.rb
# ADR 0028 (spec 2026-10-05 §3.3, §5, §7): credenciais de integração (segredo
# cifrado com a chave da cidade, em text — o envelope da cifra não é jsonb),
# CNES da unidade, equipes (INE) e seus membros, CPF do profissional (cifrado
# determinístico, para unicidade e casamento) e o CNS do cidadão com a marca da
# conferência e o pendente da consulta (desvio 6). Só expansão; os CHECKs vão
# na forma que o dump reproduz.
class AddRecordModeFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :integration_credentials, id: :uuid do |t|
      t.string :kind, null: false
      t.text :secret, null: false
      t.references :set_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.datetime :set_at, null: false
      t.datetime :last_check_at
      t.string :last_check_status
      t.string :last_check_message, limit: 200
      t.timestamps
      t.index :kind, unique: true
    end
    add_check_constraint :integration_credentials, "kind::text = ANY (ARRAY['ledi', 'cadsus']::text[])",
                         name: "ck_integration_credentials_kind"
    add_check_constraint :integration_credentials,
                         "last_check_status IS NULL OR last_check_status::text = ANY (ARRAY['ok', 'unauthorized', " \
                         "'unreachable', 'error']::text[])",
                         name: "ck_integration_credentials_status"

    add_column :health_units, :cnes, :string, limit: 7
    add_index :health_units, :cnes, unique: true, where: "cnes IS NOT NULL", name: "idx_health_units_cnes"
    add_check_constraint :health_units, "cnes IS NULL OR cnes::text ~ '^[0-9]{7}$'::text", name: "ck_health_units_cnes"

    create_table :health_teams, id: :uuid do |t|
      t.string :ine, null: false, limit: 10
      t.string :kind, null: false
      t.string :name, limit: 120
      t.references :health_unit, type: :uuid, null: false, foreign_key: true
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :ine, unique: true
    end
    add_check_constraint :health_teams, "ine::text ~ '^[0-9]{10}$'::text", name: "ck_health_teams_ine"
    add_check_constraint :health_teams, "kind::text = ANY (ARRAY['70', '76']::text[])", name: "ck_health_teams_kind"

    create_table :health_team_members, id: :uuid do |t|
      t.references :professional, type: :uuid, null: false, foreign_key: true
      t.references :health_team, type: :uuid, null: false, foreign_key: true
      t.string :cbo_code, null: false
      t.date :started_on, null: false
      t.date :ended_on
      t.timestamps
      t.index %i[professional_id health_team_id], unique: true, where: "ended_on IS NULL",
                                                   name: "idx_health_team_members_one_active"
    end
    add_check_constraint :health_team_members, "cbo_code::text ~ '^[0-9]{6}$'::text", name: "ck_health_team_members_cbo_code"
    add_check_constraint :health_team_members, "ended_on IS NULL OR ended_on >= started_on",
                         name: "ck_health_team_members_order"

    add_column :professionals, :cpf, :string
    add_index :professionals, :cpf, unique: true, where: "cpf IS NOT NULL", name: "idx_professionals_cpf"

    add_column :citizens, :cns, :string
    add_column :citizens, :cadsus_checked_at, :timestamptz
    add_column :citizens, :cadsus_pending_cns, :string
    add_column :citizens, :cadsus_pending_session_id, :uuid
    add_column :citizens, :cadsus_pending_at, :timestamptz
  end
end
