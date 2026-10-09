require "rails_helper"

# Módulo 19 (ADR 0031; spec §4–§5): consulta finalizada não muda; itens e
# adendos só por acréscimo (itens de consulta finalizada só com adendo);
# aberturas só acréscimo; texto clínico cifrado.
RSpec.describe "Guardas das tabelas da consulta" do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patient.create!(cpf: citizen.cpf) }
  let(:attendance) { consulting_attendance!(unit, citizen: citizen, doctor: doctor) }
  let(:link) { doctor.professional.links.active.sole }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  def consultation!(**over)
    Consultation.create!({ attendance: attendance, patient: patient, author_user: doctor, professional_link: link,
                           cbo_code: link.cbo_code, status: "draft", started_at: Time.current,
                           subjective: "MARCADOR-S", assessment: "avaliação" }.merge(over))
  end

  def finalize!(consultation) = consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5)

  def problem_row!(consultation, addendum: nil)
    id = SecureRandom.uuid
    PatientProblemEvent.create!(patient_problem_id: id, kind: "added", consultation_id: consultation.id, user: doctor,
                                status_after: "active")
    problem = PatientProblem.create!(id: id, patient: patient, terminology: "ciap2", code: "T90", status: "active",
                                     terminology_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id)
    ConsultationProblem.create!(consultation: consultation, addendum: addendum, patient_problem: problem, action: "add",
                                terminology: "ciap2", code: "T90", terminology_release_id: problem.terminology_release_id,
                                status_after: "active")
  end

  def addendum!(consultation, **over)
    ConsultationAddendum.create!({ consultation: consultation, author_user: doctor, text: "MARCADOR-ADENDO",
                                   reason: "correção do exame pedido" }.merge(over))
  end

  describe "consultations" do
    it "uma por atendimento; nunca some; identidade fixa; texto cifrado" do
      consultation = consultation!
      expect { attempt { consultation! } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { consultation.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { attempt { consultation.update_columns(author_user_id: User.create!(email_address: "x-#{SecureRandom.hex(3)}@x.br", password: "senha-segura-123").id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      raw = ApplicationRecord.connection.select_value("SELECT subjective FROM consultations WHERE id = #{ApplicationRecord.connection.quote(consultation.id)}")
      expect(raw).not_to include("MARCADOR")
    end

    it "rascunho muda; finalizada nunca muda (nem volta a rascunho)" do
      consultation = consultation!
      expect { consultation.update!(plan: "plano novo", systolic: 120, diastolic: 80) }.not_to raise_error
      finalize!(consultation)
      expect { attempt { consultation.update!(plan: "mudei depois") } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
      expect { attempt { consultation.update_columns(status: "draft", finalized_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
    end

    it "a marca da re-cifra só deixa mudar o texto cifrado" do
      consultation = consultation!
      finalize!(consultation)
      expect do
        attempt do
          ApplicationRecord.connection.execute("SET LOCAL rota.reencrypting = 'on'")
          consultation.update_columns(care_type: 6)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
      expect { CityEncryption.allowing_reencryption { consultation.encrypt } }.not_to raise_error
      expect(consultation.reload.subjective).to eq("MARCADOR-S")
      expect { attempt { CityEncryption.allowing_reencryption { consultation.update_columns(care_type: 6) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
    end

    # SET LOCAL sobrevive ao RELEASE SAVEPOINT até o fim da transação externa:
    # sem o 'off' do fim do bloco, a marca vazaria para o resto da transação.
    it "a marca não sobra depois do bloco, no sucesso nem na falha (mesma transação externa)" do
      consultation = consultation!
      finalize!(consultation)
      marker = -> { ApplicationRecord.connection.select_value("SELECT current_setting('rota.reencrypting', true)") }

      CityEncryption.allowing_reencryption { consultation.encrypt }
      expect(marker.call).to eq("off")
      expect { attempt { consultation.update_columns(plan: "regravado fora da re-cifra") } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)

      expect { CityEncryption.allowing_reencryption { raise ArgumentError, "falhou no meio" } }.to raise_error(ArgumentError)
      expect(marker.call).not_to eq("on")
      expect { attempt { consultation.update_columns(plan: "regravado fora da re-cifra") } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
    end

    # Revisão final: dentro de um `rescue` do chamador `$!` não é nulo; o
    # ensure por `$!` deixava a marca 'on' depois de um bloco com sucesso.
    it "a marca volta a 'off' quando o bloco (com sucesso) roda dentro de um rescue do chamador" do
      consultation = consultation!
      finalize!(consultation)
      marker = -> { ApplicationRecord.connection.select_value("SELECT current_setting('rota.reencrypting', true)") }

      begin
        raise ArgumentError, "erro já tratado pelo chamador"
      rescue ArgumentError
        CityEncryption.allowing_reencryption { consultation.encrypt }
      end
      expect(marker.call).to eq("off")
      expect { attempt { consultation.update_columns(plan: "regravado fora da re-cifra") } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)

      # `break` do bloco ainda é sucesso.
      [ 1 ].each { CityEncryption.allowing_reencryption { break } }
      expect(marker.call).to eq("off")
    end

    it "CHECKs: finalizada exige tipo e itens do rascunho vazios; tipo 4 não; pressão aos pares" do
      # Atendimento e paciente nascem FORA dos savepoints: criados dentro, o
      # rollback os levaria e o `let` memoizado apontaria para linha nenhuma.
      attendance
      patient
      expect { attempt { consultation!(care_type: 4) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_care_type/)
      expect { attempt { consultation!(systolic: 120) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_bp/)
      consultation = consultation!(draft_items: { "conducts" => [ 1 ] })
      expect { attempt { consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_draft_items/)
      # reload: o update! recusado acima deixa care_type: 5 atribuído em memória.
      expect { attempt { consultation.reload.update!(status: "finalized", finalized_at: Time.current, draft_items: {}) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_finalized_care_type/)
    end
  end

  describe "itens" do
    it "entram com a consulta em rascunho; depois só com adendo da mesma consulta; nunca mudam" do
      consultation = consultation!
      row = problem_row!(consultation)
      conduct = ConsultationConduct.create!(consultation: consultation, code: 9, action: "add")
      finalize!(consultation)
      expect { attempt { ConsultationConduct.create!(consultation: consultation, code: 1, action: "add") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only come with an addendum/)
      other = Consultation.create!(attendance: consulting_attendance!(unit, citizen: verified_citizen!(2), doctor: doctor),
                                   patient: Patient.create!(cpf: verified_citizen!(3).cpf), author_user: doctor,
                                   professional_link: link, cbo_code: link.cbo_code, status: "draft", started_at: Time.current)
      finalize!(other)
      foreign = addendum!(other)
      expect { attempt { ConsultationConduct.create!(consultation: consultation, addendum: foreign, code: 1, action: "add") } }
        .to raise_error(ActiveRecord::StatementInvalid, /addendum of another consultation/)
      mine = addendum!(consultation)
      expect { ConsultationConduct.create!(consultation: consultation, addendum: mine, code: 9, action: "remove") }.not_to raise_error
      expect { attempt { row.update_columns(action: "resolve") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { attempt { conduct.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "CHECKs: conduta da lista; remover só com adendo; exame do grupo 02; cancelar só com adendo" do
      consultation = consultation!
      { { code: 3, action: "add" } => /ck_consultation_conducts_code/,
        { code: 9, action: "remove" } => /ck_consultation_conducts_removal/ }.each do |attrs, error|
        expect { attempt { ConsultationConduct.create!(consultation: consultation, **attrs) } }
          .to raise_error(ActiveRecord::StatementInvalid, error)
      end
      base = { consultation: consultation, sigtap_competence: "202610", status: "requested" }
      { { sigtap_code: "0301010064" } => /ck_consultation_exam_requests_sigtap/,
        { sigtap_code: "0202010503", status: "cancelled" } => /ck_consultation_exam_requests_cancel/,
        { sigtap_code: "0202010503", cid10_justification: "e11" } => /ck_consultation_exam_requests_cid10/ }.each do |attrs, error|
        expect { attempt { ConsultationExamRequest.create!(base.merge(attrs)) } }
          .to raise_error(ActiveRecord::StatementInvalid, error), attrs.inspect
      end
    end
  end

  describe "consultation_addenda" do
    it "só em consulta finalizada; nunca muda nem some; motivo 10–500; texto cifrado" do
      consultation = consultation!
      expect { attempt { addendum!(consultation) } }.to raise_error(ActiveRecord::StatementInvalid, /only a finalized consultation/)
      finalize!(consultation)
      addendum = addendum!(consultation)
      expect { attempt { addendum.update_columns(reason: "outro motivo qualquer") } }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      expect { attempt { addendum.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { attempt { addendum!(consultation, reason: "curto") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultation_addenda_reason/)
      expect { CityEncryption.allowing_reencryption { addendum.encrypt } }.not_to raise_error
      expect { attempt { CityEncryption.allowing_reencryption { addendum.update_columns(reason: "outro motivo qualquer") } } }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      raw =ApplicationRecord.connection.select_value("SELECT text FROM consultation_addenda WHERE id = #{ApplicationRecord.connection.quote(addendum.id)}")
      expect(raw).not_to include("MARCADOR")
    end
  end

  describe "clinical_record_openings" do
    it "só acréscimo; nota só com other; validade positiva" do
      now = Time.current
      opening = ClinicalRecordOpening.create!(patient: patient, user: doctor, reason_code: "case_review",
                                              created_at: now, expires_at: now + 30.minutes)
      expect { attempt { opening.update_columns(expires_at: now + 1.day) } }.to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      expect { attempt { opening.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { attempt { CityEncryption.allowing_reencryption { opening.update_columns(expires_at: now + 1.day) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      { { reason_code: "other" } => /ck_clinical_record_openings_note/,
        { reason_code: "case_review", reason_note: "nota sem other" } => /ck_clinical_record_openings_note/,
        { reason_code: "curiosidade" } => /ck_clinical_record_openings_reason/,
        { reason_code: "case_review", expires_at: now } => /ck_clinical_record_openings_expiry/ }.each do |attrs, error|
        expect do
          attempt { ClinicalRecordOpening.create!({ patient: patient, user: doctor, created_at: now, expires_at: now + 30.minutes }.merge(attrs)) }
        end.to raise_error(ActiveRecord::StatementInvalid, error), attrs.inspect
      end
      expect(ClinicalRecordOpening.valid_for(user_id: doctor.id, patient_id: patient.id, now: now + 29.minutes)).to eq([ opening ])
      expect(ClinicalRecordOpening.valid_for(user_id: doctor.id, patient_id: patient.id, now: now + 30.minutes)).to be_empty
    end
  end

  # Task 23 (decisão do usuário 2026-10-09): a leitura administrativa fica
  # para sempre — sem UPDATE, DELETE nem TRUNCATE, sem exceção de re-cifra
  # (não há coluna cifrada) nem de exclusão LGPD (como as aberturas).
  describe "clinical_record_administrative_reads" do
    it "só acréscimo, inclusive com a marca da re-cifra; o banco preenche created_at" do
      consultation = consultation!
      finalize!(consultation)
      read = ClinicalRecordAdministrativeRead.create!(user: doctor, patient: patient, consultation: consultation)
      expect(read.reload.created_at).to be_present
      expect(read).to be_readonly
      expect { read.update!(created_at: 1.day.ago) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      other = User.create!(email_address: "x-#{SecureRandom.hex(3)}@x.br", password: "senha-segura-123")
      expect { attempt { ClinicalRecordAdministrativeRead.where(id: read.id).update_all(user_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { ClinicalRecordAdministrativeRead.where(id: read.id).update_all(created_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { CityEncryption.allowing_reencryption { ClinicalRecordAdministrativeRead.where(id: read.id).update_all(created_at: 1.day.ago) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { ClinicalRecordAdministrativeRead.where(id: read.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: DELETE refused/)
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE clinical_record_administrative_reads") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: TRUNCATE refused/)
      expect(ClinicalRecordAdministrativeRead.count).to eq(1)
    end
  end
end
