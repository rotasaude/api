require "rails_helper"

# Módulo 27a, Task 7 (ADR 0045; contrato §6 e H2/H4/H8/H12): inventário, perdas e
# vencimentos. Criar, aprovar e rejeitar pedem step-up; só `stock_keeper` ou
# `pharmacist` do local (403 sozinho). Respostas SEM envelope, na forma
# <adjustment>, com o motivo também na lista. Todo 422 traz `problems`. Ajuste de
# outro escopo (sem papel no local dele) por id → 404.
RSpec.describe "Farmácia — ajustes, perdas e vencimentos", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:second_keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(central, "pharmacist") }
  let(:assistant) { pharmacy_staff!(central, "pharmacy_assistant") }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "100", lot_number: "AJ-A") }
  let(:reason) { "Contagem do inventário de outubro" }
  let(:today) { Time.zone.today }

  def body(kind: "adjustment", counted: "95", quantity: nil, lot_record: lot, location: central, why: reason)
    { location_id: location.id, lot_id: lot_record&.id, kind: kind, counted_quantity: counted, quantity: quantity, reason: why }.compact
  end

  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def written = [ StockAdjustment.count, StockMovement.count ]
  def balance(lot_record = lot) = Pharmacy::Ledger.balance(location_id: central.id, lot_id: lot_record.id)
  def disable_pharmacy! = Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)

  def pending!(counted = "85", by: keeper)
    result = Pharmacy::RequestAdjustment.call(location: central, lot: lot, kind: "adjustment", counted_quantity: counted, quantity: nil,
                                              reason: reason, by: by, settings: Pharmacy::Settings.current)
    raise result.inspect unless result.ok? && result.payload.fetch(:adjustment).status == "pending"

    result.payload.fetch(:adjustment)
  end

  def lot_json(lot_record)
    { "id" => lot_record.id,
      "item" => { "catalog_item_id" => paracetamol.id, "catmat_code" => 267_778, "name" => paracetamol.label, "unit" => paracetamol.unit,
                  "dispensing_unit" => "comprimido", "controlled" => false, "controlled_list" => nil },
      "lot_number" => lot_record.lot_number, "expires_on" => lot_record.expires_on.iso8601, "manufacturer" => lot_record.manufacturer }
  end

  def central_json = { "id" => central.id, "name" => central.name, "kind" => "central", "active" => true, "health_unit" => nil }

  def person_json(user) = { "user_id" => user.id, "name" => user.professional&.professional_name }

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  describe "POST /pharmacy/adjustments" do
    it "o almoxarife com step-up conta 95: 201 sem envelope, applied, saldo 95, forma <adjustment> com o motivo" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body
      expect(response).to have_http_status(:created)
      adjustment = StockAdjustment.sole
      expect(json_body).to eq(
        "id" => adjustment.id, "location" => central_json, "lot" => lot_json(lot), "kind" => "adjustment", "status" => "applied",
        "quantity" => "-5.00", "counted_quantity" => "95.00", "balance_at_request" => "100.00", "reason" => reason,
        "requested_by" => person_json(keeper), "decided_by" => nil, "decision_reason" => nil, "created_at" => adjustment.created_at.iso8601
      )
      expect(json_body).not_to have_key("adjustment")
      expect(balance).to eq(95)
      expect(StockMovement.where(kind: "adjustment").sole.quantity).to eq(-5)
    end

    it "contagem acima do limite: 201 pending, saldo intacto, sem movimento" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(counted: "85")
      expect(response).to have_http_status(:created)
      expect(json_body).to include("status" => "pending", "quantity" => "-15.00", "counted_quantity" => "85.00", "balance_at_request" => "100.00")
      expect([ balance, StockMovement.where(kind: "adjustment").count ]).to eq([ 100, 0 ])
    end

    it "o farmacêutico também ajusta (com o nome do perfil em requested_by)" do
      stepped_up!(pharmacist)
      json_post "/pharmacy/adjustments", body(counted: "96")
      expect(response).to have_http_status(:created)
      expect(json_body["requested_by"]).to eq(person_json(pharmacist))
      expect(json_body["requested_by"]["name"]).to be_present
    end

    it "perda: aplicada na hora, quantity com sinal de saída; vencimento só de lote vencido" do
      expired = stocked_lot!(central, item: paracetamol, quantity: "30", lot_number: "AJ-OLD", expires_on: today - 2)
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(kind: "loss", counted: nil, quantity: "40")
      expect(json_body).to include("kind" => "loss", "status" => "applied", "quantity" => "-40.00", "counted_quantity" => nil)
      expect(balance).to eq(60)

      json_post "/pharmacy/adjustments", body(kind: "expiry", counted: nil, quantity: "30", lot_record: expired)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("kind" => "expiry", "status" => "applied", "quantity" => "-30.00")
      expect(balance(expired)).to eq(0)

      json_post "/pharmacy/adjustments", body(kind: "expiry", counted: nil, quantity: "10")
      expect([ response.status, json_body ]).to eq([ 422, refusal("lot_not_expired", "lot_id") ])
    end

    it "sem step-up (sessão sem MFA recente, ou sem MFA cadastrado) → 401 mfa_required e nada é gravado" do
      sign_in_as(step_up_enrolled!(keeper))
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      sign_in_as(second_keeper)
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(written).to eq([ 0, 1 ])
    end

    it "auxiliar → 403 missing_role, sozinho, mesmo com step-up e corpo inválido" do
      stepped_up!(assistant)
      json_post "/pharmacy/adjustments", { location_id: central.id, kind: "x", reason: "y" }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(written).to eq([ 0, 1 ])
    end

    it "almoxarife de outro local e usuário sem papel → 403; Membership revogada com vínculo ativo → 403" do
      stepped_up!(pharmacy_staff!(farmacia, "stock_keeper"))
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      stepped_up!(staff_with("sem-papel@cidade.gov.br"))
      json_post "/pharmacy/adjustments", body
      expect(response).to have_http_status(:forbidden)
      stepped_up!(keeper)
      keeper.memberships.find_by!(role: "stock_keeper").revoke!
      json_post "/pharmacy/adjustments", body
      expect(response).to have_http_status(:forbidden)
      expect(written).to eq([ 0, 1 ])
    end

    it "location_id ausente, lixo ou inexistente → 422 invalid_request com problems" do
      stepped_up!(keeper)
      [ nil, "lixo", SecureRandom.uuid ].each do |value|
        json_post "/pharmacy/adjustments", body.merge(location_id: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      end
    end

    it "local inativo → 409 location_inactive com path" do
      stepped_up!(keeper)
      central.update_columns(active: false)
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive", "path" => "location_id" } ])
      expect(written).to eq([ 0, 1 ])
    end

    it "motivo com 9 caracteres → 422 invalid_reason, com problems" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(why: "123456789")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_reason", "reason") ])
      expect(written).to eq([ 0, 1 ])
    end

    it "DOIS campos inválidos (quantidade e motivo): 422 com error/path do primeiro e problems com os dois" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(kind: "loss", counted: nil, quantity: "1,5", why: "curto")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_quantity", "path" => "quantity",
                              "problems" => [ { "path" => "quantity", "error" => "invalid_quantity" }, { "path" => "reason", "error" => "invalid_reason" } ])
      expect(written).to eq([ 0, 1 ])
    end

    it "saldo insuficiente (apurado sob trava) junto do motivo curto: as duas recusas, nada gravado" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(kind: "loss", counted: nil, quantity: "200", why: "curto")
      expect(json_body).to eq("error" => "insufficient_balance", "path" => "quantity",
                              "problems" => [ { "path" => "quantity", "error" => "insufficient_balance" }, { "path" => "reason", "error" => "invalid_reason" } ])
      json_post "/pharmacy/adjustments", body(kind: "loss", counted: nil, quantity: "200")
      expect([ response.status, json_body ]).to eq([ 422, refusal("insufficient_balance", "quantity") ])
      expect(written).to eq([ 0, 1 ])
    end

    it "contado igual ao saldo → 422 no_difference; delta acima de 99999.99 → 422 invalid_quantity" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(counted: "100")
      expect([ response.status, json_body ]).to eq([ 422, refusal("no_difference", "counted_quantity") ])
      json_post "/pharmacy/adjustments", body(counted: "200000")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "counted_quantity") ])
      json_post "/pharmacy/adjustments", body(counted: "100099.99")
      expect(response).to have_http_status(:created)
    end

    it "lote ausente ou inexistente, kind inválido e quantidade como número JSON: recusas juntas" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", { location_id: central.id, lot_id: SecureRandom.uuid, kind: "refund", counted_quantity: 95, reason: reason }
      expect(json_body["problems"]).to eq([ { "path" => "lot_id", "error" => "invalid_request" }, { "path" => "kind", "error" => "invalid_request" } ])
      json_post "/pharmacy/adjustments", { location_id: central.id, kind: "adjustment", counted_quantity: 95, reason: reason }
      expect(json_body["problems"]).to eq([ { "path" => "lot_id", "error" => "invalid_request" }, { "path" => "counted_quantity", "error" => "invalid_quantity" } ])
      expect(written).to eq([ 0, 1 ])
    end

    it "segunda contagem do mesmo lote com uma pendente → 409 adjustment_pending (path lot_id); perda passa; depois de decidida, nova contagem passa" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(counted: "85")
      expect(json_body).to include("status" => "pending")
      pending_id = json_body["id"]

      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments", body(counted: "70")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "adjustment_pending", "path" => "lot_id" } ])
      json_post "/pharmacy/adjustments", body(counted: "99")
      expect(response).to have_http_status(:conflict)
      expect(StockAdjustment.count).to eq(1)

      json_post "/pharmacy/adjustments", body(kind: "loss", counted: nil, quantity: "5")
      expect(response).to have_http_status(:created)

      json_post "/pharmacy/adjustments/#{pending_id}/approve", {}
      expect(response).to have_http_status(:ok)
      json_post "/pharmacy/adjustments", body(counted: "60")
      expect(response).to have_http_status(:created)
      expect(json_body["status"]).to eq("pending")
    end

    it "evento stock_adjustment.recorded só com ids e o booleano pending" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments", body(counted: "85")
      expect(DomainEvent.where(name: "stock_adjustment.recorded").sole.payload)
        .to eq("stock_adjustment_id" => StockAdjustment.sole.id, "user_id" => keeper.id, "pending" => true)
    end

    it "o log não leva o motivo nem a contagem (o id do lote não é dado pessoal)" do
      stepped_up!(keeper)
      log = capture_log { json_post "/pharmacy/adjustments", body(counted: "91.37", why: "Frascos quebrados na caixa 4") }
      parameters = log.lines.grep(/Parameters/).join
      expect(parameters).not_to include("Frascos quebrados")
      expect(parameters).not_to include("91.37")
    end

    it "sem sessão → 401; form-encoded com cookie → 415; interruptor desligado → 403 feature_disabled" do
      post "/pharmacy/adjustments", params: { location_id: central.id }
      expect(response).to have_http_status(:unauthorized)
      stepped_up!(keeper)
      post "/pharmacy/adjustments", params: { location_id: central.id }
      expect(response).to have_http_status(:unsupported_media_type)
      disable_pharmacy!
      json_post "/pharmacy/adjustments", body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end

  describe "POST /pharmacy/adjustments/:id/approve e /reject" do
    let!(:adjustment) { pending!("85") }

    it "outro almoxarife com step-up aprova: 200 sem envelope, approved, saldo 85, decided_by" do
      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", { reason: "Conferi a contagem no armário" }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => adjustment.id, "status" => "approved", "quantity" => "-15.00", "decided_by" => person_json(second_keeper),
                                   "decision_reason" => "Conferi a contagem no armário", "requested_by" => person_json(keeper), "reason" => reason)
      expect(json_body).not_to have_key("adjustment")
      expect(balance).to eq(85)
      expect(DomainEvent.where(name: "stock_adjustment.approved").sole.payload).to eq("stock_adjustment_id" => adjustment.id, "user_id" => second_keeper.id)
    end

    it "o farmacêutico aprova sem motivo (opcional)" do
      stepped_up!(pharmacist)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "approved", "decision_reason" => nil)
    end

    it "pelo próprio autor → 403 same_user, sozinho" do
      stepped_up!(keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "same_user" } ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Contagem refeita, o saldo estava certo" }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "same_user" } ])
      expect(adjustment.reload.status).to eq("pending")
    end

    it "sem step-up → 401 mfa_required; nada muda" do
      sign_in_as(step_up_enrolled!(second_keeper))
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Contagem refeita, o saldo estava certo" }
      expect(response).to have_http_status(:unauthorized)
      expect([ adjustment.reload.status, balance ]).to eq([ "pending", 100 ])
    end

    it "auxiliar do local → 403 missing_role, sozinho" do
      stepped_up!(assistant)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "curto" }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(adjustment.reload.status).to eq("pending")
    end

    it "almoxarife de OUTRO local (sem papel no do ajuste) → 404, como todo registro por id de outro escopo; nada muda" do
      stepped_up!(pharmacy_staff!(farmacia, "stock_keeper"))
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Contagem refeita, o saldo estava certo" }
      expect(response).to have_http_status(:not_found)
      stepped_up!(staff_with("sem-papel@cidade.gov.br"))
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect(response).to have_http_status(:not_found)
      expect([ adjustment.reload.status, balance ]).to eq([ "pending", 100 ])
    end

    it "id desconhecido ou lixo → 404" do
      stepped_up!(second_keeper)
      [ SecureRandom.uuid, "lixo" ].each do |id|
        json_post "/pharmacy/adjustments/#{id}/approve", {}
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
    end

    it "aprovar duas vezes → 409 not_pending; saldo muda uma vez" do
      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect(response).to have_http_status(:ok)
      stepped_up!(pharmacist)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_pending" } ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Contagem refeita, o saldo estava certo" }
      expect(response).to have_http_status(:conflict)
      expect(balance).to eq(85)
    end

    it "saem 90 antes da aprovação → 422 insufficient_balance com problems; continua pending" do
      Pharmacy::RequestAdjustment.call(location: central, lot: lot, kind: "loss", counted_quantity: nil, quantity: "90", reason: reason, by: pharmacist,
                                       settings: Pharmacy::Settings.current)
      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 422, refusal("insufficient_balance", "id") ])
      expect([ adjustment.reload.status, balance ]).to eq([ "pending", 10 ])
    end

    it "aprovação com motivo curto → 422 invalid_reason com problems" do
      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", { reason: "curto" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_reason", "reason") ])
      expect(adjustment.reload.status).to eq("pending")
    end

    it "rejeitar sem motivo → 422 reason_required com problems; com motivo → 200 rejected, sem movimento" do
      stepped_up!(second_keeper)
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", {}
      expect([ response.status, json_body ]).to eq([ 422, refusal("reason_required", "reason") ])
      json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Contagem refeita, o saldo estava certo" }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("status" => "rejected", "decided_by" => person_json(second_keeper),
                                   "decision_reason" => "Contagem refeita, o saldo estava certo")
      expect([ balance, StockMovement.where(kind: "adjustment").count ]).to eq([ 100, 0 ])
      expect(DomainEvent.where(name: "stock_adjustment.rejected").sole.payload).to eq("stock_adjustment_id" => adjustment.id, "user_id" => second_keeper.id)
    end

    it "o log não leva o motivo da decisão" do
      stepped_up!(second_keeper)
      log = capture_log { json_post "/pharmacy/adjustments/#{adjustment.id}/reject", { reason: "Recontagem com a chefia da farmácia" } }
      expect(log.lines.grep(/Parameters/).join).not_to include("Recontagem")
    end

    it "interruptor desligado → 403 feature_disabled" do
      stepped_up!(second_keeper)
      disable_pharmacy!
      json_post "/pharmacy/adjustments/#{adjustment.id}/approve", {}
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end

  describe "GET /pharmacy/adjustments/:id" do
    let!(:adjustment) { pending!("85") }

    it "almoxarife e farmacêutico do local veem o detalhe completo (com o motivo)" do
      [ keeper, pharmacist ].each do |user|
        sign_in_as(user)
        get "/pharmacy/adjustments/#{adjustment.id}"
        expect(response).to have_http_status(:ok)
        expect(json_body).to include("id" => adjustment.id, "status" => "pending", "reason" => reason, "lot" => lot_json(lot), "location" => central_json,
                                     "requested_by" => person_json(keeper), "decided_by" => nil, "decision_reason" => nil)
      end
    end

    it "auxiliar do local → 403; de outro escopo, sem papel, desconhecido ou lixo → 404" do
      sign_in_as(assistant)
      get "/pharmacy/adjustments/#{adjustment.id}"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
      get "/pharmacy/adjustments/#{adjustment.id}"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      sign_in_as(keeper)
      [ SecureRandom.uuid, "lixo" ].each do |id|
        get "/pharmacy/adjustments/#{id}"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /pharmacy/adjustments" do
    let!(:first) { pending!("85") }
    let!(:second) do
      Pharmacy::RequestAdjustment.call(location: central, lot: lot, kind: "loss", counted_quantity: nil, quantity: "5", reason: "Frascos quebrados na caixa 4",
                                       by: keeper, settings: Pharmacy::Settings.current, now: Time.current + 1.minute).payload.fetch(:adjustment)
    end
    let!(:elsewhere) do
      farmacia_lot = stocked_lot!(farmacia, item: paracetamol, quantity: "50", lot_number: "AJ-F")
      Pharmacy::RequestAdjustment.call(location: farmacia, lot: farmacia_lot, kind: "loss", counted_quantity: nil, quantity: "5", reason: reason,
                                       by: pharmacy_staff!(farmacia, "pharmacist"), settings: Pharmacy::Settings.current).payload.fetch(:adjustment)
    end

    def ids = json_body["adjustments"].map { |row| row["id"] }

    it "lista os ajustes DO LOCAL, mais novos primeiro, com o motivo na lista; sem envelope de erro" do
      sign_in_as(keeper)
      get "/pharmacy/adjustments", params: { location_id: central.id }
      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ second.id, first.id ])
      expect(json_body["next_before"]).to be_nil
      expect(json_body["adjustments"].map { |row| row["reason"] }).to eq([ "Frascos quebrados na caixa 4", reason ])
      expect(json_body["adjustments"].first.keys).to eq(%w[id location lot kind status quantity counted_quantity balance_at_request reason requested_by
                                                          decided_by decision_reason created_at])
    end

    it "filtra por status e pagina com limit e before" do
      sign_in_as(pharmacist)
      get "/pharmacy/adjustments", params: { location_id: central.id, status: "pending" }
      expect(ids).to eq([ first.id ])
      get "/pharmacy/adjustments", params: { location_id: central.id, limit: 1 }
      expect(ids).to eq([ second.id ])
      cursor = json_body["next_before"]
      expect(cursor).to be_present
      get "/pharmacy/adjustments", params: { location_id: central.id, limit: 1, before: cursor }
      expect(ids).to eq([ first.id ])
      expect(json_body["next_before"]).to be_nil
    end

    it "papel só na farmácia da UBS lista só os dela" do
      sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
      get "/pharmacy/adjustments", params: { location_id: farmacia.id }
      expect(ids).to eq([ elsewhere.id ])
    end

    it "local sem papel (ou só auxiliar) → 403 missing_role; ausente, lixo ou inexistente → 422 com problems" do
      sign_in_as(assistant)
      get "/pharmacy/adjustments", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(keeper)
      get "/pharmacy/adjustments", params: { location_id: farmacia.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      [ {}, { location_id: "lixo" }, { location_id: SecureRandom.uuid } ].each do |params|
        get "/pharmacy/adjustments", params: params
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      end
    end

    it "status, limit, cursor e chave de query inválidos → 422 com problems" do
      sign_in_as(keeper)
      get "/pharmacy/adjustments", params: { location_id: central.id, status: "done" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "status") ])
      get "/pharmacy/adjustments", params: { location_id: central.id, limit: 0 }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_limit", "limit") ])
      get "/pharmacy/adjustments", params: { location_id: central.id, before: "lixo" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cursor", "before") ])
      get "/pharmacy/adjustments", params: { location_id: central.id, reason: "x" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "reason") ])
    end

    it "interruptor desligado → 403 feature_disabled" do
      sign_in_as(keeper)
      disable_pharmacy!
      get "/pharmacy/adjustments", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end
end
