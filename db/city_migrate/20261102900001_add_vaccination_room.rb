# Módulo 29 (ADR 0047): sala de vacina. A sala (uma por unidade, com local de
# estoque próprio do tipo vaccine_room) e a rede de frio municipal (local
# cold_chain_central, um por cidade); equipe da sala; parâmetros (uma linha, id
# 1, inserida aqui); a dose aplicada ou transcrita (imutável: só o
# cancelamento, uma vez); a fila RNDS (payload cifrado, nulo no aceite); o
# frasco multidose aberto; a cadeia de frio (equipamento, leitura imutável,
# excursão e bloqueio dos lotes); a conferência da caderneta (imutável) e a
# situação vacinal materializada (cópia recalculável). O razão do 27a ganha a
# "chave de item": `catalog_item_id` OU `immunobiological_code` (Desvio 3), os
# movimentos do frasco e da dose (Desvio 7) e o motivo SIES da perda (§15 V4).
# A notificação compulsória ganha a dose de origem (ESAVI). Motivos, lote e
# local da transcrição e o payload cifrados com a chave da cidade. Triggers em
# db/city_triggers.sql (o dump não representa trigger nem linha). Irreversível.
class AddVaccinationRoom < ActiveRecord::Migration[8.1]
  # Espelho de Vaccination::Catalog e Pharmacy::Catalog no dia desta migração
  # (a migração não lê código da aplicação: a lista do banco fica fixa no que
  # foi migrado).
  CREDENTIAL_KINDS = %w[ledi cadsus rnds].freeze
  LOCATION_KINDS = %w[central unit cold_chain_central vaccine_room].freeze
  UNIT_LOCATION_KINDS = %w[unit vaccine_room].freeze
  ITEM_KINDS = %w[medication immunobiological].freeze
  ROOM_ROLES = %w[vaccinator room_lead].freeze
  CHECK_MODES = %w[transcribed confirmed_complete born_after_go_live].freeze
  # not_applicable nunca é gravada (Desvio 11).
  STORED_ITEM_STATUSES = %w[due overdue upcoming complete unchecked].freeze
  OUTBOX_KINDS = %w[application cancellation].freeze
  OUTBOX_STATUSES = %w[pending sending accepted rejected failed blocked].freeze
  BLOCK_REASONS = %w[professional_cns_not_in_cnes patient_identity_unverified patient_without_cns_or_cpf].freeze
  EQUIPMENT_KINDS = %w[refrigerator chamber freezer].freeze
  EXCURSION_DECISIONS = %w[use discard].freeze
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return
                      vial_opening immunization immunization_reversal].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return immunization_reversal].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry vial_opening immunization].freeze
  MAX_QUANTITY = "99999.99".freeze
  DOSES_PER_VIAL = (1..10_000)

  def up
    replace_check :integration_credentials, "ck_integration_credentials_kind",
                  "kind::text = ANY (ARRAY[#{quoted(CREDENTIAL_KINDS)}]::text[])"

    change_stock_locations
    change_stock_items

    create_table :vaccination_settings, id: :smallint do |t|
      t.date :go_live_on
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :vaccination_settings, "id = 1", name: "ck_vaccination_settings_singleton"
    execute "INSERT INTO vaccination_settings (id, updated_at) VALUES (1, now()) ON CONFLICT (id) DO NOTHING"

    create_table :vaccine_rooms, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 120, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :vaccine_rooms, :health_unit_id, unique: true, name: "idx_vaccine_rooms_unit"
    add_index :vaccine_rooms, :stock_location_id, unique: true, name: "idx_vaccine_rooms_location"

    create_table :vaccine_room_staff, id: :uuid do |t|
      t.references :vaccine_room, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.string :role, null: false
      t.references :granted_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :granted_at, null: false
      t.datetime :revoked_at
      t.references :revoked_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
    end
    add_index :vaccine_room_staff, %i[vaccine_room_id user_id role], unique: true, where: "revoked_at IS NULL",
                                                                     name: "idx_vaccine_room_staff_active"
    add_index :vaccine_room_staff, :user_id, name: "idx_vaccine_room_staff_user"
    add_check_constraint :vaccine_room_staff, "role::text = ANY (ARRAY[#{quoted(ROOM_ROLES)}]::text[])", name: "ck_vaccine_room_staff_role"
    add_check_constraint :vaccine_room_staff, "(revoked_at IS NULL) = (revoked_by_user_id IS NULL)", name: "ck_vaccine_room_staff_revoked"

    create_table :vial_openings, id: :uuid do |t|
      t.references :vaccine_room, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.references :opened_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :opened_at, null: false
      t.datetime :expires_at, null: false
      t.integer :doses_per_vial, null: false
      t.datetime :closed_at
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade.
      t.text :close_reason
      t.integer :technical_loss_doses
    end
    add_index :vial_openings, %i[vaccine_room_id closed_at], name: "idx_vial_openings_room"
    add_index :vial_openings, :stock_lot_id, name: "idx_vial_openings_lot"
    add_check_constraint :vial_openings, "doses_per_vial >= #{DOSES_PER_VIAL.min} AND doses_per_vial <= #{DOSES_PER_VIAL.max}",
                         name: "ck_vial_openings_doses"
    add_check_constraint :vial_openings, "expires_at > opened_at", name: "ck_vial_openings_expires"
    # Fechado (no descarte ou no vencimento) ⇔ perda técnica gravada; quem
    # descarta dá o motivo; o vencimento (job) fecha sem autor nem motivo.
    add_check_constraint :vial_openings,
                         "(closed_at IS NULL) = (technical_loss_doses IS NULL) AND " \
                         "(closed_by_user_id IS NULL) = (close_reason IS NULL) AND " \
                         "(closed_at IS NOT NULL OR closed_by_user_id IS NULL) AND " \
                         "(technical_loss_doses IS NULL OR (technical_loss_doses >= 0 AND technical_loss_doses <= doses_per_vial))",
                         name: "ck_vial_openings_closed"

    create_table :immunizations, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :vaccine_room, type: :uuid, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :vaccinator_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :vaccinator_cbo, limit: 6, null: false
      t.string :immunobiological_code, limit: 10, null: false
      t.string :dose_code, limit: 10, null: false
      t.string :strategy, limit: 10, null: false
      t.string :care_group, limit: 10
      t.string :route, limit: 10
      t.string :site, limit: 10
      t.string :maternal_condition, limit: 10
      t.timestamptz :applied_at, null: false
      t.boolean :transcription, null: false, default: false
      t.references :stock_lot, type: :uuid, foreign_key: true, index: false
      # Lote, fabricante e local da transcrição: cifrados com a chave da cidade.
      t.text :lot_number_text
      t.text :manufacturer_text
      t.text :place_text
      t.references :vial_opening, type: :uuid, foreign_key: true, index: false
      t.references :campaign, type: :uuid, foreign_key: true, index: false
      t.references :replaces, type: :uuid, foreign_key: { to_table: :immunizations }, index: false
      # Justificativa do aviso (§15 V5) e motivo do cancelamento: cifrados.
      t.text :override_reason
      t.datetime :cancelled_at
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :cancel_reason
      t.string :calendar_version, limit: 20, null: false
      t.datetime :created_at, null: false
    end
    add_index :immunizations, %i[patient_id applied_at], name: "idx_immunizations_patient"
    add_index :immunizations, %i[vaccine_room_id applied_at], name: "idx_immunizations_room"
    add_index :immunizations, %i[immunobiological_code applied_at], name: "idx_immunizations_immunobiological"
    add_index :immunizations, :stock_lot_id, name: "idx_immunizations_lot"
    add_index :immunizations, :vial_opening_id, name: "idx_immunizations_vial"
    add_index :immunizations, :campaign_id, name: "idx_immunizations_campaign"
    add_index :immunizations, :replaces_id, unique: true, name: "idx_immunizations_replaces"
    # Transcrição ⇔ sem lote do estoque; a aplicada exige sala, grupo, via e
    # local; frasco só com lote; lote/fabricante/local em texto só na transcrição.
    add_check_constraint :immunizations,
                         "transcription = (stock_lot_id IS NULL) AND " \
                         "(transcription OR (vaccine_room_id IS NOT NULL AND care_group IS NOT NULL AND route IS NOT NULL AND site IS NOT NULL)) AND " \
                         "(vial_opening_id IS NULL OR stock_lot_id IS NOT NULL) AND " \
                         "(transcription OR (lot_number_text IS NULL AND manufacturer_text IS NULL AND place_text IS NULL))",
                         name: "ck_immunizations_transcription"
    add_check_constraint :immunizations,
                         "(cancelled_at IS NULL) = (cancelled_by_user_id IS NULL) AND (cancelled_at IS NULL) = (cancel_reason IS NULL)",
                         name: "ck_immunizations_cancel"
    add_check_constraint :immunizations, "vaccinator_cbo::text ~ '^[0-9]{6}$'::text", name: "ck_immunizations_cbo"
    add_check_constraint :immunizations, "replaces_id IS NULL OR replaces_id <> id", name: "ck_immunizations_replaces"

    create_table :rnds_outbox, id: :uuid do |t|
      t.references :immunization, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      # O Bundle RIA-R serializado, cifrado com a chave da cidade; nulo no aceite.
      t.text :payload
      t.string :rnds_id, limit: 100
      t.string :block_reason
      t.string :error, limit: 200
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :first_attempt_at
      t.datetime :last_attempted_at
      t.datetime :sent_at
      t.datetime :accepted_at
      t.datetime :identity_checked_at
      t.datetime :deadline_at, null: false
      t.timestamps
    end
    add_index :rnds_outbox, %i[immunization_id kind], unique: true, name: "idx_rnds_outbox_immunization"
    add_index :rnds_outbox, %i[status next_attempt_at], name: "idx_rnds_outbox_due"
    add_index :rnds_outbox, :deadline_at, name: "idx_rnds_outbox_deadline"
    add_check_constraint :rnds_outbox, "kind::text = ANY (ARRAY[#{quoted(OUTBOX_KINDS)}]::text[])", name: "ck_rnds_outbox_kind"
    add_check_constraint :rnds_outbox, "status::text = ANY (ARRAY[#{quoted(OUTBOX_STATUSES)}]::text[])", name: "ck_rnds_outbox_status"
    add_check_constraint :rnds_outbox, "status::text <> 'accepted'::text OR payload IS NULL", name: "ck_rnds_outbox_payload_accepted"
    add_check_constraint :rnds_outbox, "(status::text = 'accepted'::text) = (accepted_at IS NOT NULL)", name: "ck_rnds_outbox_accepted_at"
    add_check_constraint :rnds_outbox,
                         "(status::text = 'blocked'::text) = (block_reason IS NOT NULL) AND " \
                         "(block_reason IS NULL OR block_reason::text = ANY (ARRAY[#{quoted(BLOCK_REASONS)}]::text[]))",
                         name: "ck_rnds_outbox_block"
    add_check_constraint :rnds_outbox, "attempts >= 0", name: "ck_rnds_outbox_attempts"

    create_table :cold_chain_equipments, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 120, null: false
      t.string :kind, null: false
      t.decimal :min_c, precision: 4, scale: 1, null: false
      t.decimal :max_c, precision: 4, scale: 1, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :cold_chain_equipments, :stock_location_id, name: "idx_cold_chain_equipments_location"
    add_check_constraint :cold_chain_equipments, "kind::text = ANY (ARRAY[#{quoted(EQUIPMENT_KINDS)}]::text[])",
                         name: "ck_cold_chain_equipments_kind"
    add_check_constraint :cold_chain_equipments, "min_c < max_c", name: "ck_cold_chain_equipments_range"

    create_table :cold_chain_readings, id: :uuid do |t|
      # "equipment" é incontável no inflector: a tabela vem dita.
      t.references :cold_chain_equipment, type: :uuid, null: false, foreign_key: { to_table: :cold_chain_equipments }, index: false
      t.datetime :read_at, null: false
      t.decimal :current_c, precision: 4, scale: 1, null: false
      t.decimal :min_c, precision: 4, scale: 1, null: false
      t.decimal :max_c, precision: 4, scale: 1, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :cold_chain_readings, %i[cold_chain_equipment_id read_at], name: "idx_cold_chain_readings_equipment"
    add_check_constraint :cold_chain_readings, "min_c <= max_c", name: "ck_cold_chain_readings_range"

    create_table :cold_chain_excursions, id: :uuid do |t|
      t.references :cold_chain_reading, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :decided_at
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :cold_chain_excursions, :cold_chain_reading_id, unique: true, name: "idx_cold_chain_excursions_reading"
    add_index :cold_chain_excursions, :stock_location_id, where: "decided_at IS NULL", name: "idx_cold_chain_excursions_open"
    add_check_constraint :cold_chain_excursions, "(decided_at IS NULL) = (decided_by_user_id IS NULL)",
                         name: "ck_cold_chain_excursions_decided"

    create_table :stock_lot_blocks, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.references :cold_chain_excursion, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :released_at
      t.string :decision
    end
    add_index :stock_lot_blocks, %i[cold_chain_excursion_id stock_lot_id], unique: true, name: "idx_stock_lot_blocks_excursion_lot"
    add_index :stock_lot_blocks, %i[stock_location_id stock_lot_id], where: "released_at IS NULL", name: "idx_stock_lot_blocks_open"
    add_check_constraint :stock_lot_blocks,
                         "(released_at IS NULL) = (decision IS NULL) AND " \
                         "(decision IS NULL OR decision::text = ANY (ARRAY[#{quoted(EXCURSION_DECISIONS)}]::text[]))",
                         name: "ck_stock_lot_blocks_decision"

    create_table :vaccination_record_checks, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :vaccine_room, type: :uuid, foreign_key: true, index: false
      t.references :checked_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.string :mode, null: false
      t.datetime :checked_at, null: false
    end
    add_index :vaccination_record_checks, %i[patient_id checked_at], name: "idx_vaccination_record_checks_patient"
    add_check_constraint :vaccination_record_checks, "mode::text = ANY (ARRAY[#{quoted(CHECK_MODES)}]::text[])",
                         name: "ck_vaccination_record_checks_mode"
    add_check_constraint :vaccination_record_checks, "(mode::text = 'born_after_go_live'::text) = (checked_by_user_id IS NULL)",
                         name: "ck_vaccination_record_checks_author"

    create_table :vaccination_statuses, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.string :series, limit: 40, null: false
      t.string :immunobiological_code, limit: 10, null: false
      t.string :next_dose_code, limit: 10
      t.string :status, null: false
      t.date :due_on
      t.integer :doses_applied, null: false, default: 0
      t.integer :age_months, null: false
      t.boolean :checked, null: false, default: false
      t.date :computed_on, null: false
    end
    add_index :vaccination_statuses, %i[patient_id series], unique: true, name: "idx_vaccination_statuses_series"
    add_index :vaccination_statuses, %i[status immunobiological_code], name: "idx_vaccination_statuses_status"
    add_check_constraint :vaccination_statuses, "status::text = ANY (ARRAY[#{quoted(STORED_ITEM_STATUSES)}]::text[])",
                         name: "ck_vaccination_statuses_status"
    add_check_constraint :vaccination_statuses, "doses_applied >= 0 AND age_months >= 0", name: "ck_vaccination_statuses_counts"

    change_stock_movements

    add_reference :disease_notifications, :immunization, type: :uuid, foreign_key: true, index: false
    add_index :disease_notifications, :immunization_id, name: "idx_disease_notifications_immunization"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Desvio 4: a rede de frio (uma por cidade) e a sala (com unidade); a
  # unidade pode ter farmácia (unit) e sala (vaccine_room) ao mesmo tempo.
  def change_stock_locations
    replace_check :stock_locations, "ck_stock_locations_kind", "kind::text = ANY (ARRAY[#{quoted(LOCATION_KINDS)}]::text[])"
    replace_check :stock_locations, "ck_stock_locations_unit",
                  "(kind::text = ANY (ARRAY[#{quoted(UNIT_LOCATION_KINDS)}])) = (health_unit_id IS NOT NULL)"
    remove_index :stock_locations, name: "idx_stock_locations_unit"
    add_index :stock_locations, %i[health_unit_id kind], unique: true, where: "health_unit_id IS NOT NULL", name: "idx_stock_locations_unit"
    add_index :stock_locations, :kind, unique: true, where: "kind::text = 'cold_chain_central'::text",
                                       name: "idx_stock_locations_one_cold_chain_central"
  end

  # Desvio 3: a chave de item (catálogo CATMAT OU código do imunobiológico)
  # nos lotes, mínimos e aberturas; o fabricante (a `key` estável do catálogo,
  # §15 V19: o lote nunca grava o código RNDS) só no lote de imunobiológico, sempre em doses; o motivo SIES da
  # perda (§15 V4) só em perda e vencimento.
  def change_stock_items
    add_column :stock_lots, :item_kind, :string, null: false, default: "medication"
    add_column :stock_lots, :immunobiological_code, :string, limit: 10
    add_column :stock_lots, :manufacturer_key, :string, limit: 40
    change_column_null :stock_lots, :catalog_item_id, true
    change_column_null :stock_lots, :catmat_code, true
    add_check_constraint :stock_lots,
                         "item_kind::text = ANY (ARRAY[#{quoted(ITEM_KINDS)}]) AND " \
                         "(item_kind::text = 'immunobiological'::text) = (immunobiological_code IS NOT NULL) AND " \
                         "(item_kind::text = 'immunobiological'::text) = (catalog_item_id IS NULL) AND " \
                         "(catalog_item_id IS NULL) = (catmat_code IS NULL) AND " \
                         "(item_kind::text = 'immunobiological'::text OR manufacturer_key IS NULL) AND " \
                         "(item_kind::text <> 'immunobiological'::text OR dispensing_unit::text = 'dose'::text)",
                         name: "ck_stock_lots_item"
    add_index :stock_lots, %i[immunobiological_code lot_number], unique: true, where: "immunobiological_code IS NOT NULL",
                                                                 name: "idx_stock_lots_immunobiological_number"

    %i[stock_minimums stock_openings].each do |table|
      add_column table, :immunobiological_code, :string, limit: 10
      change_column_null table, :catalog_item_id, true
      add_check_constraint table, "num_nonnulls(catalog_item_id, immunobiological_code) = 1", name: "ck_#{table}_item"
    end
    add_index :stock_minimums, %i[stock_location_id immunobiological_code], unique: true, where: "immunobiological_code IS NOT NULL",
                                                                            name: "idx_stock_minimums_immunobiological"
    add_index :stock_openings, %i[stock_location_id immunobiological_code], unique: true, where: "immunobiological_code IS NOT NULL",
                                                                            name: "idx_stock_openings_immunobiological_once"

    add_column :stock_adjustments, :loss_code, :string, limit: 10
    add_check_constraint :stock_adjustments, "loss_code IS NULL OR kind::text = ANY (ARRAY['loss'::text, 'expiry'::text])",
                         name: "ck_stock_adjustments_loss_code"
  end

  # Desvio 7: abertura de frasco (−doses), dose de unidose (−1) e a devolução
  # da dose de unidose cancelada (+1), com o frasco ou a dose por documento.
  def change_stock_movements
    add_column :stock_movements, :immunobiological_code, :string, limit: 10
    change_column_null :stock_movements, :catalog_item_id, true
    add_reference :stock_movements, :vial_opening, type: :uuid, foreign_key: true, index: false
    add_reference :stock_movements, :immunization, type: :uuid, foreign_key: true, index: false
    add_index :stock_movements, :vial_opening_id, name: "idx_stock_movements_vial_opening"
    add_index :stock_movements, :immunization_id, name: "idx_stock_movements_immunization"
    add_check_constraint :stock_movements, "num_nonnulls(catalog_item_id, immunobiological_code) = 1", name: "ck_stock_movements_item"
    replace_check :stock_movements, "ck_stock_movements_kind", "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}]::text[])"
    replace_check :stock_movements, "ck_stock_movements_sign",
                  "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]::text[]) OR quantity > 0::numeric) AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]::text[]) OR quantity < 0::numeric)"
    replace_check :stock_movements, "ck_stock_movements_document",
                  "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id, vial_opening_id, immunization_id) = 1 AND " \
                  "(stock_entry_id IS NOT NULL) = (kind::text = ANY (ARRAY['opening'::text, 'receipt'::text, 'donation'::text])) AND " \
                  "(dispensation_item_id IS NOT NULL) = (kind::text = ANY (ARRAY['dispensing'::text, 'return'::text])) AND " \
                  "(stock_transfer_id IS NULL OR kind::text = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'loss'::text])) AND " \
                  "(stock_adjustment_id IS NULL OR kind::text = ANY (ARRAY['adjustment'::text, 'expiry'::text, 'loss'::text])) AND " \
                  "(kind::text <> ALL (ARRAY['transfer_out'::text, 'transfer_in'::text]) OR stock_transfer_id IS NOT NULL) AND " \
                  "(kind::text <> ALL (ARRAY['adjustment'::text, 'expiry'::text]) OR stock_adjustment_id IS NOT NULL) AND " \
                  "(vial_opening_id IS NOT NULL) = (kind::text = 'vial_opening'::text) AND " \
                  "(immunization_id IS NOT NULL) = (kind::text = ANY (ARRAY['immunization'::text, 'immunization_reversal'::text]))"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
