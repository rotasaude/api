require "rails_helper"

# Módulo 27a, Task 5 (ADR 0045; contrato §3 e H12; Review Focus 5): entradas
# por nota ou doação (almoxarife do local) e inventário de abertura
# (almoxarife ou farmacêutico do local). 201 com o objeto SEM envelope. Nada de
# step-up aqui: ele só existe no admin e nos ajustes.
RSpec.describe "Farmácia — entradas e inventário de abertura", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:today) { Time.zone.today }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }

  def line(item = paracetamol, **over)
    { catalog_item_id: item.id, lot_number: "LOTE-A1", expires_on: (today + 365).iso8601, manufacturer: "EMS",
      package: { units_per_package: 30, packages: 10 } }.merge(over)
  end

  def receipt(items, location: central, kind: "invoice", **document)
    { location_id: location.id, document: { kind: kind, number: "NF-1234", supplier: "Distribuidora Sul" }.merge(document), items: items }
  end

  # 422 com um problema só: o erro e o path no topo e a lista com ele.
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }

  def opening(items, location: farmacia) = { location_id: location.id, items: items }
  def written = [ StockEntry.count, StockLot.count, StockMovement.count, StockOpening.count ]

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  describe "POST /pharmacy/receipts" do
    it "201 sem envelope: id, kind, local, itens com o lote e a quantidade em duas casas, e a hora; item.unit é a concentração e item.dispensing_unit vem do lote" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line ])
      expect(response).to have_http_status(:created)
      entry = StockEntry.sole
      lot = StockLot.sole
      expect(json_body).to eq(
        "id" => entry.id, "kind" => "invoice",
        "location" => { "id" => central.id, "name" => central.name, "kind" => "central", "health_unit" => nil, "active" => true },
        "items" => [ { "lot" => { "id" => lot.id,
                                  "item" => { "catalog_item_id" => paracetamol.id, "catmat_code" => 267_778, "name" => paracetamol.label,
                                              "unit" => paracetamol.unit, "dispensing_unit" => "comprimido",
                                              "controlled" => false, "controlled_list" => nil },
                                  "lot_number" => "LOTE-A1", "expires_on" => (today + 365).iso8601, "manufacturer" => "EMS" },
                        "quantity" => "300.00" } ],
        "at" => entry.created_at.iso8601
      )
      expect(json_body).not_to have_key("entry")
      expect(json_body.dig("items", 0, "lot", "item", "unit")).to eq("mg")
      expect(StockMovement.sole).to have_attributes(kind: "receipt", quantity: 300, package_units: 30, packages: 10)
    end

    it "a LOSARTANA (sem forma farmacêutica no recorte de dev) cai em dispensing_unit \"unidade\", e item.unit segue sendo a concentração" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(losartana, lot_number: "LOS-1") ])
      expect(json_body.dig("items", 0, "lot", "item")).to include("unit" => "mg", "dispensing_unit" => "unidade", "catmat_code" => 268_856)
    end

    it "doação → kind \"donation\" e movimento donation; os itens voltam na ordem do pedido" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(lot_number: "ZZ-1", package: nil, quantity: "5"), line(lot_number: "AA-1", package: nil, quantity: "7.5") ],
                                              kind: "donation", number: "DOA-1")
      expect(response).to have_http_status(:created)
      expect(json_body["kind"]).to eq("donation")
      expect(json_body["items"].map { |i| [ i.dig("lot", "lot_number"), i["quantity"] ] }).to eq([ [ "ZZ-1", "5.00" ], [ "AA-1", "7.50" ] ])
      expect(StockMovement.pluck(:kind).uniq).to eq([ "donation" ])
    end

    it "não pede step-up: a sessão comum do almoxarife basta" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line ])
      expect(response).to have_http_status(:created)
    end

    it "Review Focus 5: \"1,5\", 1.5 (número JSON), \"0.001\", \"-2\" e \"100000\" → 422 invalid_quantity em items[0].quantity, nada gravado" do
      sign_in_as(keeper)
      [ "1,5", 1.5, "0.001", "-2", "100000" ].each do |raw|
        json_post "/pharmacy/receipts", receipt([ line(package: nil, quantity: raw) ])
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "items[0].quantity") ]), raw.inspect
      end
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "embalagem com o produto acima de 99999,99 → 422 invalid_quantity com path items[0].package" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(package: { units_per_package: 10_000, packages: 10_000 }) ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "items[0].package") ])
    end

    it "H8: dois itens inválidos → 422 com o erro do primeiro, o path e TODOS em problems" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(expires_on: (today - 1).iso8601), line(lot_number: "B-2", package: nil, quantity: "1,5") ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "expired_lot", "path" => "items[0].expires_on",
                              "problems" => [ { "path" => "items[0].expires_on", "error" => "expired_lot" },
                                              { "path" => "items[1].quantity", "error" => "invalid_quantity" } ])
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "lote existente com outra validade → 422 lot_mismatch em items[0].lot_number" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line ])
      json_post "/pharmacy/receipts", receipt([ line(expires_on: (today + 366).iso8601) ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("lot_mismatch", "items[0].lot_number") ])
    end

    it "H8: invalid_quantity numa linha e lot_mismatch contra lote existente noutra → as duas em problems, na ordem das linhas" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line ])
      before = written
      json_post "/pharmacy/receipts", receipt([ line(lot_number: "NOVO-1", package: nil, quantity: "1,5"), line(expires_on: (today + 366).iso8601) ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_quantity", "path" => "items[0].quantity",
                              "problems" => [ { "path" => "items[0].quantity", "error" => "invalid_quantity" },
                                              { "path" => "items[1].lot_number", "error" => "lot_mismatch" } ])
      expect(written).to eq(before)
    end

    it "o dia da validade ainda vale: expires_on de hoje é aceito, o de ontem não" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(expires_on: today.iso8601) ])
      expect(response).to have_http_status(:created)
      json_post "/pharmacy/receipts", receipt([ line(lot_number: "ONT", expires_on: (today - 1).iso8601) ])
      expect(json_body).to include("error" => "expired_lot")
    end

    it "document.kind fora de invoice/donation (inclusive opening) → 422 invalid_request em document.kind" do
      sign_in_as(keeper)
      [ "opening", "gift", nil ].each do |kind|
        json_post "/pharmacy/receipts", receipt([ line ], kind: kind)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "document.kind" } ]), kind.inspect
      end
      json_post "/pharmacy/receipts", { location_id: central.id, items: [ line ] }
      expect(json_body).to include("error" => "invalid_request", "path" => "document")
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "papéis: auxiliar de farmácia → 403; farmacêutica do local → 403 (nota é do almoxarife); almoxarife do central em outro local → 403; sozinhos, sem problems" do
      assistant = pharmacy_staff!(farmacia, "pharmacy_assistant")
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      [ [ assistant, farmacia ], [ pharmacist, farmacia ], [ keeper, farmacia ] ].each do |user, location|
        sign_in_as(user)
        json_post "/pharmacy/receipts", receipt([ line, line(lot_number: "!!") ], location: location)
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "membership revogada com o vínculo ativo → 403" do
      sign_in_as(keeper)
      keeper.memberships.active.find_by!(role: "stock_keeper").revoke!
      json_post "/pharmacy/receipts", receipt([ line ])
      expect(response).to have_http_status(:forbidden)
    end

    it "location_id ausente, malformado ou inexistente → 422 invalid_request em location_id; local desativado do almoxarife → 409 location_inactive" do
      sign_in_as(keeper)
      [ nil, "abc", SecureRandom.uuid ].each do |id|
        json_post "/pharmacy/receipts", receipt([ line ]).merge(location_id: id)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "location_id" } ]), id.inspect
      end
      central.update!(active: false)
      json_post "/pharmacy/receipts", receipt([ line ])
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive" } ])
    end

    it "local desativado → 409 location_inactive ANTES de validar o corpo (receipts e openings), mas depois do papel (403 sozinho)" do
      assistant = pharmacy_staff!(farmacia, "pharmacy_assistant")
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      farmacia.update!(active: false)
      sign_in_as(assistant)
      json_post "/pharmacy/openings", opening([ line(package: nil, quantity: "1,5") ])
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      sign_in_as(pharmacist)
      json_post "/pharmacy/openings", opening([ line(package: nil, quantity: "1,5") ])
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive" } ])

      central.update!(active: false)
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line(package: nil, quantity: "1,5") ], kind: "gift")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive" } ])
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "items que não é lista → 422 invalid_request em items" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt("x")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "items" } ])
    end

    it "evento stock_receipt.recorded com payload exatamente stock_entry_id e user_id" do
      sign_in_as(keeper)
      json_post "/pharmacy/receipts", receipt([ line ])
      expect(DomainEvent.where(name: "stock_receipt.recorded").sole.payload).to eq("stock_entry_id" => StockEntry.sole.id, "user_id" => keeper.id)
    end

    it "a linha \"Started POST\" do log não leva o número do lote nem o fornecedor" do
      sign_in_as(keeper)
      log = capture_log { json_post "/pharmacy/receipts", receipt([ line(lot_number: "LOTE-SIGILOSO-77") ], supplier: "Fornecedor Reservado Ltda") }
      started = log.lines.grep(/Started POST/)
      expect(started).not_to be_empty
      expect(started.join).to include("/pharmacy/receipts")
      expect(started.join).not_to match(/LOTE-SIGILOSO|Fornecedor Reservado|NF-1234/)
    end

    it "form-encoded com cookie → 415 json_required; sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      sign_in_as(keeper)
      post "/pharmacy/receipts", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])

      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      json_post "/pharmacy/receipts", receipt([ line ])
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end

    it "sem sessão → 401" do
      json_post "/pharmacy/receipts", receipt([ line ])
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /pharmacy/openings" do
    it "a farmacêutica do local abre o inventário: 201 com kind \"opening\", sem document" do
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      sign_in_as(pharmacist)
      json_post "/pharmacy/openings", opening([ line ])
      expect(response).to have_http_status(:created)
      expect(json_body).to include("id" => StockEntry.sole.id, "kind" => "opening")
      expect(json_body.dig("location", "id")).to eq(farmacia.id)
      expect(json_body.dig("items", 0)).to include("quantity" => "300.00")
      expect(StockEntry.sole).to have_attributes(kind: "opening", recorded_by_user_id: pharmacist.id, document_number: nil, supplier: nil)
      expect(StockOpening.sole).to have_attributes(stock_location_id: farmacia.id, catalog_item_id: paracetamol.id)
    end

    it "o almoxarife do local também abre" do
      other_keeper = pharmacy_staff!(farmacia, "stock_keeper")
      sign_in_as(other_keeper)
      json_post "/pharmacy/openings", opening([ line ])
      expect(response).to have_http_status(:created)
    end

    it "409 opening_exists na segunda abertura do item, também pela farmacêutica; nada novo gravado" do
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      other_keeper = pharmacy_staff!(farmacia, "stock_keeper")
      sign_in_as(other_keeper)
      json_post "/pharmacy/openings", opening([ line ])
      expect(response).to have_http_status(:created)

      before = written
      sign_in_as(pharmacist)
      json_post "/pharmacy/openings", opening([ line(lot_number: "OUTRO") ])
      expect([ response.status, json_body ]).to eq([ 409, refusal("opening_exists", "items[0].catalog_item_id") ])
      expect(written).to eq(before)
    end

    it "H8: abertura com dois itens inválidos devolve todas as recusas" do
      sign_in_as(pharmacy_staff!(farmacia, "pharmacist"))
      json_post "/pharmacy/openings", opening([ line(catalog_item_id: SecureRandom.uuid), line(losartana, lot_number: "L-2", package: nil, quantity: "0.001") ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_item", "path" => "items[0].catalog_item_id",
                              "problems" => [ { "path" => "items[0].catalog_item_id", "error" => "invalid_item" },
                                              { "path" => "items[1].quantity", "error" => "invalid_quantity" } ])
    end

    it "auxiliar de farmácia → 403; local de outro → 403; o almoxarife do central não abre a farmácia da UBS" do
      assistant = pharmacy_staff!(farmacia, "pharmacy_assistant")
      outsider = pharmacy_staff!(unit_location!, "pharmacist")
      [ assistant, outsider, keeper ].each do |user|
        sign_in_as(user)
        json_post "/pharmacy/openings", opening([ line ])
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "o almoxarife do central abre o próprio central" do
      sign_in_as(keeper)
      json_post "/pharmacy/openings", opening([ line ], location: central)
      expect(response).to have_http_status(:created)
    end

    it "Review Focus 5 também na abertura: \"1,5\" → 422 invalid_quantity com path" do
      sign_in_as(pharmacy_staff!(farmacia, "pharmacist"))
      json_post "/pharmacy/openings", opening([ line(package: nil, quantity: "1,5") ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "items[0].quantity") ])
    end

    it "evento stock_receipt.recorded também na abertura" do
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      sign_in_as(pharmacist)
      json_post "/pharmacy/openings", opening([ line ])
      expect(DomainEvent.where(name: "stock_receipt.recorded").sole.payload).to eq("stock_entry_id" => StockEntry.sole.id, "user_id" => pharmacist.id)
    end
  end
end
