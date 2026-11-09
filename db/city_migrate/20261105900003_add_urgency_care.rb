# Módulo 32a (ADR 0050; contrato §5, §7, §13 e §14 Q1, Q3, Q16, Q18; plano,
# Desvios 8 e 9): a urgência da UPA. O encontro é 1:1 com o atendimento
# `walk_in` do 13 (o estado da fila e da chamada continua no atendimento) e
# guarda o que é clínico: as classificações (só acréscimo, numeradas; cada
# uma com a foto do tempo máximo da sua cor e o protocolo que a sugeriu, para
# o estouro não mudar com a troca do protocolo) e o desfecho (um, imutável).
# A dor fica fora dos sinais (`pain_scale`, 0..10, Q3). Um só protocolo de
# urgência ativo por cidade, pelo `kind` e não pelo nome (Q16).
# Queixa, sinais, critério, justificativa, destino, pedido de vaga, motivo
# do retorno e motivo do registro por engano (§14 Q25): cifrados com a chave
# da cidade. Os limites de texto ficam nos comandos (o cifrado não tem o
# tamanho do claro). Triggers em db/city_triggers.sql (o dump não representa
# trigger). Irreversível.
class AddUrgencyCare < ActiveRecord::Migration[8.1]
  # Espelho de Urgency::Catalog no dia desta migração (a migração não lê
  # código da aplicação: a lista do banco fica fixa no que foi migrado).
  COLORS = %w[red orange yellow green blue].freeze
  STATES = %w[waiting_classification classified in_care closed].freeze
  OUTCOMES = %w[discharged discharged_to_primary_care transferred left_without_care left_against_advice death registered_in_error].freeze
  MAX_WAIT = (0..1440)
  PAIN = (0..10)
  RETURN_DAYS = (1..90)
  URGENCY_KIND = "urgency_classification".freeze
  # As tabelas desta migração (TRUNCATE recusado em todas).
  TABLES = %w[urgency_encounters urgency_classifications urgency_outcomes].freeze

  def up
    create_encounters
    create_classifications
    create_outcomes
    add_index :protocol_definitions, "(definition ->> 'kind')", unique: true,
                                                                 where: "status = 'active' AND (definition ->> 'kind') = '#{URGENCY_KIND}'",
                                                                 name: "idx_protocol_definitions_one_active_urgency"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_encounters
    create_table :urgency_encounters, id: :uuid do |t|
      t.references :attendance, type: :uuid, null: false, foreign_key: true, index: false
      t.references :consultation, type: :uuid, foreign_key: true, index: false
      # O paciente provisório com que o encontro nasceu (R4): gravado pela
      # chegada do não identificado e nunca muda (trigger) — a fusão leva o
      # atendimento ao real, e é por aqui que a identificação sabe que o
      # encontro já foi de um provisório. Não se chama patient_id: a fusão não
      # o move.
      t.references :provisional_patient, type: :uuid, foreign_key: { to_table: :patients }, index: false
      t.string :state, null: false, default: "waiting_classification"
      t.uuid :current_classification_id
      t.datetime :first_classified_at
      t.timestamps
    end
    add_index :urgency_encounters, :attendance_id, unique: true, name: "idx_urgency_encounters_attendance"
    add_check_constraint :urgency_encounters, "state::text = ANY (ARRAY[#{quoted(STATES)}]::text[])", name: "ck_urgency_encounters_state"
    # Desvio 8: aguardando ⇔ sem classificação; classificado e em atendimento
    # sempre com ela; o fechado pode não ter (evasão antes da classificação).
    add_check_constraint :urgency_encounters,
                         "(current_classification_id IS NULL) = (first_classified_at IS NULL) AND " \
                         "(state::text <> 'waiting_classification'::text OR current_classification_id IS NULL) AND " \
                         "(state::text <> ALL (ARRAY['classified'::text, 'in_care'::text]) OR current_classification_id IS NOT NULL)",
                         name: "ck_urgency_encounters_classification"
  end

  def create_classifications
    create_table :urgency_classifications, id: :uuid do |t|
      t.references :urgency_encounter, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, limit: 2, null: false
      t.string :color, null: false
      t.string :suggested_color
      t.string :suggested_rule_id, limit: 40
      # Critério da regra sugerida, queixa, sinais (JSON) e justificativa: cifrados.
      t.text :criterion
      t.text :complaint, null: false
      t.text :vital_signs, null: false
      t.integer :pain_scale, limit: 2, null: false
      t.text :justification
      t.integer :max_wait_minutes, null: false
      t.references :protocol_definition, type: :uuid, foreign_key: true, index: false
      t.references :classified_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :professional_link, type: :uuid, null: false, foreign_key: true, index: false
      t.string :cbo_code, limit: 6, null: false
      t.datetime :created_at, null: false
    end
    add_index :urgency_classifications, %i[urgency_encounter_id position], unique: true, name: "idx_urgency_classifications_position"
    add_check_constraint :urgency_classifications,
                         "position >= 1 AND color::text = ANY (ARRAY[#{quoted(COLORS)}]::text[]) AND " \
                         "(suggested_color IS NULL OR suggested_color::text = ANY (ARRAY[#{quoted(COLORS)}]::text[])) AND " \
                         "pain_scale >= #{PAIN.min} AND pain_scale <= #{PAIN.max} AND " \
                         "max_wait_minutes >= #{MAX_WAIT.min} AND max_wait_minutes <= #{MAX_WAIT.max} AND " \
                         "cbo_code::text ~ '^[0-9]{6}$'::text",
                         name: "ck_urgency_classifications_domains"
    add_check_constraint :urgency_classifications, "suggested_color IS NOT DISTINCT FROM color OR justification IS NOT NULL",
                         name: "ck_urgency_classifications_justification"
    add_check_constraint :urgency_classifications, "(suggested_color IS NULL) = (suggested_rule_id IS NULL)",
                         name: "ck_urgency_classifications_suggestion"
    add_foreign_key :urgency_encounters, :urgency_classifications, column: :current_classification_id
  end

  def create_outcomes
    create_table :urgency_outcomes, id: :uuid do |t|
      t.references :urgency_encounter, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      # Destino, pedido de vaga e motivo do retorno: cifrados.
      t.text :destination
      t.text :vacancy_request
      t.integer :return_days, limit: 2
      t.text :return_reason
      # Motivo do registro por engano (§14 Q25): cifrado, só nele.
      t.text :error_reason
      t.references :counter_referral_health_team, type: :uuid, foreign_key: { to_table: :health_teams }, index: false
      t.references :counter_referral_health_unit, type: :uuid, foreign_key: { to_table: :health_units }, index: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :urgency_outcomes, :urgency_encounter_id, unique: true, name: "idx_urgency_outcomes_encounter"
    # Retornos pedidos à UBS (contrato §14 Q11/Q20): por unidade e data.
    add_index :urgency_outcomes, %i[counter_referral_health_unit_id recorded_at], where: "counter_referral_health_unit_id IS NOT NULL",
                                                                                  name: "idx_urgency_outcomes_counter_referral"
    add_check_constraint :urgency_outcomes,
                         "kind::text = ANY (ARRAY[#{quoted(OUTCOMES)}]::text[]) AND " \
                         "(return_days IS NULL OR return_days >= #{RETURN_DAYS.min} AND return_days <= #{RETURN_DAYS.max})",
                         name: "ck_urgency_outcomes_domains"
    add_check_constraint :urgency_outcomes, "(kind::text = 'transferred'::text) = (destination IS NOT NULL)",
                         name: "ck_urgency_outcomes_destination"
    add_check_constraint :urgency_outcomes,
                         "(kind::text = 'discharged_to_primary_care'::text) = (return_days IS NOT NULL) AND " \
                         "(return_days IS NULL) = (return_reason IS NULL)",
                         name: "ck_urgency_outcomes_return"
    add_check_constraint :urgency_outcomes, "(kind::text = 'registered_in_error'::text) = (error_reason IS NOT NULL)",
                         name: "ck_urgency_outcomes_error_reason"
    add_check_constraint :urgency_outcomes, "vacancy_request IS NULL OR kind::text = 'transferred'::text",
                         name: "ck_urgency_outcomes_vacancy_request"
    add_check_constraint :urgency_outcomes, "counter_referral_health_unit_id IS NULL OR kind::text = 'discharged_to_primary_care'::text",
                         name: "ck_urgency_outcomes_counter_referral"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
end
