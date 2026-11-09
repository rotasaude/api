require "rails_helper"

# Módulo 32a (ADR 0050, R4; plano, Desvios 4–6; contrato §14 Q4/Q5): o
# paciente provisório (não identificado) e a marca da fusão no banco. Tudo que
# tem o patient_id do provisório pertence ao único encontro dele; na fusão,
# sob a marca rota.patient_merge, cada guarda que recusa trocar o paciente
# aceita SÓ a troca de patient_id (e updated_at) do provisório para o
# merged_into_id gravado nele. As recusas vêm do banco (CHECKs e os triggers
# de db/city_triggers.sql), não do modelo.
RSpec.describe "Fusão do paciente provisório no banco", type: :model do
  let!(:city) { clinical_city! }
  let(:upa) { create_unit("UPA Fusão", kind: "upa") }
  let(:real) { Patient.create!(cpf: "52998224725", full_name: "Carlos Eduardo Pinto", birth_date: "1980-02-01", sex: "male") }
  let(:provisional) { Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "Homem, 40 anos, rodoviária") }
  let!(:attendance) do
    Attendance.create!(origin_kind: "walk_in", patient: provisional, health_unit: upa, checked_in_by_user: reception!,
                       checked_in_at: Time.current, check_in_method: "urgency_reception")
  end

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  # A marca, no padrão de Consultation.with_draft_admin: SET LOCAL num
  # savepoint e de volta a 'off' no sucesso (o SET LOCAL sobreviveria ao
  # RELEASE até o fim da transação do exemplo).
  def merging
    attempt do
      ApplicationRecord.connection.execute("SET LOCAL rota.patient_merge = 'on'")
      yield.tap { ApplicationRecord.connection.execute("SET LOCAL rota.patient_merge = 'off'") }
    end
  end

  it "sem a marca, ninguém troca o paciente; com a marca, só para o alvo gravado no provisório" do
    target = real
    expect { attempt { attendance.update_column(:patient_id, target.id) } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns/)
    expect { merging { attendance.update_column(:patient_id, target.id) } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns/)
    provisional.update!(merged_into: target)
    other = Patient.create!(cpf: "11144477735", full_name: "Outra Pessoa", birth_date: "1990-01-01", sex: "female")
    expect { merging { attendance.update_column(:patient_id, other.id) } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns/)
    expect { merging { attendance.update_columns(patient_id: target.id, ticket: "U-999", ticket_on: Date.current) } }
      .to raise_error(ActiveRecord::StatementInvalid, /check-in columns/)
    merging { attendance.update_column(:patient_id, target.id) }
    expect(attendance.reload.patient_id).to eq(target.id)
  end

  it "a marca vale também para o atendimento encerrado; fora da marca, nada muda" do
    target = real
    attendance.update_columns(status: "closed", outcome: "left", closed_at: Time.current, closed_by_user_id: reception!.id)
    provisional.update!(merged_into: target)
    expect { attempt { attendance.update_column(:patient_id, target.id) } }.to raise_error(ActiveRecord::StatementInvalid, /already closed/)
    merging { attendance.update_column(:patient_id, target.id) }
    expect(attendance.reload.patient_id).to eq(target.id)
  end

  it "merged_into uma vez, só para paciente identificado e nunca para si mesmo" do
    target = real
    expect { provisional.update!(merged_into: Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "Outro provisório")) }
      .to raise_error(ActiveRecord::StatementInvalid, /merge target must be an identified patient/)
    provisional.reload
    expect { attempt { provisional.update_column(:merged_into_id, provisional.id) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_patients_merged/)
    provisional.reload.update!(merged_into: target)
    expect { provisional.update!(merged_into: Patient.create!(cpf: "11144477735", full_name: "Outra", birth_date: "1990-01-01", sex: "female")) }
      .to raise_error(ActiveRecord::StatementInvalid, /merged_into never changes/)
    expect { attempt { provisional.update_column(:merged_into_id, nil) } }.to raise_error(ActiveRecord::StatementInvalid, /merged_into never changes/)
    expect { provisional.reload.update!(unidentified: false) }.to raise_error(ActiveRecord::StatementInvalid, /unmerged provisional/)
    expect { target.update!(unidentified: true) }.to raise_error(ActiveRecord::StatementInvalid, /never becomes unidentified/)
    expect(provisional.reload).to be_merged
  end

  it "o provisório identificado pelos dados digitados deixa de ser provisório" do
    provisional.update!(cpf: "11144477735", no_cpf_reason: nil, full_name: "Pedro Alves", unidentified: false)
    expect(provisional.reload).not_to be_unidentified
    expect(Patient.identified).to include(provisional)
    second = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "Mulher, 30 anos, praça")
    expect(Patient.identified).not_to include(second)
  end

  it "provisório não tem CPF nem CNS e tem a descrição, cifrada; o nome de tela não expõe a descrição" do
    expect { provisional.update!(cpf: "52998224725", no_cpf_reason: nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_patients_unidentified/)
    expect { Patient.create!(no_cpf_reason: "unidentified", unidentified: true) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_patients_description/)
    expect(provisional.display_name).to eq("Paciente não identificado")
    expect(provisional.inspect).not_to include("rodoviária")
    raw = ApplicationRecord.connection.select_value(
      "SELECT unidentified_description FROM patients WHERE id = #{ApplicationRecord.connection.quote(provisional.id)}"
    )
    expect(raw).not_to include("rodoviária")
    expect(provisional.reload.unidentified_description).to eq("Homem, 40 anos, rodoviária")
  end

  # Cada guarda que recusa trocar o paciente (Desvio 6 e contrato §14 Q5):
  # sem a marca, recusa; com a marca e outra coluna junto, recusa; com a
  # marca e só o paciente (e updated_at) para o alvo gravado, aceita.
  describe "guardas das tabelas que a fusão move" do
    let(:doctor) { doctor!(upa) }
    let(:link) { doctor.professional.links.active.sole }
    let(:consultation) do
      Consultation.create!(attendance: attendance, patient: provisional, author_user: doctor, professional_link: link,
                           cbo_code: link.cbo_code, status: "draft", started_at: Time.current)
    end

    def expect_only_the_patient_moves(row)
      target = real
      provisional.update!(merged_into: target)
      earlier = row.created_at - 1.second
      touched = row.has_attribute?(:updated_at) ? { updated_at: Time.current } : {}
      expect { attempt { row.update_columns(patient_id: target.id) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { merging { row.update_columns(patient_id: target.id, created_at: earlier) } }.to raise_error(ActiveRecord::StatementInvalid)
      merging { row.update_columns(patient_id: target.id, **touched) }
      expect(row.class.find(row.id).patient_id).to eq(target.id)
    end

    it "consultations" do
      expect_only_the_patient_moves(consultation)
    end

    it "consultations finalizadas também" do
      consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5)
      expect_only_the_patient_moves(consultation)
    end

    it "clinical_documents" do
      document = ClinicalDocument.create!(kind: "sick_note", patient_id: provisional.id, citizen_id: screening_citizen!(1).id,
                                          consultation: consultation, attendance: attendance, author_user_id: doctor.id,
                                          cbo_code: "225125", issue_mode: "paper", verification_token: ClinicalDocuments::Codes.token,
                                          short_code: ClinicalDocuments::Codes.short_code, issued_at: Time.current,
                                          content: { "type" => "leave", "days" => 1, "start_on" => Time.zone.today.iso8601,
                                                     "cid_authorized" => false }.to_json)
      expect_only_the_patient_moves(document)
    end

    it "exam_orders" do
      expect_only_the_patient_moves(exam_order!(patient: provisional, unit: upa, requester: doctor, status: :awaiting_authorization))
    end

    it "exam_results" do
      order = exam_order!(patient: provisional, unit: upa, requester: doctor, status: :awaiting_authorization)
      result = ExamResult.create!(exam_order: order, patient: provisional, sigtap_code: order.sigtap_code, origin: "order",
                                  source: "unit", pdf_file: pdf_file!(user: doctor), values: [ { "key" => "hba1c", "value" => "9.1" } ].to_json,
                                  released_on: Time.zone.today, laboratory_name: "Lab", critical: false, registered_by_user: doctor)
      expect_only_the_patient_moves(result)
    end

    it "performed_procedures" do
      expect_only_the_patient_moves(raw_procedure!(unit: upa, patient: provisional, professional: doctor))
    end

    it "disease_notifications" do
      notification = DiseaseNotification.create!(patient: provisional, disease_code: "dengue", disease_list_version: 1, deadline: "weekly",
                                                 origin: "manual", status: "notified", suspected_on: Date.current, due_at: 7.days.from_now,
                                                 health_unit: upa, form: {})
      expect_only_the_patient_moves(notification)
    end

    it "regulation_requests" do
      request = RegulationRequest.create!(patient: provisional, consultation: consultation, requester_user: doctor, requester_cbo: "225125",
                                          requester_unit: upa, target_type: "specialty", target_code: "225120",
                                          target_name: "Médico cardiologista", cid10: "I10",
                                          justification: "Hipertensão resistente a três fármacos", suggested_color: "yellow",
                                          status: "pending", requested_at: Time.current, due_on: Date.current + 30)
      expect_only_the_patient_moves(request)
    end

    it "dispensations" do
      keeper = staff_with("almox-#{SecureRandom.hex(2)}@cidade.gov.br", "stock_keeper")
      location = unit_location!
      external = ExternalPrescription.create!(patient: provisional, stock_location: location, prescriber_name: "Dra. Beltrana", council: "CRM",
                                              council_state: "PR", council_number: "12345", issued_on: Date.current,
                                              notification_number: "PR-123456", recorded_by_user: keeper)
      dispensation = Dispensation.create!(stock_location: location, patient: provisional, external_prescription: external,
                                          dispensed_by_user: keeper, dispensed_by_role: "pharmacist", dispensed_at: Time.current)
      expect_only_the_patient_moves(dispensation)
    end

    it "patient_problems" do
      ciap2_release!
      id = SecureRandom.uuid
      PatientProblemEvent.create!(patient_problem_id: id, kind: "added", consultation_id: consultation.id, user: doctor, status_after: "active")
      problem = PatientProblem.create!(id: id, patient: provisional, terminology: "ciap2", code: "T90", status: "active",
                                       terminology_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id)
      expect_only_the_patient_moves(problem)
    end

    it "patient_medications" do
      id = SecureRandom.uuid
      PatientMedicationEvent.create!(patient_medication_id: id, kind: "added", consultation_id: consultation.id, user: doctor,
                                     status_after: "active")
      medication = PatientMedication.create!(id: id, patient: provisional, free_text: "Dipirona 500 mg", label: "Dipirona 500 mg",
                                             origin: "prescription", status: "active")
      expect_only_the_patient_moves(medication)
    end
  end
end
