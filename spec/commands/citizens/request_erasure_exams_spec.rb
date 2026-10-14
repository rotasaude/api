require "rails_helper"

# ADR 0026 + ADR 0036 (decisão do usuário, 2026-10-14): o exame — pedido,
# resultado e laudo — é registro clínico; a pessoa com exame tem a exclusão
# retida, como a de atendimento ou documento clínico.
RSpec.describe Citizens::RequestErasure do
  before { exam_city! }

  let(:unit) { create_unit("UBS Exclusão") }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }

  before { allow(described_class).to receive_messages(attended?: false, documented?: false) } # isola a regra nova

  it "par com pedido de exame nasce retido" do
    patient, citizen = exam_patient!(exam_seq!)
    exam_order!(patient: patient, unit: unit, requester: doctor!(unit))
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("retained")
  end

  it "par só com resultado externo nasce retido" do
    patient, citizen = exam_patient!(exam_seq!)
    recorded = Exams::RecordExternalResult.call(patient: patient, sigtap_code: "0202020380", released_on: Time.zone.today.iso8601,
                                                laboratory_name: "Lab", file_id: pdf_file!(user: reception).id, values: [], by: reception)
    expect(recorded).to be_ok
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("retained")
  end

  it "par com exame cancelado também nasce retido (o pedido continua registro clínico)" do
    patient, citizen = exam_patient!(exam_seq!)
    order = exam_order!(patient: patient, unit: unit, requester: doctor!(unit))
    cancelled = Exams::Transition.call(order: order.reload, kind: "cancelled", actor_user: reception, reason: "Paciente desistiu")
    expect(order.reload.status).to eq("cancelled"), cancelled.inspect
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("retained")
  end

  it "Erase reconfere: exame que chega depois do pedido retém na confirmação" do
    patient, citizen = exam_patient!(exam_seq!)
    request = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception).payload[:request]
    expect(request.status).to eq("pending")
    exam_order!(patient: patient, unit: unit, requester: doctor!(unit))
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    result = Citizens::Erase.call(request: request, by: admin)
    expect(result.payload[:request]).to have_attributes(status: "retained", decided_by_user_id: admin.id)
    expect(citizen.reload.cpf).to be_present
  end

  it "par sem exame segue pendente" do
    _patient, citizen = exam_patient!(exam_seq!)
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("pending")
  end
end
