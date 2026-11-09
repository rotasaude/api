require "rails_helper"

# Módulo 32a, Task 16 (ADR 0050; ADR 0026; contrato §13 e §14 Q25): o encontro
# da urgência com classificação ou consulta é registro de saúde retido; a
# evasão antes da classificação (e o registro por engano sem classificação)
# segue a triagem sem atendimento — confirmada a exclusão, o paciente perde
# nome, nascimento, sexo e CNS, e o atendimento `walk_in` fica, só com ids. O
# `walk_in` não tem par (citizen_id nulo): a exclusão chega ao paciente pelo
# CPF (RequestErasure.patient_ids). O provisório (sem CPF nem CNS) nunca é
# atingido. Quem está com o atendimento aberto na UPA → patient_in_urgency, e
# o pedido segue pendente.
RSpec.describe "Exclusão LGPD com encontro da urgência (ADR 0050)" do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:admin) { staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:patient) { urgency_patient!(urgency_seq!) }
  # O par do wpda com o mesmo CPF (sem ele o pedido não acha o cidadão).
  let!(:citizen) { Citizen.create!(cpf: patient.cpf, phone: "+55419#{format('%08d', SecureRandom.random_number(10**8))}") }
  let(:cpf) { patient.cpf }

  after { Current.reset }

  def request! = Citizens::RequestErasure.call(cpf: cpf, document_checked: true, by: verifier!)
  def leave!(encounter, kind: "left_without_care", reason: nil)
    attrs = { "kind" => kind }
    attrs["reason"] = reason if reason
    result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: attrs, by: upa_reception!, team: nil)
    raise "leave! recusado: #{result.reason}" if result.failure?

    encounter.reload
  end

  it "classificado na UPA: o pedido nasce retido" do
    encounter = arrived!(upa, patient: patient)
    expect(Citizens::RequestErasure.urgency_recorded?([ patient.id ])).to be(false)
    classified!(encounter, color: "green", by: nurse)
    expect(Citizens::RequestErasure.urgency_recorded?([ patient.id ])).to be(true)
    expect(request!.payload[:request].status).to eq("retained")
  end

  it "classificado e depois saiu: segue retido (a evasão depois da classificação não libera)" do
    leave!(arrived!(upa, patient: patient).tap { |e| classified!(e, color: "yellow", by: nurse) })
    expect(request!.payload[:request].status).to eq("retained")
  end

  it "registro por engano com classificação: retido; sem classificação, segue a evasão" do
    leave!(arrived!(upa, patient: patient).tap { |e| classified!(e, color: "green", by: nurse) },
           kind: "registered_in_error", reason: "Chegada aberta em duplicidade")
    expect(Citizens::RequestErasure.urgency_recorded?([ patient.id ])).to be(true)

    other = urgency_patient!(urgency_seq!)
    leave!(arrived!(upa, patient: other), kind: "registered_in_error", reason: "Chegada aberta em duplicidade")
    expect(Citizens::RequestErasure.urgency_recorded?([ other.id ])).to be(false)
  end

  it "chegou e saiu antes da classificação: pendente; confirmado, o paciente fica sem nome, nascimento, sexo e CNS, e o atendimento fica" do
    encounter = leave!(arrived!(upa, patient: patient))
    attendance = encounter.attendance
    name = patient.full_name
    provisional = arrived!(upa, unidentified: "Homem de uns 60 anos, boné vermelho")

    request = request!.payload[:request]
    expect(request.status).to eq("pending")
    result = Citizens::Erase.call(request: request, by: admin)
    expect(result.payload[:request].status).to eq("confirmed")

    expect(patient.reload).to have_attributes(full_name: nil, social_name: nil, mother_name: nil, birth_date: nil, sex: nil,
                                              cns: nil, match_key: nil)
    expect(attendance.reload).to have_attributes(status: "closed", outcome: "left", patient_id: patient.id, citizen_id: nil)
    expect(encounter.reload).to have_attributes(state: "closed")
    detail = Urgency::Json.encounter(encounter, clinical: true).to_json
    expect(detail).not_to include(cpf)
    expect(detail).not_to include(name)
    rows = ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ "SELECT a.*, e.* FROM attendances a JOIN urgency_encounters e ON e.attendance_id = a.id WHERE a.id = ?",
                                       attendance.id ])
    ).to_a.to_json
    expect(rows).not_to include(cpf)

    # O provisório não tem CPF e nunca é atingido pela exclusão por CPF.
    expect(provisional.attendance.patient.reload).to have_attributes(unidentified: true,
                                                                     unidentified_description: "Homem de uns 60 anos, boné vermelho")
    expect(provisional.reload.state).to eq("waiting_classification")
  end

  # Ruling do coordenador (fix 1): o provisório identificado por paciente novo
  # (a própria linha recebe o CPF, unidentified false) guarda a descrição da
  # chegada; a exclusão confirmada a apaga junto com a identificação.
  it "provisório identificado por paciente novo e saído antes da classificação: a descrição sai na exclusão" do
    encounter = leave!(arrived!(upa, unidentified: "Senhora de uns 70 anos, cadeira de rodas"))
    new_cpf = urgency_cpf(urgency_seq!)
    identified = Urgency::Identify.call(encounter: encounter.reload, patient_id: nil,
                                        new_patient: { "full_name" => "Benedita Souza Lima", "birth_date" => "1955-03-02",
                                                       "sex" => "female", "cpf" => new_cpf },
                                        duplicates_reviewed: true, by: upa_reception!)
    expect(identified).to be_ok
    row = encounter.reload.attendance.patient
    expect(row).to have_attributes(unidentified: false, unidentified_description: be_present, cpf: new_cpf)
    Citizen.create!(cpf: new_cpf, phone: "+55419#{format('%08d', SecureRandom.random_number(10**8))}")

    request = Citizens::RequestErasure.call(cpf: new_cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("pending")
    expect(Citizens::Erase.call(request: request, by: admin).payload[:request].status).to eq("confirmed")
    expect(row.reload).to have_attributes(unidentified: false, unidentified_description: nil, full_name: nil, birth_date: nil)
    expect(encounter.reload.provisional_patient_id).to eq(row.id)
  end

  it "com o atendimento aberto na UPA: patient_in_urgency, nada muda; depois da evasão, segue" do
    encounter = arrived!(upa, patient: patient)
    request = request!.payload[:request]
    expect(request.status).to eq("pending")

    refused = Citizens::Erase.call(request: request, by: admin)
    expect(refused.reason).to eq(:patient_in_urgency)
    expect(request.reload.status).to eq("pending")
    expect(patient.reload.full_name).to be_present
    expect(citizen.reload.erased_at).to be_nil

    leave!(encounter)
    expect(Citizens::Erase.call(request: request.reload, by: admin).payload[:request].status).to eq("confirmed")
    expect(patient.reload.full_name).to be_nil
  end
end
