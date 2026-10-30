require "rails_helper"

# ADR 0045 (spec decisão 12): a dispensação e a receita externa são registro
# clínico retido, como o prontuário (ADR 0026). O pedido de exclusão nasce
# retido e a confirmação (Citizens::Erase) reconfere pela mesma regra. Os
# movimentos de estoque não dependem do paciente e ficam intactos.
RSpec.describe "Exclusão LGPD com dispensação da farmácia (ADR 0045)" do
  before do
    pharmacy_city!
    # O caminho real sempre tem atendimento no par: aqui ele é desligado para
    # isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  let(:pair) { exam_patient!(exam_seq!) }
  let(:patient) { pair.first }
  let(:citizen) { pair.last }
  let!(:farmacia) { unit_location! }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:settings) { Pharmacy::Settings.current }
  let(:today) { Time.zone.today }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  def external_prescription!
    result = Pharmacy::RecordExternalPrescription.call(
      location: farmacia, patient_id: patient.id, new_patient: nil, notification_number: nil, by: pharmacist, role: "pharmacist",
      prescriber: { "name" => "Dra. Beltrana Souza", "council" => "CRM", "council_state" => "PR", "council_number" => "54321" },
      issued_on: today.iso8601, catalog: { losartana.id => losartana }, today: today, settings: settings,
      items: [ { "catalog_item_id" => losartana.id, "quantity" => "30", "quantity_unit" => "comprimido", "dosage_instructions" => "1 ao dia",
                 "continuous" => false } ]
    )
    raise "receita externa recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:external_prescription)
  end

  def dispense!(record, lot)
    prescription = Pharmacy::Prescription.find(kind: "external", id: record.id, settings: settings)
    result = Pharmacy::Dispense.call(
      location: farmacia, prescription: prescription, retention: nil, by: pharmacist, role: "pharmacist", settings: settings,
      catalog: { losartana.id => losartana },
      items: [ { "prescription_item_id" => record.items.sole.id,"lot_id" => lot.id, "quantity" => "30" } ]
    )
    raise "dispensação recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:dispensation)
  end

  def movements = StockMovement.order(:id).pluck(:id, :kind, :quantity, :stock_lot_id)

  it "pedido de quem só tem uma receita externa dispensada nasce retido; os movimentos de estoque ficam" do
    lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
    dispense!(external_prescription!, lot)
    before_movements = movements
    expect(before_movements.map(&:second)).to include("dispensing")

    expect(request_for(citizen).payload[:request].status).to eq("retained")
    expect(movements).to eq(before_movements)
  end

  it "a receita externa sem dispensação também retém" do
    external_prescription!
    expect(Dispensation.exists?(patient_id: patient.id)).to be(false)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "dispensed? confere os ids do paciente e não acusa quem não tem nada" do
    lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
    dispense!(external_prescription!, lot)
    expect(Citizens::RequestErasure.dispensed?([ patient.id ])).to be(true)
    expect(Citizens::RequestErasure.dispensed?([ SecureRandom.uuid ])).to be(false)
  end

  it "dispensação gravada depois do pedido de exclusão: a confirmação retém e nada se apaga" do
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
    record = external_prescription!
    dispense!(record, lot)
    before_movements = movements

    result = Citizens::Erase.call(request: request, by: care_admin!)

    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(Dispensation.where(patient_id: patient.id).count).to eq(1)
    expect(ExternalPrescription.where(id: record.id)).to exist
    expect(movements).to eq(before_movements)
  end

  it "sem dispensação nem receita externa, o pedido nasce pendente e a confirmação apaga normalmente" do
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("confirmed")
    expect(citizen.reload.erased_at).to be_present
  end

  it "nenhum dado pessoal vai no evento da exclusão retida" do
    external_prescription!
    request = request_for(citizen).payload[:request]
    event = DomainEvent.where(name: "citizen.erasure_retained").order(:created_at).last
    expect(event.payload).to eq("request_id" => request.id)
  end
end
