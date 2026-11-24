require "rails_helper"

# Módulo 35b, Task 14 (ADR 0054; contrato §6, §3, Q20, Q23): a coleira de
# deltametrina. due_on = placed_on + collar_months; a segunda coleira troca a
# anterior (replaced) na mesma transação; só cão ativo; a baixa do estoque
# nunca recusa (falta gravada); eventos só com o id. Pelo app: gate de campo e
# agente no escopo do domicílio do animal.
RSpec.describe Zoonoses::PlaceCollar, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:product) { zoonoses_product!(use: "collar") }
  let(:location) { vector_location! }

  def stock!(quantity: "10")
    vector_stock_location!(location)
    vector_lot!(location, product: product, quantity: quantity)
  end

  def place(animal, by: team, origin: "dashboard", zoonoses_field: true, **over)
    params = { "animal_id" => animal.id, "vector_product_id" => product.id, "placed_on" => today.iso8601 }
             .merge(over.transform_keys(&:to_s)).reject { |_, value| value == :omit }
    described_class.call(params: params, by: by, origin: origin, zoonoses_field: zoonoses_field)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "colocada em 2026-05-31 com 6 meses → due 2026-11-30; baixa 1 un; evento só com collar_id" do
    stock!
    animal = animal!
    result = described_class.call(params: { "animal_id" => animal.id, "vector_product_id" => product.id, "placed_on" => "2026-05-31" },
                                  by: team, today: Date.new(2026, 6, 1))
    expect(result).to be_ok
    collar = result.payload.fetch(:collar)
    expect(collar).to have_attributes(animal_id: animal.id, placed_on: Date.new(2026, 5, 31), due_on: Date.new(2026, 11, 30), removed_on: nil)
    expect(StockMovement.where(collar_id: collar.id, kind: "collar_placement").count).to eq(1)
    expect(DomainEvent.where(name: "collar.placed").sole.payload).to eq("collar_id" => collar.id)
  end

  it "segunda coleira → a anterior replaced em placed_on e uma só ativa" do
    stock!
    animal = animal!
    first = place(animal, placed_on: (today - 30).iso8601).payload.fetch(:collar)
    second = place(animal).payload.fetch(:collar)
    expect(first.reload).to have_attributes(removed_on: today, removal_reason: "replaced")
    expect(Collar.active.where(animal_id: animal.id).pluck(:id)).to eq([ second.id ])
    expect(DomainEvent.where(name: "collar.removed").sole.payload).to eq("collar_id" => first.id)
    expect(StockMovement.where(kind: "collar_placement").count).to eq(2)
  end

  it "gato → animal_not_dog; inativo → animal_not_active; sem permissão → missing_role" do
    expect(refusal(place(animal!(species: "cat")))).to eq([ :animal_not_dog, {} ])
    expect(refusal(place(animal!(status: "missing")))).to eq([ :animal_not_active, {} ])
    expect(refusal(place(animal!, by: endemic_agent!))).to eq([ :missing_role, {} ])
    expect(Collar.count).to eq(0)
  end

  it "sem saldo → coleira gravada e falta com a data da colocação" do
    animal = animal!
    result = place(animal, placed_on: (today - 2).iso8601)
    expect(result).to be_ok
    collar = result.payload.fetch(:collar)
    expect(StockMovement.where(collar_id: collar.id).count).to eq(0)
    shortfall = VectorStockShortfall.sole
    expect(shortfall).to have_attributes(collar_id: collar.id, source: "collar", occurred_on: today - 2)
  end

  it "recusas de campo" do
    animal = animal!
    expect(refusal(place(animal, placed_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "placed_on" } ])
    expect(refusal(place(animal, placed_on: "31/05/2026"))).to eq([ :invalid_request, { path: "placed_on" } ])
    expect(refusal(place(animal, vector_product_id: zoonoses_product!.id))).to eq([ :invalid_request, { path: "vector_product_id" } ])
    expect(refusal(place(animal, vector_product_id: "x"))).to eq([ :invalid_request, { path: "vector_product_id" } ])
    expect(refusal(place(animal!.tap { |a| a.id }, animal_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(place(animal, note: "x"))).to eq([ :invalid_request, { path: "note" } ])
    expect(refusal(place(animal, client_uuid: SecureRandom.uuid))).to eq([ :invalid_request, { path: "client_uuid" } ])
    expect(Collar.count).to eq(0)
  end

  it "pelo app: gate de campo, agente no escopo do domicílio e client_uuid" do
    stock!
    household = registry_household!
    animal = animal!(household: household)
    uuid = SecureRandom.uuid
    expect(refusal(place(animal, by: registry_acs_of(household), origin: "field", zoonoses_field: false))).to eq([ :feature_disabled, {} ])
    expect(refusal(place(animal, by: endemic_agent!, origin: "field"))).to eq([ :out_of_scope, {} ])
    expect(refusal(place(animal!, by: registry_acs_of(household), origin: "field"))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(place(animal, by: team, origin: "field"))).to eq([ :out_of_scope, {} ])

    result = place(animal, by: registry_acs_of(household), origin: "field", client_uuid: uuid)
    expect(result).to be_ok
    expect(result.payload.fetch(:collar)).to have_attributes(client_uuid: uuid, animal_id: animal.id)
  end
end
