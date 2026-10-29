require "rails_helper"

# ADR 0044 (spec decisão 11): o pedido de regulação é registro clínico retido,
# como o prontuário (ADR 0026), em qualquer situação, rascunho inclusive. O
# pedido de exclusão nasce retido e a confirmação (Citizens::Erase) reconfere
# pela mesma regra.
RSpec.describe "Exclusão LGPD com pedido de regulação (ADR 0044)" do
  before do
    regulation_city!
    # O caminho real sempre tem atendimento no par: aqui ele é desligado para
    # isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  let(:pair) { regulation_patient!(exam_seq!) }
  let(:patient) { pair.first }
  let(:citizen) { pair.last }

  # Pendente sem a finalização da consulta (que leva o pedido de exame do
  # rascunho e retém por outro caminho): o rascunho real, promovido na mão.
  def pending_regulation!
    request = regulation_request!(citizen: citizen, status: "draft")
    request.update_columns(status: "pending", requested_at: Time.current, due_on: Time.zone.today + 30)
    request
  end

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  it "pedido de quem tem pedido de regulação nasce retido" do
    pending_regulation!
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "o rascunho também retém" do
    regulation_request!(citizen: citizen, status: "draft")
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "pedido de regulação gravado depois do pedido de exclusão: a confirmação retém e nada se apaga" do
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    regulation = pending_regulation!
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(RegulationRequest.where(patient_id: patient.id, id: regulation.id)).to exist
  end

  it "sem pedido de regulação, o pedido nasce pendente" do
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end
end
