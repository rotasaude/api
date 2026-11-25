require "rails_helper"

# Módulo 27b, Task 13 (contrato Q13, Q19): GET /pharmacy/openings. Exige só o
# estoque do domínio (nunca o `bnafar`); lê quem tem papel no local ou o
# almoxarife do central. A marca `from_import` entra na Task 14.
RSpec.describe "Farmácia — aberturas de estoque", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:paracetamol) { catalog_item(267_778) }

  def get_openings(params = {})
    get "/pharmacy/openings", params: params
  end

  it "lista a abertura com o lote, quem registrou e o que falta para o envio" do
    lot = stocked_lot!(central, item: paracetamol, quantity: "30", lot_number: "ABC123", by: keeper)
    sign_in_as(keeper)
    get_openings(location_id: central.id)

    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    row = json_body["items"].sole
    expect(row).to include("stock_entry_id" => StockMovement.find_by!(stock_lot_id: lot.id, kind: "opening").stock_entry_id,
                           "recorded_by" => { "name" => "—" }, "from_import" => false, "reverted" => false)
    expect(row["created_at"]).to be_present
    expect(row["lots"].sole).to eq("stock_lot_id" => lot.id, "item_label" => paracetamol.label, "lot_number" => "ABC123",
                                   "expires_on" => lot.expires_on.iso8601, "quantity" => "30.00",
                                   "bnafar" => { "missing" => %w[unit_price_cents manufacturer_cnpj anvisa_registration health_program] })
  end

  it "abertura revertida sai com reverted: true" do
    stocked_lot!(central, item: paracetamol, by: keeper)
    StockOpening.update_all(reverted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    sign_in_as(keeper)
    get_openings(location_id: central.id)
    expect(json_body["items"].sole["reverted"]).to be(true)
  end

  it "sem papel no local → 403; sem location_id → 422" do
    stocked_lot!(central, item: paracetamol, by: keeper)
    outsider = pharmacy_staff!(farmacia, "stock_keeper")
    sign_in_as(outsider)
    get_openings(location_id: central.id)
    expect(response).to have_http_status(:forbidden)
    get_openings
    expect([ response.status, json_body["path"] ]).to eq([ 422, "location_id" ])
  end

  it "o almoxarife do central lê a abertura de qualquer local de medicamento" do
    stocked_lot!(farmacia, item: paracetamol, by: keeper)
    sign_in_as(keeper)
    get_openings(location_id: farmacia.id)
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].size).to eq(1)
  end

  it "pagina por before/limit, a mais nova primeiro" do
    stocked_lot!(central, item: paracetamol, by: keeper)
    stocked_lot!(central, item: losartana, by: keeper)
    sign_in_as(keeper)
    get_openings(location_id: central.id, limit: 1)
    first_page = json_body
    expect(first_page["items"].size).to eq(1)
    expect(first_page["next_before"]).to be_present

    get_openings(location_id: central.id, limit: 1, before: first_page["next_before"])
    expect(json_body["items"].size).to eq(1)
    expect(json_body["items"].first["stock_entry_id"]).not_to eq(first_page["items"].first["stock_entry_id"])
    expect(json_body["next_before"]).to be_nil

    get_openings(location_id: central.id, before: "lixo")
    expect([ response.status, json_body["path"] ]).to eq([ 422, "before" ])
  end

  it "funciona com o bnafar desligado" do
    expect(::Bnafar::Gate.usable?(city)).to be(false)
    stocked_lot!(central, item: paracetamol, by: keeper)
    sign_in_as(keeper)
    get_openings(location_id: central.id)
    expect(response).to have_http_status(:ok)
  end
end
