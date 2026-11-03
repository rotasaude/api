require "rails_helper"

# ADR 0047 (módulo 29, Desvio 19): a dose de vacina é registro clínico retido,
# em qualquer situação (transcrita da caderneta e cancelada inclusive). A
# conferência de caderneta e a situação materializada não retêm.
RSpec.describe "Exclusão LGPD com dose de vacina (ADR 0047)" do
  before do
    Current.city = vaccination_city!
    # O caminho real sempre tem atendimento no par: aqui ele é desligado para isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  after { Current.reset }

  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patients::Resolve.call(citizen).payload.fetch(:patient) }
  let(:room) { vaccine_room! }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  it "sem dose nem conferência: o pedido fica pendente" do
    patient
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end

  it "dose aplicada na sala: o pedido nasce retido" do
    create_immunization!(room, patient: patient)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "dose transcrita da caderneta: retido" do
    create_immunization!(room, patient: patient, transcription: true, vaccine_room: nil, stock_lot: nil, lot_number_text: "L123")
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "dose cancelada: retido" do
    create_immunization!(room, patient: patient, cancelled_at: Time.current, cancelled_by_user: room_member!(room, role: "room_lead", cbo: "223505"),
                                cancel_reason: "Paciente errado na busca")
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "conferência de caderneta e situação materializada não retêm" do
    VaccinationStatus.create!(patient: patient, series: "penta", immunobiological_code: "42", status: "due", age_months: 3, computed_on: Time.zone.today)
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end
end
