require "rails_helper"

# Módulo 27b, Task 9 (contrato §4; Q8, Q11, Q16): a saída externa (devolução,
# remanejamento, doação, empréstimo). Escreve movimentos external_exit, nunca o
# lote. Não exige o `bnafar`, só o estoque do domínio. Respostas sem envelope.
RSpec.describe "Farmácia — saídas externas", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:paracetamol) { catalog_item(267_778) }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "100", lot_number: "EX-A") }
  let(:reason) { "Doação de excedente à entidade filantrópica" }
  let(:cnpj) { "12ABC34501DE35" }

  def body(items = [ { lot_id: lot.id, quantity: 30 } ], **over)
    { location_id: central.id, exit_type: "S-D", destination_kind: "cnpj", destination_code: cnpj, reason: reason, items: items }.merge(over)
  end

  def written = [ StockExternalExit.count, StockExternalExitItem.count, StockMovement.count ]

  describe "POST /pharmacy/external_exits" do
    it "almoxarife registra doação a um CNPJ com step-up: 201, o saldo cai, um movimento por item, o lote não muda" do
      stepped_up!(keeper)
      lot_before = lot.reload.attributes
      expect { json_post "/pharmacy/external_exits", body }.to change(StockMovement, :count).by(1)
      expect(response).to have_http_status(:created)
      exit_row = StockExternalExit.sole
      expect(json_body).to include("id" => exit_row.id, "exit_type" => "S-D", "destination_kind" => "cnpj", "destination_code" => cnpj,
                                   "reason" => reason, "version" => 1)
      expect(json_body["items"].map { |row| [ row["lot"]["id"], row["quantity"] ] }).to eq([ [ lot.id, 30 ] ])
      expect(json_body["location"]).to include("id" => central.id, "kind" => "central")
      movement = StockMovement.find_by!(kind: "external_exit")
      expect(movement).to have_attributes(quantity: -30, stock_external_exit_id: exit_row.id, stock_lot_id: lot.id, recorded_by_user_id: keeper.id)
      expect(balance_of(central, lot)).to eq(70)
      expect(lot.reload.attributes).to eq(lot_before)
    end

    it "sem step-up → 401 mfa_required e nada gravado" do
      sign_in_as(step_up_enrolled!(keeper))
      before = written
      json_post "/pharmacy/external_exits", body
      expect(response).to have_http_status(:unauthorized)
      expect(written).to eq(before)
    end

    it "saldo insuficiente → 422 insufficient_balance com path items[0].quantity" do
      stepped_up!(keeper)
      before = written
      json_post "/pharmacy/external_exits", body([ { lot_id: lot.id, quantity: 101 } ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "insufficient_balance", "path" => "items[0].quantity")
      expect(written).to eq(before)
    end

    it "motivo de 9 caracteres → 422 com path reason; 10 passa" do
      stepped_up!(keeper)
      json_post "/pharmacy/external_exits", body(reason: "a" * 9)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      json_post "/pharmacy/external_exits", body(reason: "a" * 10)
      expect(response).to have_http_status(:created)
    end

    it "destino, tipo e itens malformados voltam juntos em problems; nada gravado" do
      stepped_up!(keeper)
      before = written
      json_post "/pharmacy/external_exits", body([ { lot_id: lot.id, quantity: 1.5 }, { lot_id: lot.id, quantity: 1 } ],
                                                  exit_type: "S-T", destination_kind: "cnes", destination_code: cnpj)
      expect(response).to have_http_status(:unprocessable_entity)
      paths = json_body["problems"].map { |row| [ row["path"], row["error"] ] }
      expect(paths).to include([ "exit_type", "invalid_request" ], [ "destination_code", "invalid_request" ],
                               [ "items[0].quantity", "invalid_quantity" ], [ "items[1].lot_id", "invalid_items" ])
      expect(written).to eq(before)
    end

    it "CNPJ com dígito verificador errado → 422 destination_code; CNES de 7 dígitos passa" do
      stepped_up!(keeper)
      json_post "/pharmacy/external_exits", body(destination_code: "12ABC34501DE36")
      expect(json_body).to include("path" => "destination_code")
      json_post "/pharmacy/external_exits", body(exit_type: "S-TR", destination_kind: "cnes", destination_code: "2384299")
      expect(response).to have_http_status(:created)
    end

    it "mais itens que o teto, ou itens que não é lista → 422 items" do
      stepped_up!(keeper)
      json_post "/pharmacy/external_exits", body("x")
      expect(json_body).to include("error" => "invalid_request", "path" => "items")
      json_post "/pharmacy/external_exits", body(Array.new(Pharmacy::Catalog::MAX_TRANSFER_ITEMS + 1) { { lot_id: lot.id, quantity: 1 } })
      expect(json_body).to include("error" => "invalid_request", "path" => "items")
    end

    it "lote de outro domínio → item_not_allowed_here em items[0]" do
      stepped_up!(keeper)
      vaccination_city!
      room_lot = vaccine_lot!(cold_chain_central!, code: "15", doses: 100)
      json_post "/pharmacy/external_exits", body([ { lot_id: room_lot.id, quantity: 10 } ])
      expect(json_body).to include("error" => "item_not_allowed_here", "path" => "items[0]")
    end

    it "lote bloqueado por excursão → 422 lot_blocked em items[0].lot_id, em todo tipo de saída; nada gravado" do
      vaccination_city!
      cold = cold_chain_central!
      vial_lot = vaccine_lot!(cold, code: "15", doses: 100)
      lot_block!(cold, vial_lot)
      stepped_up!(pharmacy_staff!(cold, "stock_keeper"))
      before = written
      %w[S-DF S-TR S-D S-E].each do |type|
        json_post "/pharmacy/external_exits", body([ { lot_id: vial_lot.id, quantity: 10 } ], location_id: cold.id, exit_type: type)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "lot_blocked", "path" => "items[0].lot_id")
      end
      expect(written).to eq(before)
    end

    it "o extrato do lote mostra a saída como documento external_exit" do
      stepped_up!(keeper)
      json_post "/pharmacy/external_exits", body
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: central.id }
      row = json_body["movements"].find { |movement| movement["kind"] == "external_exit" }
      expect(row["document"]).to eq("type" => "external_exit", "id" => StockExternalExit.sole.id, "number" => nil)
    end

    it "lote vencido: S-TR, S-D e S-E → 422 lot_expired em items[0].lot_id; S-DF (devolução ao fornecedor) aceita" do
      old = stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "EX-OLD", expires_on: Time.zone.today - 2)
      stepped_up!(keeper)
      %w[S-TR S-D S-E].each do |type|
        json_post "/pharmacy/external_exits", body([ { lot_id: old.id, quantity: 5 } ], exit_type: type)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "lot_expired", "path" => "items[0].lot_id")
      end
      json_post "/pharmacy/external_exits", body([ { lot_id: old.id, quantity: 5 } ], exit_type: "S-DF")
      expect(response).to have_http_status(:created)
      expect(balance_of(central, old)).to eq(45)
    end

    it "local desativado → 409 location_inactive" do
      stepped_up!(keeper)
      central.update_columns(active: false)
      json_post "/pharmacy/external_exits", body
      expect([ response.status, json_body["error"] ]).to eq([ 409, "location_inactive" ])
    end

    it "vacina com 15 doses num lote de 10 por frasco → invalid_quantity; 20 doses (2 frascos) passa" do
      vaccination_city!
      cold = cold_chain_central!
      vial_lot = vaccine_lot!(cold, code: "15", doses: 100)
      stepped_up!(pharmacy_staff!(cold, "stock_keeper"))
      json_post "/pharmacy/external_exits", body([ { lot_id: vial_lot.id, quantity: 15 } ], location_id: cold.id)
      expect(json_body).to include("error" => "invalid_quantity", "path" => "items[0].quantity")
      json_post "/pharmacy/external_exits", body([ { lot_id: vial_lot.id, quantity: 20 } ], location_id: cold.id)
      expect(response).to have_http_status(:created)
      expect(balance_of(cold, vial_lot)).to eq(80)
    end

    it "municipal_admin não grava (403 missing_role); o almoxarife de outro local também não" do
      stepped_up!(pharmacy_admin!)
      before = written
      json_post "/pharmacy/external_exits", body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      other = unit_location!
      stepped_up!(pharmacy_staff!(other, "stock_keeper"))
      json_post "/pharmacy/external_exits", body
      expect(response).to have_http_status(:forbidden)
      expect(written).to eq(before)
    end

    it "com o bnafar desligado funciona (nenhuma credencial, nenhum interruptor)" do
      expect(Bnafar::Gate.usable?(city)).to be(false)
      stepped_up!(keeper)
      json_post "/pharmacy/external_exits", body
      expect(response).to have_http_status(:created)
    end

    it "sem o estoque do domínio → 403 feature_disabled" do
      stepped_up!(keeper)
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      json_post "/pharmacy/external_exits", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end

    it "publica stock_external_exit.recorded só com os ids" do
      stepped_up!(keeper)
      allow(DomainEvents).to receive(:publish).and_call_original
      json_post "/pharmacy/external_exits", body
      expect(DomainEvents).to have_received(:publish).with("stock_external_exit.recorded", stock_external_exit_id: StockExternalExit.sole.id, user_id: keeper.id)
    end
  end

  describe "na base vector_control, só com o zoonoses" do
    it "funciona sem o vector_control ligado" do
      zone = zoonoses_city!
      expect([ VectorControl::Gate.usable?(zone), Stock::Domain.usable?(zone, Stock::Domain::VECTOR_CONTROL) ]).to eq([ false, true ])
      product = vector_product!
      location = vector_location!
      vlot = vector_lot!(location, product: product, quantity: "40")
      stepped_up!(vector_keeper!(location))
      json_post "/pharmacy/external_exits", body([ { lot_id: vlot.id, quantity: 15 } ], location_id: location.id, exit_type: "S-E")
      expect(response).to have_http_status(:created)
      expect(balance_of(location, vlot)).to eq(25)
    end
  end

  describe "GET /pharmacy/external_exits" do
    let!(:recorded) do
      Pharmacy::RecordExternalExit.call(location: central, attrs: body.deep_stringify_keys, by: keeper, now: Time.current).payload.fetch(:exit)
    end

    it "a lista traz as saídas do local sem o reason; o admin lê" do
      [ keeper, pharmacy_admin! ].each do |reader|
        sign_in_as(reader)
        get "/pharmacy/external_exits", params: { location_id: central.id }
        expect(response).to have_http_status(:ok)
        expect(json_body["external_exits"].map { |row| row["id"] }).to eq([ recorded.id ])
        expect(json_body["external_exits"].first).not_to have_key("reason")
        expect(json_body["external_exits"].first).to include("destination_code" => cnpj, "version" => 1)
        expect(json_body["next_before"]).to be_nil
      end
      expect(response.body).not_to include(reason)
    end

    it "o detalhe traz o reason; o de outro escopo é 404; quem não tem papel leva 403 na lista" do
      sign_in_as(keeper)
      get "/pharmacy/external_exits/#{recorded.id}"
      expect(json_body).to include("id" => recorded.id, "reason" => reason)
      sign_in_as(pharmacy_staff!(unit_location!, "stock_keeper"))
      get "/pharmacy/external_exits/#{recorded.id}"
      expect(response).to have_http_status(:not_found)
      get "/pharmacy/external_exits", params: { location_id: central.id }
      expect(response).to have_http_status(:forbidden)
    end

    it "pagina por before/limit e recusa parâmetro desconhecido" do
      Pharmacy::RecordExternalExit.call(location: central, attrs: body.deep_stringify_keys, by: keeper, now: Time.current + 1)
      sign_in_as(keeper)
      get "/pharmacy/external_exits", params: { location_id: central.id, limit: 1 }
      expect(json_body["external_exits"].size).to eq(1)
      cursor = json_body["next_before"]
      expect(cursor).to be_present
      get "/pharmacy/external_exits", params: { location_id: central.id, limit: 1, before: cursor }
      expect(json_body["external_exits"].map { |row| row["id"] }).to eq([ recorded.id ])
      get "/pharmacy/external_exits", params: { location_id: central.id, destination_code: cnpj }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "destination_code" ])
    end
  end
end
