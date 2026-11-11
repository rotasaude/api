# Módulo 33 (ADR 0051): ouvidoria. Esta migração traz a parte transversal: os
# três papéis (ombudsman, ombudsman_staff e ombudsman_responder) no CHECK de
# memberships, a finalidade ombudsman_attachment do upload (exam_files) e os
# setores da secretaria (departments: nunca apagados, nome único sem distinguir
# caixa). Trigger em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddOmbudsmanRolesAndDepartments < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver exam_provider exam_regulator
             health_professional lab_releaser lab_staff municipal_admin ombudsman ombudsman_responder ombudsman_staff
             pharmacist pharmacy_assistant protocol_author protocol_publisher protocol_reviewer psychosocial_lead
             psychosocial_staff stock_keeper surveillance tfd_committee transport_dispatcher viewer].freeze
  PURPOSES = %w[eqa_annual_report tfd_accountability ombudsman_attachment].freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"
    replace_check :exam_files, "ck_exam_files_purpose",
                  "purpose IS NULL OR purpose::text = ANY (ARRAY[#{quoted(PURPOSES)}]::text[])"

    create_table :departments, id: :uuid do |t|
      t.string :name, limit: 80, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :departments, "lower(name)", unique: true, name: "idx_departments_name"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
