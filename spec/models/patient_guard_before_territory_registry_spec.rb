require "rails_helper"

# Módulo 24a (revisão da Task 2): as migrações de cidade anteriores à
# 20261023900001 reexecutam db/city_triggers.sql do HEAD, e o guarda dos
# pacientes renasce antes de no_cpf_reason/cns/match_key existirem. Nesse
# intervalo (ou para sempre, se a 900001 falhar), um UPDATE de paciente que
# mantém o CPF (Patients::Resolve, Demographics) não pode falhar por campo
# ausente — e o CPF segue imutável.
RSpec.describe "Guarda dos pacientes antes das colunas do cadastro territorial" do
  let(:conn) { ApplicationRecord.connection }

  def quote(value) = conn.quote(value)

  it "tolera no_cpf_reason, cns e match_key ainda ausentes e segue recusando a troca do CPF" do
    ApplicationRecord.transaction(requires_new: true) do
      id = Patient.create!(cpf: "52998224725", full_name: "Maria Aparecida da Silva").id
      conn.execute("ALTER TABLE patients DROP CONSTRAINT ck_patients_cpf_or_reason")
      conn.execute("ALTER TABLE patients DROP COLUMN no_cpf_reason, DROP COLUMN cns, DROP COLUMN match_key")
      conn.execute(File.read(Rails.root.join("db/city_triggers.sql")))
      expect(conn.column_exists?(:patients, :no_cpf_reason)).to be(false)

      conn.execute("UPDATE patients SET full_name = 'outro texto', updated_at = now() WHERE id = #{quote(id)}")
      expect(conn.select_value("SELECT full_name FROM patients WHERE id = #{quote(id)}")).to eq("outro texto")
      expect do
        ApplicationRecord.transaction(requires_new: true) do
          conn.execute("UPDATE patients SET cpf = '11144477735' WHERE id = #{quote(id)}")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      raise ActiveRecord::Rollback
    end
  ensure
    Patient.reset_column_information
  end
end
