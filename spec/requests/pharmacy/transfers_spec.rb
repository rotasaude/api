require "rails_helper"

# Módulo 27a, Task 6 (ADR 0045; contrato §5 e H2/H5/H8/H12): transferência do
# central para a unidade. Respostas SEM envelope, na forma <transfer>; 422 com
# `problems` em todas as recusas (envio e recebimento); 403 de papel sozinho;
# recurso da URL fora do escopo → 404.
RSpec.describe "Farmácia — transferências", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "120", lot_number: "TR-A") }
  let(:reason) { "Duas caixas chegaram molhadas e foram descartadas" }
  let(:today) { Time.zone.today }

  def line(lot_record = lot, quantity = "100") = { lot_id: lot_record.id, quantity: quantity }
  def send_body(items = [ line ], to: farmacia) = { to_location_id: to.id, items: items }
  def got(lot_record = lot, quantity = "100", **extra) = { lot_id: lot_record.id, quantity_received: quantity }.merge(extra)
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def written = [ StockTransfer.count, StockTransferItem.count, StockMovement.count ]
  def disable_pharmacy! = Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)

  def sent_transfer!(*lines)
    result = Pharmacy::SendTransfer.call(from: central, to: farmacia, items: lines.map { |l, q| { "lot_id" => l.id, "quantity" => q } },
                                         by: pharmacy_staff!(central, "stock_keeper"), now: Time.current)
    result.payload.fetch(:transfer)
  end

  def lot_json(lot_record)
    { "id" => lot_record.id,
      "item" => { "catalog_item_id" => paracetamol.id, "catmat_code" => 267_778, "name" => paracetamol.label, "unit" => paracetamol.unit,
                  "dispensing_unit" => "comprimido", "controlled" => false, "controlled_list" => nil },
      "lot_number" => lot_record.lot_number, "expires_on" => lot_record.expires_on.iso8601, "manufacturer" => lot_record.manufacturer }
  end

  def location_json(location, unit_record = nil)
    { "id" => location.id, "name" => location.name, "kind" => location.kind, "active" => true,
      "health_unit" => unit_record && { "id" => unit_record.id, "name" => unit_record.name } }
  end

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  describe "POST /pharmacy/transfers" do
    it "o almoxarife do central envia: 201 sem envelope, na forma <transfer>, e o saldo do central cai" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body
      expect(response).to have_http_status(:created)
      transfer = StockTransfer.sole
      expect(json_body).to eq(
        "id" => transfer.id, "from" => location_json(central), "to" => location_json(farmacia, unit), "status" => "sent",
        "sent_at" => transfer.sent_at.iso8601, "received_at" => nil,
        "items" => [ { "lot" => lot_json(lot), "quantity_sent" => "100.00", "quantity_received" => nil, "difference" => nil } ]
      )
      expect(json_body).not_to have_key("transfer")
      expect(Pharmacy::Ledger.balance(location_id: central.id, lot_id: lot.id)).to eq(20)
    end

    it "almoxarife da UBS (não do central) envia → 403 missing_role, sozinho, mesmo com o corpo inválido; nada gravado" do
      sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
      before = written
      json_post "/pharmacy/transfers", { to_location_id: "lixo", items: "x" }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_post "/pharmacy/transfers", send_body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(written).to eq(before)
    end

    it "farmacêutico da UBS, auxiliar da UBS e usuário sem papel → 403" do
      [ pharmacy_staff!(farmacia, "pharmacist"), assistant, staff_with("sem-papel@cidade.gov.br") ].each do |user|
        sign_in_as(user)
        json_post "/pharmacy/transfers", send_body
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
    end

    it "Review Focus 4: Membership do almoxarife revogada com o vínculo ativo → 403" do
      sign_in_as(keeper)
      keeper.memberships.find_by!(role: "stock_keeper").revoke!
      json_post "/pharmacy/transfers", send_body
      expect(response).to have_http_status(:forbidden)
    end

    it "to_location_id inexistente, ausente ou que não é uuid → 422 invalid_request com o path e problems (nunca 404)" do
      sign_in_as(keeper)
      [ SecureRandom.uuid, nil, "lixo", 12 ].each do |bad|
        json_post "/pharmacy/transfers", { to_location_id: bad, items: [ line ] }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "to_location_id") ])
      end
    end

    it "to_location_id inválido junto de itens inválidos: as duas recusas voltam juntas, na ordem destino, linhas" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", { to_location_id: SecureRandom.uuid, items: [ line(lot, "1,5"), { lot_id: SecureRandom.uuid, quantity: "1" } ] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request", "path" => "to_location_id",
                              "problems" => [ { "path" => "to_location_id", "error" => "invalid_request" },
                                              { "path" => "items[0].quantity", "error" => "invalid_quantity" },
                                              { "path" => "items[1].lot_id", "error" => "invalid_items" } ])
      json_post "/pharmacy/transfers", { to_location_id: nil, items: "x" }
      expect(json_body["problems"]).to eq([ { "path" => "to_location_id", "error" => "invalid_request" }, { "path" => "items", "error" => "invalid_request" } ])
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "lote vencido → 422 lot_expired em items[i].lot_id, junto das outras; o dia da validade ainda vale" do
      expired = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-VENC", expires_on: today - 1)
      lastday = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-HOJE", expires_on: today)
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body([ line(expired, "5"), line(lot, "1,5") ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "lot_expired", "path" => "items[0].lot_id",
                                                            "problems" => [ { "path" => "items[0].lot_id", "error" => "lot_expired" },
                                                                            { "path" => "items[1].quantity", "error" => "invalid_quantity" } ] } ])
      json_post "/pharmacy/transfers", send_body([ line(lastday, "5") ])
      expect(response).to have_http_status(:created)
    end

    it "central inativo → 409 location_inactive com path from" do
      central.update_columns(active: false)
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive", "path" => "from" } ])
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "destino que é o central → 422 com problems; destino inativo → 409 location_inactive com o path" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body(to: central)
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "to_location_id") ])
      farmacia.update_columns(active: false)
      json_post "/pharmacy/transfers", send_body
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive", "path" => "to_location_id" } ])
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "DOIS itens inválidos: 422 com error/path do primeiro e problems com os dois" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body([ line(lot, "1,5"), { lot_id: SecureRandom.uuid, quantity: "1" } ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_quantity", "path" => "items[0].quantity",
                              "problems" => [ { "path" => "items[0].quantity", "error" => "invalid_quantity" },
                                              { "path" => "items[1].lot_id", "error" => "invalid_items" } ])
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "DOIS itens sem saldo (apurado sob trava): 422 com os dois problems, nada gravado" do
      other = stocked_lot!(central, item: paracetamol, quantity: "5", lot_number: "TR-B")
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body([ line(lot, "121"), line(other, "6") ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "insufficient_balance", "path" => "items[0].quantity",
                                                            "problems" => [ { "path" => "items[0].quantity", "error" => "insufficient_balance" },
                                                                            { "path" => "items[1].quantity", "error" => "insufficient_balance" } ] } ])
      expect(written).to eq([ 0, 0, 2 ])
    end

    it "lista vazia ou grande demais → 422 invalid_request path items, sem problems" do
      sign_in_as(keeper)
      [ [], Array.new(101) { line } ].each do |bad|
        json_post "/pharmacy/transfers", send_body(bad)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "items") ])
      end
    end

    it "evento stock_transfer.sent com payload exatamente stock_transfer_id e user_id" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", send_body
      expect(DomainEvent.where(name: "stock_transfer.sent").sole.payload).to eq("stock_transfer_id" => StockTransfer.sole.id, "user_id" => keeper.id)
    end

    it "form-encoded com cookie → 415; sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      post "/pharmacy/transfers", params: { to_location_id: farmacia.id }
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(keeper)
      post "/pharmacy/transfers", params: { to_location_id: farmacia.id }
      expect(response).to have_http_status(:unsupported_media_type)
      disable_pharmacy!
      json_post "/pharmacy/transfers", send_body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end

    it "o log não leva o motivo nem os lotes" do
      sign_in_as(keeper)
      log = capture_log { json_post "/pharmacy/transfers", send_body }
      expect(log.lines.grep(/Parameters/).join).not_to include(lot.id)
    end
  end

  describe "POST /pharmacy/transfers/:id/receive" do
    let!(:transfer) { sent_transfer!([ lot, "100" ]) }

    it "o auxiliar do destino recebe: 200 sem envelope, status received, difference \"0.00\"" do
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => transfer.id, "status" => "received", "received_at" => StockTransfer.find(transfer.id).received_at.iso8601)
      expect(json_body["items"]).to eq([ { "lot" => lot_json(lot), "quantity_sent" => "100.00", "quantity_received" => "100.00", "difference" => "0.00", "reason" => nil } ])
      expect(json_body).not_to have_key("transfer")
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(100)
    end

    it "com diferença e motivo: received_with_difference, difference \"5.00\", motivo devolvido a quem recebeu; extrato do destino [in 100, loss -5]" do
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got(lot, "95", reason: reason) ] }
      expect(response).to have_http_status(:ok)
      expect(json_body["status"]).to eq("received_with_difference")
      expect(json_body["items"].sole).to include("quantity_received" => "95.00", "difference" => "5.00", "reason" => reason)
      expect(StockMovement.where(stock_location_id: farmacia.id).order(quantity: :desc).pluck(:kind, :quantity)).to eq([ [ "transfer_in", 100 ], [ "loss", -5 ] ])
    end

    it "o farmacêutico e o almoxarife do destino também recebem" do
      sign_in_as(pharmacy_staff!(farmacia, "pharmacist"))
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect(response).to have_http_status(:ok)
      other = sent_transfer!([ lot, "10" ])
      sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
      json_post "/pharmacy/transfers/#{other.id}/receive", { items: [ got(lot, "10") ] }
      expect(response).to have_http_status(:ok)
    end

    it "auxiliar de outra UBS → 404 (a transferência é de outro escopo); id desconhecido ou lixo → 404; sem papel nenhum → 404" do
      sign_in_as(pharmacy_staff!(unit_location!, "pharmacy_assistant"))
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      [ SecureRandom.uuid, "lixo" ].each do |id|
        json_post "/pharmacy/transfers/#{id}/receive", { items: [ got ] }
        expect(response).to have_http_status(:not_found)
      end
      sign_in_as(staff_with("sem-papel@cidade.gov.br"))
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect(response).to have_http_status(:not_found)
      expect(StockTransfer.find(transfer.id).status).to eq("sent")
    end

    it "quem só tem papel na ORIGEM (o almoxarife do central) → 403 missing_role, sozinho, mesmo com o corpo inválido" do
      sign_in_as(keeper)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: "x" }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(StockTransfer.find(transfer.id).status).to eq("sent")
    end

    it "DOIS itens inválidos no recebimento: 422 com os dois problems (motivo faltando e quantidade a mais)" do
      other = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-B")
      two = sent_transfer!([ lot, "10" ], [ other, "10" ])
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{two.id}/receive", { items: [ got(lot, "5"), got(other, "11") ] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "reason_required", "path" => "items[0].reason",
                              "problems" => [ { "path" => "items[0].reason", "error" => "reason_required" },
                                              { "path" => "items[1].quantity_received", "error" => "invalid_quantity" } ])
      expect(StockTransfer.find(two.id).status).to eq("sent")
    end

    it "faltando um lote → 422 invalid_items com path items" do
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [] }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "items") ])
      other = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-B")
      two = sent_transfer!([ lot, "10" ], [ other, "10" ])
      json_post "/pharmacy/transfers/#{two.id}/receive", { items: [ got(lot, "10") ] }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_items", "items") ])
    end

    it "receber de novo → 409 already_received, nada gravado a mais" do
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      before = written
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_received" } ])
      expect(written).to eq(before)
    end

    it "eventos: stock_transfer.received só com os ids e o booleano" do
      sign_in_as(assistant)
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got(lot, "95", reason: reason) ] }
      payload = DomainEvent.where(name: "stock_transfer.received").sole.payload
      expect(payload).to eq("stock_transfer_id" => transfer.id, "user_id" => assistant.id, "with_difference" => true)
      expect(payload.to_json).not_to include(reason)
    end

    it "o log não leva o motivo da diferença" do
      sign_in_as(assistant)
      log = capture_log { json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got(lot, "95", reason: reason) ] } }
      expect(log).not_to include(reason)
    end

    it "interruptor desligado → 403 feature_disabled" do
      sign_in_as(assistant)
      disable_pharmacy!
      json_post "/pharmacy/transfers/#{transfer.id}/receive", { items: [ got ] }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end
  end

  describe "GET /pharmacy/transfers/:id" do
    let!(:transfer) { sent_transfer!([ lot, "100" ]) }

    before do
      Pharmacy::ReceiveTransfer.call(transfer: transfer, items: [ { "lot_id" => lot.id, "quantity_received" => "95", "reason" => reason } ],
                                     by: assistant, now: Time.current)
    end

    it "quem pode receber no destino vê o detalhe com o motivo; o motivo só vem para ele" do
      sign_in_as(assistant)
      get "/pharmacy/transfers/#{transfer.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["status"]).to eq("received_with_difference")
      expect(json_body["items"].sole).to include("quantity_sent" => "100.00", "quantity_received" => "95.00", "difference" => "5.00", "reason" => reason)
    end

    it "o almoxarife do central (origem) vê o detalhe SEM o motivo" do
      sign_in_as(keeper)
      get "/pharmacy/transfers/#{transfer.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].sole).to eq("lot" => lot_json(lot), "quantity_sent" => "100.00", "quantity_received" => "95.00", "difference" => "5.00")
      expect(response.body).not_to include(reason)
    end

    it "de outro escopo, sem papel, id desconhecido ou lixo → 404" do
      sign_in_as(pharmacy_staff!(unit_location!, "pharmacist"))
      get "/pharmacy/transfers/#{transfer.id}"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      sign_in_as(staff_with("sem-papel@cidade.gov.br"))
      get "/pharmacy/transfers/#{transfer.id}"
      expect(response).to have_http_status(:not_found)
      sign_in_as(assistant)
      [ SecureRandom.uuid, "lixo" ].each do |id|
        get "/pharmacy/transfers/#{id}"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /pharmacy/transfers" do
    let(:other_lot) { stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "TR-B") }
    let!(:older) { sent_transfer!([ lot, "10" ]) }
    let!(:newer) { sent_transfer!([ other_lot, "20" ]) }

    before do
      Pharmacy::ReceiveTransfer.call(transfer: older, items: [ { "lot_id" => lot.id, "quantity_received" => "10" } ], by: assistant, now: Time.current)
    end

    def ids = json_body["transfers"].map { |row| row["id"] }

    it "o destino lista as transferências dele (mais novas primeiro), sem o motivo na lista" do
      sign_in_as(assistant)
      get "/pharmacy/transfers", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ newer.id, older.id ])
      expect(json_body).to include("next_before" => nil)
      expect(json_body["transfers"].flat_map { |t| t["items"] }.flat_map(&:keys).uniq).not_to include("reason")
      expect(json_body["transfers"].find { |t| t["id"] == older.id }["items"].sole).to include("quantity_received" => "10.00", "difference" => "0.00")
    end

    it "a origem (almoxarife do central) lista as mesmas pelo location_id do central" do
      sign_in_as(keeper)
      get "/pharmacy/transfers", params: { location_id: central.id }
      expect(ids).to match_array([ older.id, newer.id ])
    end

    it "location_id de outro local (sem papel) → 403 missing_role; ausente, lixo ou inexistente → 422 invalid_request" do
      sign_in_as(assistant)
      get "/pharmacy/transfers", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/pharmacy/transfers", params: { location_id: unit_location!.id }
      expect(response).to have_http_status(:forbidden)
      [ {}, { location_id: "lixo" }, { location_id: SecureRandom.uuid } ].each do |params|
        get "/pharmacy/transfers", params: params
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      end
    end

    it "filtra por status; status fora da lista → 422 invalid_request path status" do
      sign_in_as(assistant)
      get "/pharmacy/transfers", params: { location_id: farmacia.id, status: "sent" }
      expect(ids).to eq([ newer.id ])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, status: "received" }
      expect(ids).to eq([ older.id ])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, status: "received_with_difference" }
      expect(ids).to eq([])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, status: "lost" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "status") ])
    end

    it "pagina por limit e before, sem repetir nem pular; limit e cursor inválidos → 422; chave desconhecida → 422 com o nome" do
      third = sent_transfer!([ lot, "5" ])
      sign_in_as(assistant)
      get "/pharmacy/transfers", params: { location_id: farmacia.id, limit: 2 }
      page_one = ids
      expect(page_one.size).to eq(2)
      expect(json_body["next_before"]).to be_a(String)
      get "/pharmacy/transfers", params: { location_id: farmacia.id, limit: 2, before: json_body["next_before"] }
      expect(ids.size).to eq(1)
      expect(json_body["next_before"]).to be_nil
      expect((page_one + ids)).to match_array([ older.id, newer.id, third.id ])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, limit: 0 }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_limit", "limit") ])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, before: "lixo" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cursor", "before") ])
      get "/pharmacy/transfers", params: { location_id: farmacia.id, short_code: "ABC" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "short_code") ])
    end

    it "interruptor desligado → 403 feature_disabled" do
      sign_in_as(assistant)
      disable_pharmacy!
      get "/pharmacy/transfers", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end
  end
end
