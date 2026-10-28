require "rails_helper"

# ADR 0043 (obrigação legal): quem tem notificação de doença compulsória, de
# qualquer origem e situação (descartada inclusive), é registro retido; o
# pedido nasce retido e a confirmação (Citizens::Erase) reconfere pela mesma regra.
RSpec.describe "Exclusão LGPD com notificação de vigilância (ADR 0043)" do
  before { surveillance_city! }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  it "pedido de quem tem notificação manual nasce retido" do
    patient, citizen = exam_patient!(31, age: 40, sex: "female")
    notification!(patient: patient, origin: "manual")
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "pedido de quem tem notificação da rede de segurança descartada nasce retido" do
    patient, citizen = exam_patient!(32, age: 40, sex: "female")
    notification = notification!(patient: patient, origin: "safety_net")
    result = Surveillance::Dismiss.call(notification: notification, reason: "Não é caso",
                                        version: notification.version, by: surveillance_officer!)
    expect(result.ok?).to be(true)
    expect(notification.reload.status).to eq("dismissed")
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "notificação gravada depois do pedido: a confirmação retém e nada se apaga" do
    patient, citizen = exam_patient!(33, age: 40, sex: "female")
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    notification!(patient: patient, origin: "manual")
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(DiseaseNotification.where(patient_id: patient.id)).to exist
  end

  it "sem notificação, o pedido nasce pendente" do
    _patient, citizen = exam_patient!(34, age: 40, sex: "female")
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end
end
