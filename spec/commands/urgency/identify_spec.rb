require "rails_helper"

# Módulo 32a (ADR 0050, R4; plano, Desvios 5–7; contrato §4 e §14 Q5, Q15,
# Q17, Q21, Q23): a identificação do paciente provisório, uma vez só. Com um
# paciente real existente, a fusão move para ele as linhas de
# Urgency::Merge::TABLES (sob a marca rota.patient_merge), deixa as trilhas
# (KEPT) e as linhas que bateriam em chave única do real (kept_duplicates) com
# o provisório, e grava merged_into_id. Qualquer linha do provisório numa
# tabela bloqueante recusa tudo. Com um paciente novo, o provisório recebe os
# dados e deixa de ser provisório, sem fusão. Os exemplos procuram a fusão
# errada: nada pode ir para a pessoa errada, nem ficar dividido.
RSpec.describe Urgency::Identify do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:other_upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:real) { urgency_patient!(1) }
  let(:encounter) { arrived!(upa, unidentified: "Homem, 50 anos, desacordado na praça") }
  # Ansioso: depois da fusão, encounter.patient já é o real.
  let!(:provisional) { encounter.patient }

  def identify(**args) = described_class.call(encounter: UrgencyEncounter.find(encounter.id), by: upa_reception!, **args)

  # Consulta gravada direto (a consulta de urgência pelo comando é da Task 10).
  def consultation_for!(attendance, patient, by: doctor)
    link = by.professional.links.active.sole
    Consultation.create!(attendance: attendance, patient: patient, author_user: by, professional_link: link,
                         cbo_code: link.cbo_code, status: "draft", started_at: Time.current)
  end

  def problem!(patient, consultation, code)
    id = SecureRandom.uuid
    PatientProblemEvent.create!(patient_problem_id: id, kind: "added", consultation_id: consultation.id, user: doctor, status_after: "active")
    PatientProblem.create!(id: id, patient: patient, terminology: "ciap2", code: code, status: "active",
                           terminology_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id)
  end

  def medication!(patient, consultation)
    id = SecureRandom.uuid
    PatientMedicationEvent.create!(patient_medication_id: id, kind: "added", consultation_id: consultation.id, user: doctor,
                                   status_after: "active")
    PatientMedication.create!(id: id, patient: patient, free_text: "Dipirona 500 mg", label: "Dipirona 500 mg",
                              origin: "prescription", status: "active")
  end

  def notification!(patient)
    DiseaseNotification.create!(patient: patient, disease_code: "dengue", disease_list_version: 1, deadline: "weekly", origin: "manual",
                                status: "notified", suspected_on: Date.current, due_at: 7.days.from_now, health_unit: upa, form: {})
  end

  def document!(patient, consultation)
    ClinicalDocument.create!(kind: "sick_note", patient_id: patient.id, citizen_id: screening_citizen!(1).id, consultation: consultation,
                             attendance: consultation.attendance, author_user_id: doctor.id, cbo_code: "225125", issue_mode: "paper",
                             verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.short_code,
                             issued_at: Time.current,
                             content: { "type" => "leave", "days" => 1, "start_on" => Time.zone.today.iso8601, "cid_authorized" => false }.to_json)
  end

  def exam_result!(order)
    ExamResult.create!(exam_order: order, patient_id: order.patient_id, sigtap_code: order.sigtap_code, origin: "order", source: "unit",
                       pdf_file: pdf_file!(user: doctor), values: [ { "key" => "hba1c", "value" => "9.1" } ].to_json,
                       released_on: Time.zone.today, laboratory_name: "Lab", critical: false, registered_by_user: doctor)
  end

  def regulation!(patient, consultation)
    RegulationRequest.create!(patient: patient, consultation: consultation, requester_user: doctor, requester_cbo: "225125",
                              requester_unit: upa, target_type: "specialty", target_code: "225120", target_name: "Médico cardiologista",
                              cid10: "I10", justification: "Hipertensão resistente a três fármacos", suggested_color: "yellow",
                              status: "pending", requested_at: Time.current, due_on: Date.current + 30)
  end

  def dispensation!(patient)
    keeper = staff_with("almox-#{SecureRandom.hex(2)}@cidade.gov.br", "stock_keeper")
    location = unit_location!
    external = ExternalPrescription.create!(patient: patient, stock_location: location, prescriber_name: "Dra. Beltrana", council: "CRM",
                                            council_state: "PR", council_number: "12345", issued_on: Date.current,
                                            notification_number: "PR-123456", recorded_by_user: keeper)
    Dispensation.create!(stock_location: location, patient: patient, external_prescription: external, dispensed_by_user: keeper,
                         dispensed_by_role: "pharmacist", dispensed_at: Time.current)
  end

  # Quantas linhas de cada tabela de TABLES (e de KEPT) apontam o paciente.
  def rows_of(patient)
    connection = ApplicationRecord.connection
    (Urgency::Merge::TABLES + Urgency::Merge::KEPT).to_h do |table|
      [ table, connection.select_value("SELECT count(*) FROM #{table} WHERE patient_id = #{connection.quote(patient.id)}").to_i ]
    end
  end

  it "funde: o atendimento, a consulta, os documentos, os exames, a lista, a farmácia e o BPA passam ao real; trilhas e repetidos ficam" do
    ciap2_release!
    classified!(encounter, color: "red", by: nurse, vital_signs: { spo2: 85 })
    called!(encounter, by: doctor)
    consultation = consultation_for!(encounter.attendance, provisional)
    order = exam_order!(patient: provisional, unit: upa, requester: doctor, status: :awaiting_authorization)
    moved = {
      consultation: consultation, document: document!(provisional, consultation), order: order, result: exam_result!(order),
      procedure: raw_procedure!(unit: upa, patient: provisional, professional: doctor), regulation: regulation!(provisional, consultation),
      dispensation: dispensation!(provisional), problem: problem!(provisional, consultation, "K86"), medication: medication!(provisional, consultation)
    }
    external = moved[:dispensation].external_prescription
    # O real já tem ativo o T90 e uma notificação aberta de dengue: as do provisório ficam (Q17, Q21).
    real_consultation = consultation_for!(arrived!(other_upa, patient: real).attendance, real, by: upa_doctor!(other_upa))
    problem!(real, real_consultation, "T90")
    notification!(real)
    repeated_problem = problem!(provisional, consultation, "T90")
    repeated_notification = notification!(provisional)
    opening = ClinicalRecordOpening.create!(patient: provisional, user: doctor, reason_code: "case_review", created_at: Time.current,
                                            expires_at: 30.minutes.from_now)
    other = arrived!(upa, unidentified: "Mulher, 20 anos")
    real_consultations = Consultation.where(patient_id: real.id).pluck(:id)

    result = identify(patient_id: real.id)

    expect(result).to be_ok
    expect(result.payload).to include(patient: real, merged_from_id: provisional.id)
    expect(encounter.attendance.reload.patient_id).to eq(real.id)
    moved.each_value { |row| expect(row.class.find(row.id).patient_id).to eq(real.id) }
    expect(external.reload.patient_id).to eq(real.id)
    expect(provisional.reload).to have_attributes(merged_into_id: real.id, unidentified: true)
    expect([ repeated_problem, repeated_notification, opening ].map { |row| row.reload.patient_id }).to all(eq(provisional.id))
    expect(other.attendance.reload.patient_id).to eq(other.patient.id)
    expect(Consultation.where(patient_id: real.id).pluck(:id)).to match_array(real_consultations + [ consultation.id ])
    left = rows_of(provisional).select { |_, count| count.positive? }
    expect(left).to eq("patient_problems" => 1, "disease_notifications" => 1, "clinical_record_openings" => 1)
    expect(result.payload[:kept_duplicates]).to eq("patient_problems" => 1, "disease_notifications" => 1)
    expect(result.payload[:moved]).to include("attendances" => 1, "consultations" => 1, "clinical_documents" => 1, "exam_orders" => 1,
                                              "exam_results" => 1, "performed_procedures" => 1, "regulation_requests" => 1,
                                              "dispensations" => 1, "external_prescriptions" => 1, "patient_problems" => 1,
                                              "patient_medications" => 1)
    event = DomainEvent.where(name: "urgency.patient_identified").sole
    expect(event.payload).to eq("encounter_id" => encounter.id, "patient_id" => real.id, "merged_from_id" => provisional.id,
                                "moved" => result.payload[:moved].values.sum, "kept_duplicates" => 2)
  end

  it "o real com walk_in aberto na mesma UPA: o atendimento do provisório bate na chave única e fica com ele (Q21)" do
    arrived!(upa, patient: real)
    result = identify(patient_id: real.id)
    expect(result).to be_ok
    expect(result.payload[:kept_duplicates]).to eq("attendances" => 1)
    expect(encounter.attendance.reload.patient_id).to eq(provisional.id)
    expect(provisional.reload.merged_into_id).to eq(real.id)
    expect(identify(patient_id: urgency_patient!(7).id).reason).to eq(:already_identified)
  end

  it "uma vez só: a segunda identificação, para o mesmo ou outro paciente ou paciente novo, é 409 e não move nada" do
    expect(identify(patient_id: real.id)).to be_ok
    second = urgency_patient!(2)
    expect(identify(patient_id: second.id).reason).to eq(:already_identified)
    expect(identify(patient_id: real.id).reason).to eq(:already_identified)
    expect(identify(new_patient: { "full_name" => "Fulano de Tal", "birth_date" => "1970-01-01", "sex" => "male", "no_cpf_reason" => "3" })
             .reason).to eq(:already_identified)
    expect(encounter.attendance.reload.patient_id).to eq(real.id)
    expect(provisional.reload.merged_into_id).to eq(real.id)
    expect(rows_of(second).values.sum).to eq(0)
    expect(DomainEvent.where(name: "urgency.patient_identified").count).to eq(1)
  end

  it "encontro de paciente que nunca foi provisório → not_unidentified; o identificado por dados novos → already_identified" do
    known = arrived!(upa, patient: real)
    refused = described_class.call(encounter: known, patient_id: urgency_patient!(2).id, by: upa_reception!)
    expect(refused.reason).to eq(:not_unidentified)
    expect(identify(new_patient: { "full_name" => "Benedito Ramos Filho", "birth_date" => "1960-07-07", "sex" => "male",
                                   "no_cpf_reason" => "3" })).to be_ok
    expect(identify(patient_id: urgency_patient!(3).id).reason).to eq(:already_identified)
  end

  it "nunca funde em provisório, em fundido, em inexistente, nem pelo CPF ou CNS digitado: nada muda" do
    ciap2_release!
    called!(classified!(encounter, color: "yellow", by: nurse), by: doctor)
    consultation = consultation_for!(encounter.attendance, provisional)
    problem!(provisional, consultation, "K86")
    before = rows_of(provisional)
    other = arrived!(upa, unidentified: "Outro provisório")
    merged = arrived!(other_upa, unidentified: "Já fundido")
    expect(described_class.call(encounter: merged, patient_id: urgency_patient!(4).id, by: upa_reception!)).to be_ok

    expect(identify(patient_id: other.patient.id)).to have_attributes(reason: :invalid_request, details: { path: "patient_id" })
    expect(identify(patient_id: Patient.find_by!(merged_into_id: merged.reload.patient.id).id))
      .to have_attributes(reason: :invalid_request, details: { path: "patient_id" })
    expect(identify(patient_id: provisional.id)).to have_attributes(reason: :invalid_request, details: { path: "patient_id" })
    expect(identify(patient_id: SecureRandom.uuid)).to have_attributes(reason: :patient_not_found, details: { path: "patient_id" })
    expect(identify(patient_id: "nao-e-uuid")).to have_attributes(reason: :invalid_request, details: { path: "patient_id" })
    expect(identify(new_patient: { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-02-01", "sex" => "male",
                                   "cpf" => real.cpf }).reason).to eq(:cpf_taken)
    expect(identify(new_patient: { "full_name" => "Ana Clara Souza", "birth_date" => "1990-03-03", "sex" => "female",
                                   "no_cpf_reason" => "3", "cns" => real.cns }).reason).to eq(:cns_taken)

    expect(provisional.reload).to have_attributes(merged_into_id: nil, unidentified: true, full_name: nil, cpf: nil, cns: nil)
    expect(rows_of(provisional)).to eq(before)
    expect(DomainEvent.where(name: "urgency.patient_identified").count).to eq(1)
  end

  it "bloqueia a fusão quando o provisório tem linha numa tabela fora das listas (ex.: vacina): nada muda" do
    ciap2_release!
    consultation = consultation_for!(called!(classified!(encounter, color: "green", by: nurse), by: doctor).attendance, provisional)
    problem!(provisional, consultation, "K86")
    VaccinationRecordCheck.create!(patient: provisional, mode: "born_after_go_live", checked_at: Time.current)
    before = rows_of(provisional)
    expect(Urgency::Merge.blocking_tables).to include("vaccination_record_checks")

    expect(identify(patient_id: real.id).reason).to eq(:merge_blocked)
    expect(rows_of(provisional)).to eq(before)
    expect(provisional.reload.merged_into_id).to be_nil
    expect(DomainEvent.where(name: "urgency.patient_identified")).to be_empty
  end

  it "forma: exatamente uma de patient_id e new_patient; chave desconhecida em new_patient é recusada" do
    expect(identify).to have_attributes(reason: :invalid_request, details: { path: "patient" })
    expect(identify(patient_id: real.id, new_patient: { "full_name" => "Fulano de Tal" }))
      .to have_attributes(reason: :invalid_request, details: { path: "patient" })
    expect(identify(new_patient: { "full_name" => "Fulano de Tal", "apelido" => "x" }))
      .to have_attributes(reason: :invalid_request, details: { path: "new_patient.apelido" })
    expect(identify(new_patient: { "full_name" => "Fulano de Tal", "birth_date" => "1970-01-01", "sex" => "male", "no_cpf_reason" => "3" },
                    duplicates_reviewed: "sim")).to have_attributes(reason: :invalid_request, details: { path: "duplicates_reviewed" })
  end

  describe "paciente novo" do
    it "o provisório recebe os dados e deixa de ser provisório, sem fundir; a descrição fica" do
      result = identify(new_patient: { "full_name" => "Benedito Ramos Filho", "birth_date" => "1960-07-07", "sex" => "male",
                                       "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("urgency:novo") })
      expect(result).to be_ok
      expect(result.payload).to include(patient: provisional, merged_from_id: nil)
      expect(provisional.reload).to have_attributes(unidentified: false, full_name: "Benedito Ramos Filho", merged_into_id: nil,
                                                    no_cpf_reason: "3", unidentified_description: "Homem, 50 anos, desacordado na praça")
      expect(provisional.cns).to be_present
      expect(encounter.attendance.reload.patient_id).to eq(provisional.id)
      expect(DomainEvent.where(name: "urgency.patient_identified").sole.payload)
        .to eq("encounter_id" => encounter.id, "patient_id" => provisional.id)
    end

    it "com CPF novo: o CPF entra pelo AddCpf e a justificativa sai" do
      cpf = urgency_cpf(40)
      result = identify(new_patient: { "full_name" => "Benedito Ramos Filho", "birth_date" => "1960-07-07", "sex" => "male", "cpf" => cpf })
      expect(result).to be_ok
      expect(provisional.reload).to have_attributes(unidentified: false, cpf: cpf, no_cpf_reason: nil)
    end

    it "duplicado suspeito → duplicate_suspected com os candidatos; com duplicates_reviewed segue" do
      twin = urgency_patient!(5, cpf: false)
      typed = { "full_name" => twin.full_name, "birth_date" => twin.birth_date, "sex" => twin.sex, "mother_name" => twin.mother_name,
                "no_cpf_reason" => "3" }
      refused = identify(new_patient: typed)
      expect(refused).to have_attributes(reason: :duplicate_suspected)
      expect(refused.details).to include(path: "new_patient", candidate_ids: [ twin.id ])
      expect(provisional.reload.unidentified).to be(true)
      expect(identify(new_patient: typed, duplicates_reviewed: true)).to be_ok
      expect(provisional.reload.unidentified).to be(false)
    end
  end
end
