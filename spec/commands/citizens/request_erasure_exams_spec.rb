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

  it "o paciente do CPF conta mesmo sem par ligado a ele (par antigo já excluído)" do
    patient, old_pair = exam_patient!(exam_seq!)
    exam_order!(patient: patient, unit: unit, requester: doctor!(unit))
    old_pair.update_columns(erased_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- simula o par já excluído
    Citizen.create!(cpf: old_pair.cpf, phone: "+5541990000#{format('%03d', exam_seq! % 1000)}")
    result = described_class.call(cpf: old_pair.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("retained")
  end

  it "Erase trava o paciente antes de reconferir (segura a FK de um exame novo)" do
    _patient, citizen = exam_patient!(exam_seq!)
    request = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception).payload[:request]
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    sqls = []
    callback = ->(*, payload) { sqls << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Citizens::Erase.call(request: request, by: admin) }
    locked = sqls.find { |sql| sql.include?('FROM "patients"') && sql.include?("FOR UPDATE") }
    expect(locked).to be_present
    retention = sqls.index { |sql| sql.include?('FROM "exam_orders"') }
    expect(sqls.index(locked)).to be < retention
    expect(request.reload.status).to eq("confirmed")
  end

  it "Erase com atendimento retém sem travar o paciente (sem impasse com documento e consulta)" do
    _patient, citizen = exam_patient!(exam_seq!)
    request = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception).payload[:request]
    allow(described_class).to receive(:attended?).and_return(true) # atendimento chegou depois do pedido
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    sqls = []
    callback = ->(*, payload) { sqls << payload[:sql] }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Citizens::Erase.call(request: request, by: admin) }
    expect(result.payload[:request].status).to eq("retained")
    expect(sqls.none? { |sql| sql.include?('FROM "patients"') && sql.include?("FOR UPDATE") }).to be(true)
  end

  it "par sem exame segue pendente" do
    _patient, citizen = exam_patient!(exam_seq!)
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("pending")
  end
end
