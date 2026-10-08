require "rails_helper"

# Módulo 19 (ADR 0031; spec §3): o banco garante o que o modelo não vê — par
# declarado nunca se liga, a ligação não troca, a lista só muda com evento da
# mesma transação, eventos e divergências são só acréscimo, sem dois ativos iguais.
RSpec.describe "Guardas das tabelas do paciente" do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:doctor) { User.create!(email_address: "medica-#{SecureRandom.hex(3)}@cidade.gov.br", password: "senha-segura-123") }
  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patient.create!(cpf: citizen.cpf, full_name: "Maria Aparecida da Silva") }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  # Evento com uma consulta qualquer (a FK para consultations nasce na Task 7).
  def event!(problem_id, kind:, status_after:, **values)
    PatientProblemEvent.create!({ patient_problem_id: problem_id, kind: kind, consultation_id: SecureRandom.uuid,
                                  user: doctor, status_after: status_after }.merge(values))
  end

  def problem!(code: "T90", status: "active", **values)
    id = SecureRandom.uuid
    event!(id, kind: "added", status_after: status, **values)
    PatientProblem.create!({ id: id, patient: patient, terminology: "ciap2", code: code, status: status,
                             terminology_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id }.merge(values))
  end

  describe "citizens" do
    it "nome cifrado com a chave da cidade; nome de exibição prefere o social" do
      citizen.update!(social_name: "Mariana")
      raw = ApplicationRecord.connection.select_value("SELECT full_name FROM citizens WHERE id = #{ApplicationRecord.connection.quote(citizen.id)}")
      expect(raw).not_to include("Maria")
      expect(citizen.reload.display_name).to eq("Mariana")
      citizen.update!(social_name: nil)
      expect(citizen.display_name).to eq("Maria Aparecida da Silva")
    end

    it "par declarado nunca se liga; a ligação nunca troca" do
      # O paciente (e o par validado) nascem FORA do savepoint abaixo: criados
      # dentro dele, o rollback os levaria, e os UPDATEs seguintes não achariam
      # linha nenhuma (0 linhas, nenhum trigger, nenhum erro).
      patient
      declared = screening_citizen!(2)
      expect { attempt { declared.update_columns(patient_id: patient.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /only a verified pair links to a patient/)
      citizen.update_columns(patient_id: patient.id)
      other = Patient.create!(cpf: screening_citizen!(3).cpf)
      expect { attempt { citizen.update_columns(patient_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /patient link never changes/)
    end

    it "revogar a validação não desliga o par (ADR 0031)" do
      citizen.update_columns(patient_id: patient.id)
      expect { citizen.update!(verification_level: "declared") }.not_to raise_error
      expect(citizen.reload.patient_id).to eq(patient.id)
    end
  end

  describe "patients" do
    it "um por CPF; nunca some; CPF nunca muda" do
      patient
      expect { attempt { Patient.create!(cpf: citizen.cpf) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { patient.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { attempt { patient.update_columns(cpf: "11144477735") } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end

    # A re-cifra (CityRekey/ReencryptionJob) regrava as colunas cifradas — o
    # cpf determinístico muda de texto cifrado sem mudar de valor. Só com a
    # marca rota.reencrypting da transação; o resto da identidade segue fixo.
    it "a re-cifra regrava o cpf só com a marca rota.reencrypting" do
      patient
      connection = ApplicationRecord.connection
      # SET LOCAL sobrevive ao RELEASE SAVEPOINT: no sucesso a marca volta a
      # 'off' na mão; na falha, o ROLLBACK TO SAVEPOINT já a desfaz.
      with_reencrypting = lambda do |&block|
        attempt do
          connection.execute("SET LOCAL rota.reencrypting = 'on'")
          block.call
          connection.execute("SET LOCAL rota.reencrypting = 'off'")
        end
      end

      expect { attempt { patient.update_columns(cpf: "11144477735") } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect { with_reencrypting.call { patient.update_columns(cpf: "11144477735", full_name: "Maria A. da Silva") } }
        .not_to raise_error
      expect(patient.reload.cpf).to eq("11144477735")
      expect { with_reencrypting.call { patient.update_columns(created_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect { with_reencrypting.call { patient.update_columns(id: SecureRandom.uuid) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end

    # Sob a marca, só as colunas cifradas mudam (o mesmo critério das consultas).
    it "com a marca da re-cifra, nada além das colunas cifradas muda" do
      patient
      expect { attempt { CityEncryption.allowing_reencryption { patient.update_columns(updated_at: 1.day.from_now) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /re-encryption only rewrites the encrypted columns/)
      expect { CityEncryption.allowing_reencryption { patient.reload.encrypt } }.not_to raise_error
      expect(patient.reload.slice(:cpf, :full_name)).to eq("cpf" => citizen.cpf, "full_name" => "Maria Aparecida da Silva")
    end
  end

  describe "patient_problems" do
    it "só nasce e só muda com evento da mesma transação e com os mesmos valores" do
      expect do
        attempt do
          PatientProblem.create!(patient: patient, terminology: "ciap2", code: "K86", status: "active",
                                 terminology_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /changes only through an event/)

      problem = problem!
      expect { attempt { problem.update!(status: "resolved", resolved_on: Time.zone.today) } }
        .to raise_error(ActiveRecord::StatementInvalid, /changes only through an event/)
      expect do
        attempt do
          event!(problem.id, kind: "resolved", status_after: "active")
          problem.update!(status: "resolved", resolved_on: Time.zone.today)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /changes only through an event/)

      event!(problem.id, kind: "resolved", status_after: "resolved", resolved_on: Time.zone.today)
      expect { problem.update!(status: "resolved", resolved_on: Time.zone.today) }.not_to raise_error
    end

    it "sem dois ativos iguais por paciente; identidade fixa; DELETE recusado; CHECKs" do
      problem = problem!
      expect { attempt { problem!(code: "T90") } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { problem.update_columns(code: "K86") } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect { attempt { problem.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      {
        { code: "t90" } => /ck_patient_problems_code/,
        { status: "resolved" } => /ck_patient_problems_resolution/,
        { onset_on: Date.new(2025, 1, 1) } => /ck_patient_problems_onset/,
        { onset_on: Date.new(2025, 1, 1), onset_precision: "week" } => /ck_patient_problems_onset_precision/
      }.each do |values, error|
        expect { attempt { problem!(code: "K86", **values) } }.to raise_error(ActiveRecord::StatementInvalid, error), values.inspect
      end
    end
  end

  describe "patient_problem_events e patient_profile_divergences" do
    it "só acréscimo; consulta XOR adendo; tipo da lista" do
      problem = problem!
      event = PatientProblemEvent.where(patient_problem_id: problem.id).sole
      expect { attempt { event.update_columns(kind: "resolved") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { attempt { event.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect do
        attempt do
          PatientProblemEvent.create!(patient_problem_id: problem.id, kind: "added", user: doctor, status_after: "active")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /ck_patient_problem_events_source/)
      expect { attempt { event!(problem.id, kind: "edited", status_after: "active") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_patient_problem_events_kind/)
      divergence = PatientProfileDivergence.create!(patient: patient, citizen: citizen, fields: %w[sex])
      expect { attempt { divergence.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { attempt { PatientProfileDivergence.create!(patient: patient, citizen: citizen, fields: %w[cpf]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_patient_profile_divergences_fields/)
    end
  end
end
