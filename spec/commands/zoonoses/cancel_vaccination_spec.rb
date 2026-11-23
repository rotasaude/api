require "rails_helper"

# Módulo 35b, Task 7 (ADR 0054; contrato §1, §3): a anulação da dose, uma vez,
# por quem registrou ou pela coordenação, com o motivo 10–500 (cifrado). Trava a
# dose FOR UPDATE antes do estorno (Zoonoses::ApplyStock.reverse!: o
# animal_vaccination_reversal no mesmo lote, ou a falta conciliada pelo
# sistema). rabies_vaccination.cancelled só com o id.
RSpec.describe Zoonoses::CancelVaccination, type: :model do
  let!(:city) { zoonoses_city! }
  let(:recorder) { zoonoses_team! }
  let(:vaccine) { zoonoses_product! }
  let(:location) { vector_location! }
  let(:reason) { "Dose lançada no animal errado" }
  let(:campaign) do
    RabiesCampaign.create!(name: "Campanha #{SecureRandom.hex(3)}", year: Time.zone.today.year, starts_on: Time.zone.today - 5,
                           ends_on: Time.zone.today + 30, goal_dogs: 10, goal_cats: 5, stage: "open")
  end

  def dose!
    result = Zoonoses::RecordVaccination.call(params: { "modality" => "fixed_post", "campaign_id" => campaign.id, "species" => "dog",
                                                        "vaccinated_on" => Time.zone.today.iso8601, "vector_product_id" => vaccine.id,
                                                        "adverse_event" => false },
                                              by: recorder, origin: "dashboard")
    raise "dose!: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:vaccination)
  end

  def cancel(dose, by:, reason: self.reason) = described_class.call(vaccination: dose, reason: reason, by: by)
  def refusal(result) = [ result.reason, result.details ]
  def balance(lot) = Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)

  it "outro usuário da equipe → missing_role; coordenação → ok com estorno" do
    vector_stock_location!(location)
    lot = vector_lot!(location, product: vaccine, quantity: "3")
    dose = dose!
    expect(balance(lot)).to eq(2)

    expect(refusal(cancel(dose, by: zoonoses_team!))).to eq([ :missing_role, {} ])
    expect(dose.reload.cancelled_at).to be_nil

    coordinator = zoonoses_coordinator!
    result = cancel(dose, by: coordinator)
    expect(result).to be_ok
    expect(result.payload.fetch(:vaccination).reload).to have_attributes(cancel_reason: reason, cancelled_at: be_present)
    reversal = StockMovement.where(rabies_vaccination_id: dose.id, kind: "animal_vaccination_reversal").sole
    expect(reversal).to have_attributes(quantity: BigDecimal("1"), stock_lot_id: lot.id, recorded_by_user_id: coordinator.id)
    expect(balance(lot)).to eq(3)
    expect(DomainEvent.where(name: "rabies_vaccination.cancelled").sole.payload).to eq("rabies_vaccination_id" => dose.id)
  end

  it "quem registrou anula; a falta aberta da dose é conciliada, sem movimento" do
    dose = dose!
    expect(VectorStockShortfall.find_by!(rabies_vaccination_id: dose.id).reconciled_at).to be_nil
    expect(cancel(dose, by: recorder)).to be_ok
    expect(VectorStockShortfall.find_by!(rabies_vaccination_id: dose.id).reconciled_at).to be_present
    expect(StockMovement.where(rabies_vaccination_id: dose.id)).to be_empty
  end

  it "segunda anulação → invalid_transition path status, sem segundo estorno" do
    vector_stock_location!(location)
    vector_lot!(location, product: vaccine, quantity: "3")
    dose = dose!
    expect(cancel(dose, by: recorder)).to be_ok
    expect(refusal(cancel(dose, by: recorder))).to eq([ :invalid_transition, { path: "status" } ])
    # Objeto lido antes da primeira anulação: a trava relê a linha.
    stale = RabiesVaccination.find(dose.id).tap { _1.cancelled_at = nil }
    expect(refusal(cancel(stale, by: recorder))).to eq([ :invalid_transition, { path: "status" } ])
    expect(StockMovement.where(rabies_vaccination_id: dose.id, kind: "animal_vaccination_reversal").count).to eq(1)
    expect(DomainEvent.where(name: "rabies_vaccination.cancelled").count).to eq(1)
  end

  it "motivo fora de 10–500 ou não texto → invalid_request path reason (recusado, nunca cortado)" do
    dose = dose!
    [ "curto", "a" * 501, nil, 123 ].each do |bad|
      expect(refusal(cancel(dose, by: recorder, reason: bad))).to eq([ :invalid_request, { path: "reason" } ])
    end
    expect(cancel(dose, by: recorder, reason: "  #{reason}  ").payload.fetch(:vaccination).reload.cancel_reason).to eq(reason)
  end
end
