# Módulo 32a (ADR 0050; contrato §6, §8 e §14 Q7/Q8; plano, Desvio 12 e
# Valor fixado 6): a sala de espera, na UPA e na UBS. Locais de chamada da
# unidade (nome único sem diferença de caixa; desativados, nunca apagados),
# as chamadas do atendimento (só acréscimo, com a senha copiada no momento) e
# as TVs pareadas: código de 6 dígitos e token guardados só como SHA-256,
# `last_seen_at` gravado pela leitura do painel (Task 12). A TV nunca recebe
# dado pessoal: o painel lê as chamadas pela janela de tempo da unidade
# (idx_attendance_calls_board cobre a leitura, com o join pelo atendimento).
# Triggers em db/city_triggers.sql. Irreversível.
class AddWaitingRoom < ActiveRecord::Migration[8.1]
  # Espelho de Urgency::Catalog::CALL_KINDS no dia desta migração.
  CALL_KINDS = %w[classification care].freeze
  DIGEST = "'^[0-9a-f]{64}$'::text".freeze
  # As tabelas desta migração (TRUNCATE recusado em todas).
  TABLES = %w[call_locations attendance_calls waiting_room_displays].freeze

  def up
    create_call_locations
    create_attendance_calls
    create_displays

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_call_locations
    create_table :call_locations, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 40, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :call_locations, "health_unit_id, lower((name)::text)", unique: true, name: "idx_call_locations_name"
  end

  def create_attendance_calls
    create_table :attendance_calls, id: :uuid do |t|
      t.references :attendance, type: :uuid, null: false, foreign_key: true, index: false
      t.string :ticket, limit: 8
      t.references :call_location, type: :uuid, foreign_key: true, index: false
      t.string :kind, null: false
      t.datetime :called_at, null: false
      t.references :called_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :attendance_calls, %i[attendance_id called_at], name: "idx_attendance_calls_attendance"
    add_index :attendance_calls, :called_at, include: %i[attendance_id ticket call_location_id kind], name: "idx_attendance_calls_board"
    add_check_constraint :attendance_calls,
                         "kind::text = ANY (ARRAY[#{CALL_KINDS.map { |kind| "'#{kind}'::text" }.join(', ')}]::text[]) AND " \
                         "(ticket IS NULL OR ticket::text ~ '^[A-Z]{1,3}-[0-9]{3,4}$'::text)",
                         name: "ck_attendance_calls_domains"
  end

  def create_displays
    create_table :waiting_room_displays, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 60, null: false
      t.boolean :active, null: false, default: true
      t.boolean :show_wait_times, null: false, default: true
      t.string :token_digest, limit: 64
      t.string :pairing_code_digest, limit: 64
      t.datetime :pairing_expires_at
      t.datetime :paired_at
      t.datetime :revoked_at
      t.datetime :last_seen_at
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :waiting_room_displays, :health_unit_id, name: "idx_waiting_room_displays_unit"
    add_index :waiting_room_displays, :token_digest, unique: true, where: "token_digest IS NOT NULL", name: "idx_waiting_room_displays_token"
    add_index :waiting_room_displays, :pairing_code_digest, where: "pairing_code_digest IS NOT NULL",
                                                            name: "idx_waiting_room_displays_pairing_code"
    add_check_constraint :waiting_room_displays, "(pairing_code_digest IS NULL) = (pairing_expires_at IS NULL)",
                         name: "ck_waiting_room_displays_pairing"
    add_check_constraint :waiting_room_displays,
                         "(token_digest IS NULL OR token_digest::text ~ #{DIGEST}) AND " \
                         "(pairing_code_digest IS NULL OR pairing_code_digest::text ~ #{DIGEST})",
                         name: "ck_waiting_room_displays_digests"
  end
end
