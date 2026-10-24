# Módulo 24a (ADR 0042): cadastro territorial. Microáreas da equipe (código e
# equipe nunca mudam), domicílios e famílias (nada se apaga; a família não
# troca de domicílio nem de responsável) e o cadastro individual (um ativo
# por paciente; a saída — mudança ou óbito — acontece uma vez e congela o
# cadastro). Cada gravação é uma VERSÃO imutável, fonte da ficha LEDI: só
# acréscimo, e a re-cifra regrava só as colunas cifradas.
#
# registered_at/registered_by_user_id de households e individual_registrations
# = instante e autor da ÚLTIMA versão `save` ou `identity_refresh` (nunca da
# `exit`): a validade do cadastro (24 meses, NT 30/2025) conta da última
# atualização.
#
# Paciente sem CPF: cpf passa a nulo, com a justificativa da ficha
# (no_cpf_reason) — um dos dois, nunca ambos (CHECK); o CPF só chega de nulo
# para valor, levando a justificativa. CNS do paciente e a chave de
# duplicados (match_key) cifrados determinísticos, como o CPF.
#
# Profissionais de campo (ACS 515105, agente de endemias 515140) não têm
# conselho: conselho, UF e registro passam a nulos, todos ou nenhum.
#
# Triggers em db/city_triggers.sql, instalados no fim do up (o dump não
# representa trigger). Irreversível.
class AddTerritoryRegistry < ActiveRecord::Migration[8.1]
  def up
    change_column_null :patients, :cpf, true
    add_column :patients, :no_cpf_reason, :text
    add_column :patients, :cns, :string
    add_column :patients, :match_key, :string
    add_index :patients, :cns, unique: true, where: "cns IS NOT NULL", name: "idx_patients_cns"
    add_index :patients, :match_key, name: "idx_patients_match_key"
    add_check_constraint :patients, "num_nonnulls(cpf, no_cpf_reason) = 1", name: "ck_patients_cpf_or_reason"

    change_column_null :professionals, :council, true
    change_column_null :professionals, :council_state, true
    change_column_null :professionals, :registration_number, true
    add_check_constraint :professionals, "num_nonnulls(council, council_state, registration_number) = ANY (ARRAY[0, 3])",
                         name: "ck_professionals_council_all_or_none"

    create_table :micro_areas, id: :uuid do |t|
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.string :code, limit: 2, null: false
      t.string :name, limit: 60, null: false
      t.references :acs_professional, type: :uuid, foreign_key: { to_table: :professionals }, index: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :micro_areas, %i[team_id code], unique: true, name: "idx_micro_areas_team_code"
    add_check_constraint :micro_areas, "code::text ~ '^(0[1-9]|[1-9][0-9])$'::text AND length(btrim(name::text)) > 0",
                         name: "ck_micro_areas_values"

    create_table :households, id: :uuid do |t|
      t.references :micro_area, type: :uuid, null: false, foreign_key: true, index: false
      t.string :status, null: false, default: "active"
      t.integer :version, null: false
      t.datetime :registered_at, null: false
      t.references :registered_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :households, %i[micro_area_id id], name: "idx_households_micro_area"
    add_check_constraint :households, "status::text = ANY (ARRAY['active'::text, 'inactive'::text]) AND version >= 1",
                         name: "ck_households_values"

    create_table :household_versions, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.references :micro_area, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.references :neighborhood, type: :uuid, foreign_key: true, index: false
      t.string :property_type, null: false
      t.text :address, null: false
      t.text :living_conditions, null: false
      t.text :contact_phone
      t.text :refused, null: false
      t.text :families_snapshot, null: false
      t.string :status, null: false
      t.string :origin, null: false
      t.references :saved_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :saved_by_professional, type: :uuid, null: false, foreign_key: { to_table: :professionals }, index: false
      t.string :saved_cbo, limit: 6, null: false
      t.datetime :created_at, null: false
    end
    add_index :household_versions, %i[household_id version], unique: true, name: "idx_household_versions_household_version"
    add_check_constraint :household_versions,
                         "property_type::text = ANY (ARRAY['1'::text, '2'::text, '3'::text, '4'::text, '5'::text, '6'::text, '7'::text, " \
                         "'8'::text, '9'::text, '10'::text, '11'::text, '12'::text, '13'::text, '99'::text]) AND " \
                         "status::text = ANY (ARRAY['active'::text, 'inactive'::text]) AND origin::text = 'save'::text AND version >= 1",
                         name: "ck_household_versions_values"

    create_table :families, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      t.references :responsible_patient, type: :uuid, null: false, foreign_key: { to_table: :patients }, index: false
      t.text :income_band
      t.integer :members_count
      t.text :living_since
      t.boolean :moved_out, null: false, default: false
      t.timestamps
    end
    add_index :families, %i[household_id responsible_patient_id], unique: true, where: "NOT moved_out",
                                                                   name: "idx_families_one_responsible"
    add_index :families, :responsible_patient_id, name: "idx_families_responsible_patient"
    add_check_constraint :families, "members_count IS NULL OR (members_count >= 1 AND members_count <= 999)",
                         name: "ck_families_members_count"

    create_table :individual_registrations, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.references :micro_area, type: :uuid, foreign_key: true, index: false
      t.references :household, type: :uuid, foreign_key: true, index: false
      t.references :family, type: :uuid, foreign_key: true, index: false
      t.boolean :is_responsible, null: false, default: false
      t.integer :version, null: false
      t.text :refused, null: false
      t.datetime :registered_at, null: false
      t.references :registered_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :exit_reason
      t.date :exited_on
      t.date :death_on
      t.text :death_certificate
      t.datetime :identity_changed_at
      t.timestamps
    end
    add_index :individual_registrations, :patient_id, unique: true, where: "exit_reason IS NULL",
                                                      name: "idx_individual_registrations_one_active"
    # CareLines::Facts.deceased: o único índice por paciente é parcial em NULL.
    add_index :individual_registrations, :patient_id, where: "exit_reason = 'death'",
                                                      name: "idx_individual_registrations_deaths"
    add_index :individual_registrations, %i[team_id registered_at], name: "idx_individual_registrations_team"
    add_index :individual_registrations, :household_id, name: "idx_individual_registrations_household"
    add_check_constraint :individual_registrations, registration_exit_check("version >= 1 AND (household_id IS NULL OR micro_area_id IS NOT NULL)"),
                         name: "ck_individual_registrations_values"

    create_table :individual_registration_versions, id: :uuid do |t|
      t.references :registration, type: :uuid, null: false, foreign_key: { to_table: :individual_registrations }, index: false
      t.integer :version, null: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: true
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.references :micro_area, type: :uuid, foreign_key: true, index: false
      t.references :household, type: :uuid, foreign_key: true, index: false
      t.references :family, type: :uuid, foreign_key: true, index: false
      t.boolean :is_responsible, null: false
      t.text :identity, null: false
      t.text :identification, null: false
      t.text :sociodemographic
      t.text :health_conditions
      t.text :street_situation
      t.text :refused, null: false
      t.string :exit_reason
      t.date :exited_on
      t.date :death_on
      t.text :death_certificate
      t.string :origin, null: false
      t.references :saved_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :saved_by_professional, type: :uuid, null: false, foreign_key: { to_table: :professionals }, index: false
      t.string :saved_cbo, limit: 6, null: false
      t.datetime :created_at, null: false
    end
    add_index :individual_registration_versions, %i[registration_id version], unique: true,
                                                                              name: "idx_individual_registration_versions_version"
    add_check_constraint :individual_registration_versions,
                         registration_exit_check("version >= 1 AND " \
                                                 "origin::text = ANY (ARRAY['save'::text, 'identity_refresh'::text, 'exit'::text]) AND " \
                                                 "((origin::text = 'exit'::text) = (exit_reason IS NOT NULL))"),
                         name: "ck_individual_registration_versions_values"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Saída: motivo moved|death, com a data; óbito exige a data do óbito; data
  # do óbito e número da DO só com death. `exit_reason IS NOT NULL AND ...`
  # porque NULL = x é NULL, e CHECK com NULL passa.
  def registration_exit_check(prefix)
    "#{prefix} AND " \
      "(exit_reason IS NULL OR exit_reason::text = ANY (ARRAY['moved'::text, 'death'::text])) AND " \
      "((exit_reason IS NULL) = (exited_on IS NULL)) AND " \
      "((exit_reason IS NOT NULL AND exit_reason::text = 'death'::text) = (death_on IS NOT NULL)) AND " \
      "(death_certificate IS NULL OR death_on IS NOT NULL)"
  end
end
