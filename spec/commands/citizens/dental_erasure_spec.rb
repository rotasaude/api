require "rails_helper"

# ADR 0046: odontograma e prótese são registro clínico retido, como o
# prontuário (ADR 0026). O paciente com evento do odontograma (achado, plano,
# procedimento, periograma e endodontia nascem de uma consulta e deixam
# evento) ou com pedido de prótese conta como examinado: o pedido de exclusão
# nasce retido e a confirmação (Citizens::Erase) reconfere pela mesma regra.
RSpec.describe "Exclusão LGPD com registro odontológico (ADR 0046)" do
  before do
    Current.city = dental_city!
    # O caminho real sempre tem atendimento no par: aqui ele é desligado para
    # isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  after { Current.reset }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patients::Resolve.call(citizen).payload.fetch(:patient) }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  def prosthesis_order!(consultation)
    created = DentalCare::CreateProsthesisOrder.call(
      params: { "consultation_id" => consultation.id, "patient_id" => consultation.patient_id, "sigtap" => "0701070137",
                "laboratory" => { "name" => "Laboratório de Prótese Sorriso" } }, by: dentist
    )
    raise "pedido de prótese recusado: #{created.reason} #{created.details}" if created.failure?

    created.payload.fetch(:order)
  end

  it "paciente com evento do odontograma (consulta finalizada): o pedido nasce retido" do
    finalized_dental!(unit: unit, by: dentist, citizen: citizen)
    expect(DentalChartEvent.where(patient_id: patient.id)).to exist
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "só o registro inicial (achados) também retém" do
    consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen, baseline: true)
    saved = Consultations::SaveDraft.call(consultation: consultation, by: dentist,
                                          params: { "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" } ] } })
    raise "rascunho recusado: #{saved.reason}" if saved.failure?

    done = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: dentist)
    raise "finalização recusada: #{done.reason}" if done.failure?

    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "paciente com pedido de prótese (sem evento do odontograma): o pedido nasce retido" do
    order = prosthesis_order!(dental_consultation!(unit: unit, by: dentist, citizen: citizen))
    expect(DentalChartEvent.where(patient_id: patient.id)).not_to exist
    expect(request_for(citizen).payload[:request].status).to eq("retained")
    expect(DentalProsthesisOrder.where(id: order.id)).to exist
  end

  it "registro gravado depois do pedido de exclusão: a confirmação retém e nada se apaga" do
    patient
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: citizen)
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(DentalChartEvent.where(consultation_id: consultation.id)).to exist
    expect(DentalProcedure.where(consultation_id: consultation.id)).to exist
  end

  it "sem registro odontológico, o pedido nasce pendente" do
    patient
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end
end
