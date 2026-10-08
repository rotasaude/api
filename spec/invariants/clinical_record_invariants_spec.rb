# spec/invariants/clinical_record_invariants_spec.rb
require "rails_helper"

# Módulo 19, critério de fechamento (ADR 0031, "Invariantes"). Cada bloco tem
# a mutação que precisa deixá-lo vermelho.
RSpec.describe "Invariantes do prontuário (ADR 0031)", type: :request do
  before do
    clinical_city!
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:marker) { "MARCADOR#{SecureRandom.hex(4)}" }
  def body = JSON.parse(response.body)
  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  # Mutação: tirar o ramo `OLD.status = 'finalized'` de rota_consultation_guard.
  it "consulta finalizada não muda; correção só por adendo" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect { attempt { consultation.update_columns(plan: "reescrito", care_type: 6) } }
      .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
    expect { attempt { ConsultationConduct.create!(consultation: consultation, code: 9, action: "add") } }
      .to raise_error(ActiveRecord::StatementInvalid, /only come with an addendum/)
    expect(Consultations::SaveDraft.call(consultation: consultation, params: { "plan" => "x" }, by: doctor).reason).to eq(:not_draft)
  end

  # Mutação: tirar o NOT EXISTS de rota_patient_problem_guard, ou gravar o
  # problema antes do evento em Patients::ApplyProblemEvent.
  it "patient_problems só muda por evento ligado a consulta ou adendo" do
    finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    problem = PatientProblem.sole
    expect { attempt { problem.update!(status: "resolved", resolved_on: Time.zone.today) } }
      .to raise_error(ActiveRecord::StatementInvalid, /changes only through an event/)
    expect(PatientProblemEvent.where(patient_problem_id: problem.id).pluck(:consultation_id, :addendum_id))
      .to all(satisfy { |consultation_id, addendum_id| consultation_id.present? ^ addendum_id.present? })
  end

  # Mutação: tirar ClinicalRecord::Trail.viewed! de qualquer ação de leitura.
  it "nenhuma leitura de prontuário sem trilha" do
    citizen = verified_citizen!(1)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
    nurse = doctor!(unit, cbo: "223505")
    now = Time.current
    ClinicalRecordOpening.create!(patient: consultation.patient, user: nurse, reason_code: "case_review", created_at: now,
                                  expires_at: now + 30.minutes)
    reads = [ [ doctor, "/attendance/attendances/#{attendance.id}/record" ], [ doctor, "/attendance/consultations/#{consultation.id}" ],
              [ doctor, "/attendance/consultations/#{consultation.id}/print" ], [ nurse, "/clinical_record/patients/#{consultation.patient_id}" ] ]
    reads.each do |user, path|
      sign_in_as(user)
      expect { get path }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1), path
      expect(response).to have_http_status(:ok), path
    end
  end

  # Mutação: tirar :subjective/:plan/:text/:full_name de filter_parameters, pôr
  # texto ou nome em payload de evento ou argumento de job, ou devolver o texto
  # recebido numa mensagem de erro.
  it "nenhum texto clínico nem nome em evento, log, job, Analytics ou mensagem de erro" do
    citizen = verified_citizen!(1, full_name: "#{marker} Nome")
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    log = capture_log do
      sign_in_as(doctor)
      json_post "/attendance/attendances/#{attendance.id}/consultation"
      id = body["id"]
      patch "/attendance/consultations/#{id}", params: draft_body(subjective: "S #{marker}", plan: "P #{marker}").to_json,
                                               headers: { "CONTENT_TYPE" => "application/json" }
      patch "/attendance/consultations/#{id}", params: { "objective" => "#{marker} " * 3000 }.to_json,
                                               headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include(marker)
      json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
      json_post "/attendance/consultations/#{id}/addenda", reason: "motivo #{marker}", text: "adendo #{marker}"
      expect(response).to have_http_status(:created)
    end
    [ log, DomainEvent.pluck(:payload).to_json, ActiveJob::Base.queue_adapter.enqueued_jobs.to_json ].each do |text|
      expect(text).not_to include(marker)
    end
    analytics = Dir[Rails.root.join("app/services/analytics/**/*.rb")].map { |f| File.read(f) }.join
    expect(analytics).not_to match(/consultations|consultation_addenda|clinical_record_openings|full_name|social_name|mother_name/)
  end

  # Mutação: trocar require_professional por require_attendance_staff em
  # qualquer controller do prontuário.
  it "a recepção nunca lê o prontuário" do
    citizen = verified_citizen!(1, full_name: "#{marker} Nome")
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, subjective: "S #{marker}")
    attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
    sign_in_as(reception!)
    [ "/attendance/attendances/#{attendance.id}/record", "/attendance/consultations/#{consultation.id}",
      "/attendance/consultations/#{consultation.id}/print", "/clinical_record/patients/#{consultation.patient_id}" ].each do |path|
      get path
      expect(response).to have_http_status(:forbidden), path
      expect(response.body).not_to include(marker)
    end
  end

  # Mutação: tirar a checagem de verification_level de Patients::Resolve, ou o
  # NEW.verification_level de rota_citizen_patient_link_guard.
  it "consulta só para par validado; par declarado nunca ligado a paciente" do
    declared = screening_citizen!(9)
    attendance = consulting_attendance!(unit, citizen: declared, doctor: doctor)
    expect(Consultations::Start.call(attendance: attendance, by: doctor).reason).to eq(:citizen_not_verified)
    patient = Patients::Resolve.call(verified_citizen!(2)).payload[:patient]
    expect { attempt { declared.update_columns(patient_id: patient.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /only a verified pair links/)
    expect(Citizen.where.not(patient_id: nil).where(verification_level: "declared")).to be_empty
  end

  # Mutação: tirar ledi_outbox_correction_guard, ou fazer correction! gravar
  # status "pending".
  it "nenhuma correção de ficha aceita é enviada enquanto o reenvio após aceite não for confirmado" do
    stub_pec!
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return(nil)
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    exportable_unit!(unit, doctor)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Current.set(city: city) { Ledi::ConsultationFicha.generate(consultation) }
    accepted = LediOutboxEntry.sole.tap(&:accept!)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "conduta acrescentada", text: "x",
                                    changes: { "conducts" => [ 1, 9 ] })
    Current.set(city: city) { Ledi::ConsultationFicha.refresh!(consultation.reload) }
    allow(Ledi::DeliverJob).to receive(:perform_later).and_call_original
    CityConnection.with(city) { Ledi::DeliverJob.perform_now }
    expect(FakePec.for("https://pec.a.test").deliveries).to be_empty
    expect(LediOutboxEntry.find_by!(replaces_outbox_id: accepted.id).status).to eq("correction_pending")
    expect { attempt { LediOutboxEntry.find_by!(replaces_outbox_id: accepted.id).update_columns(status: "pending") } }
      .to raise_error(ActiveRecord::StatementInvalid, /stays correction_pending/)
  end

  # ADR 0026 + 0031: paciente com consulta é retido na exclusão; a revogação
  # não afeta o prontuário. Mutação: tirar Attendance de RequestErasure.attended?.
  it "paciente com consulta é retido; revogação não desliga" do
    citizen = verified_citizen!(1)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("retained")
    Citizens::RevokeVerification.call(verification: citizen.reload.active_verification, reason: "documento rasurado",
                                      by: staff_with("adm-#{SecureRandom.hex(3)}@x.gov.br", "municipal_admin"))
    expect(citizen.reload.patient_id).to be_present
  end
end

# Mutação: trocar `e.txid = txid_current()` por nada em rota_patient_problem_guard.
# Fora de fixture transacional: o evento COMMITA numa transação e o UPDATE vem
# de outra. Dentro de transação de teste as duas coisas coincidem e o trigger
# nunca é provado contra evento alheio.
RSpec.describe "patient_problems: evento de outra transação não basta (ADR 0031)" do
  self.use_transactional_tests = false

  let(:problem_id) { SecureRandom.uuid }
  let(:conn) { ApplicationRecord.connection }

  # Linhas sintéticas inseridas com os triggers desligados (replica também
  # dispensa as FKs); nada aqui passa pelos comandos.
  before do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute(<<~SQL)
          INSERT INTO patient_problems (id, patient_id, terminology, code, terminology_release_id, status, created_at, updated_at)
          VALUES ('#{problem_id}', gen_random_uuid(), 'ciap2', 'A01', gen_random_uuid(), 'active', now(), now())
        SQL
      end
      # Evento ligado ao resolve, commitado ANTES (outra transação).
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute(<<~SQL)
          INSERT INTO patient_problem_events (patient_problem_id, kind, status_after, resolved_on, user_id, consultation_id, created_at)
          VALUES ('#{problem_id}', 'resolved', 'resolved', current_date, gen_random_uuid(), gen_random_uuid(), now())
        SQL
      end
    end
  end

  after do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute("DELETE FROM patient_problem_events WHERE patient_problem_id = '#{problem_id}'")
        conn.execute("DELETE FROM patient_problems WHERE id = '#{problem_id}'")
      end
    end
  end

  it "recusa o UPDATE quando o evento foi commitado em outra transação" do
    CityConnection.with(TEST_CITY_A) do
      expect do
        ApplicationRecord.transaction do
          conn.execute("UPDATE patient_problems SET status = 'resolved', resolved_on = current_date WHERE id = '#{problem_id}'")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /changes only through an event of the same transaction/)
      expect(conn.select_value("SELECT status FROM patient_problems WHERE id = '#{problem_id}'")).to eq("active")
    end
  end

  # Controle positivo: com um evento da MESMA transação o mesmo UPDATE passa
  # (prova que a recusa acima é pelo txid, não por outra coisa). Rollback no fim.
  it "aceita o mesmo UPDATE com evento da mesma transação" do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute(<<~SQL)
          INSERT INTO patient_problem_events (patient_problem_id, kind, status_after, resolved_on, user_id, consultation_id, created_at)
          VALUES ('#{problem_id}', 'resolved', 'resolved', current_date, gen_random_uuid(), gen_random_uuid(), now())
        SQL
        conn.execute("SET LOCAL session_replication_role = origin")
        conn.execute("UPDATE patient_problems SET status = 'resolved', resolved_on = current_date WHERE id = '#{problem_id}'")
        expect(conn.select_value("SELECT status FROM patient_problems WHERE id = '#{problem_id}'")).to eq("resolved")
        raise ActiveRecord::Rollback
      end
    end
  end
end
