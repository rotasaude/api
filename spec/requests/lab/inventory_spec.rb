require "rails_helper"

# Contrato §5 (F-21.32): itens (admin), entrada de lote (vencido recusado),
# abertura, perda, vencimento e ajuste (só admin) com motivo; saldo = soma
# dos movimentos e nunca negativo; alertas sem trilha (vencendo, abaixo do
# mínimo, resultados sem rastreio). Item, lote ou movimento de outro
# laboratório: 404 (C-E25). Toda recusa: status + código + nada gravado.
RSpec.describe "Estoque do laboratório", type: :request do
  before { inventory_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:admin) { lab_admin! }
  let(:staff) { lab_staff! }
  let(:supply_body) do
    { provider_id: provider.id, name: "Glicose GOD-PAP", kind: "reagent", unit: "kit", tests_per_package: 500, minimum_stock: 3,
      expiry_alert_days: 30, lab_exam_ids: [ exam.id ], active: true }
  end

  def create_supply(body = supply_body)
    json_post "/lab/inventory/supplies", body
    json_body
  end

  def receive(supply_id, lot_number: "GL2609", expires_on: (Time.zone.today + 240).iso8601, quantity: 4, **over)
    json_post "/lab/inventory/lots", { supply_id: supply_id, lot_number: lot_number, expires_on: expires_on, supplier: "Distribuidora Paraná",
                                       origin: "purchase", quantity: quantity, document: "NF 4471" }.merge(over)
    json_body
  end

  def move(lot_id, kind, quantity, reason = nil)
    json_post "/lab/inventory/movements", { lot_id: lot_id, kind: kind, quantity: quantity, reason: reason }.compact
  end

  def counts = [ LabSupply.count, LabSupplyLot.count, LabSupplyMovement.count, DomainEvent.count ]

  # status + código + nada gravado
  def refuses(status, error)
    before = counts
    yield
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(counts).to eq(before)
  end

  def seeded_lot(quantity: 4)
    stepped_up!(admin)
    supply = create_supply
    lot = receive(supply["id"], quantity: quantity)
    [ supply, lot ]
  end

  it "admin cadastra itens; recusas de tipo, rendimento e exames" do
    stepped_up!(admin)
    supply = create_supply
    expect(response).to have_http_status(:created)
    expect(supply).to include("kind" => "reagent", "tests_per_package" => 500, "balance" => 0, "below_minimum" => true,
                              "lab_exam_ids" => [ exam.id ], "provider_id" => provider.id)
    refuses(422, "invalid_tests_per_package") { create_supply(supply_body.merge(name: "Outro", kind: "consumable")) } # só reagente tem rendimento
    refuses(422, "invalid_tests_per_package") { create_supply(supply_body.merge(name: "Outro", tests_per_package: nil)) }
    refuses(422, "invalid_kind") { create_supply(supply_body.merge(name: "Outro", kind: "solvente")) }
    foreign_exam = lab_exam!(provider: lab_provider!)
    refuses(422, "invalid_exams") { create_supply(supply_body.merge(name: "Outro", lab_exam_ids: [ foreign_exam.id ])) }
    refuses(422, "invalid_exams") { create_supply(supply_body.merge(name: "Outro", lab_exam_ids: [ exam.id, exam.id ])) }
    refuses(422, "invalid_exams") { create_supply(supply_body.merge(name: "Outro", lab_exam_ids: [ "nope" ])) }
    refuses(422, "duplicate_name") { create_supply }
    refuses(422, "duplicate_name") { create_supply(supply_body.merge(name: "  glicose god-pap ")) }
    json_patch "/lab/inventory/supplies/#{supply['id']}", supply_body.except(:provider_id).merge(minimum_stock: 2)
    expect(response).to have_http_status(:ok)
    expect(json_body["minimum_stock"]).to eq(2)
    create_supply(supply_body.merge(name: "Ponteira 200 µL", kind: "consumable", unit: "caixa", tests_per_package: nil, lab_exam_ids: [])
                             .except(:expiry_alert_days))
    expect(response).to have_http_status(:created)
    expect(json_body).to include("expiry_alert_days" => 30, "tests_per_package" => nil) # padrão 30
    get "/lab/inventory/supplies", params: { provider_id: provider.id }
    expect(json_body["supplies"].map { |s| s["name"] }).to eq([ "Glicose GOD-PAP", "Ponteira 200 µL" ])

    sign_in_as(staff)
    refuses(401, "mfa_required") { create_supply(supply_body.merge(name: "Da técnica")) } # sem step-up
    stepped_up!(staff)
    refuses(403, "missing_role") { create_supply(supply_body.merge(name: "Da técnica")) }
    refuses(403, "missing_role") { json_patch "/lab/inventory/supplies/#{supply['id']}", supply_body.merge(minimum_stock: 9) }
    get "/lab/inventory/supplies", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok) # membro lê
  end

  it "limites do item" do
    stepped_up!(admin)
    refuses(422, "invalid_name") { create_supply(supply_body.merge(name: "  ")) }
    refuses(422, "invalid_name") { create_supply(supply_body.merge(name: "x" * 121)) }
    refuses(422, "invalid_unit") { create_supply(supply_body.merge(unit: "")) }
    refuses(422, "invalid_unit") { create_supply(supply_body.merge(unit: "u" * 21)) }
    refuses(422, "invalid_tests_per_package") { create_supply(supply_body.merge(tests_per_package: 0)) }
    refuses(422, "invalid_tests_per_package") { create_supply(supply_body.merge(tests_per_package: 100_001)) }
    refuses(422, "invalid_minimum_stock") { create_supply(supply_body.merge(minimum_stock: -1)) }
    refuses(422, "invalid_minimum_stock") { create_supply(supply_body.merge(minimum_stock: 100_001)) }
    refuses(422, "invalid_minimum_stock") { create_supply(supply_body.merge(minimum_stock: "3")) }
    refuses(422, "invalid_expiry_alert_days") { create_supply(supply_body.merge(expiry_alert_days: 0)) }
    refuses(422, "invalid_expiry_alert_days") { create_supply(supply_body.merge(expiry_alert_days: 366)) }
    refuses(422, "invalid_active") { create_supply(supply_body.merge(active: "yes")) }
    refuses(422, "invalid_provider") { create_supply(supply_body.merge(provider_id: "nope")) }
    refuses(422, "invalid_provider") { create_supply(supply_body.merge(provider_id: SecureRandom.uuid)) }
    refuses(404, "not_found") { json_patch "/lab/inventory/supplies/#{SecureRandom.uuid}", supply_body }
    create_supply(supply_body.merge(name: "x" * 120, unit: "u" * 20, tests_per_package: 100_000, minimum_stock: 100_000, expiry_alert_days: 365))
    expect(response).to have_http_status(:created)
    create_supply(supply_body.merge(name: "Mínimos", tests_per_package: 1, minimum_stock: 0, expiry_alert_days: 1))
    expect(response).to have_http_status(:created)
  end

  it "entrada, abertura, perda, vencimento, ajuste; saldo nunca negativo; motivos" do
    stepped_up!(admin)
    supply = create_supply
    sign_in_as(staff)
    lot = receive(supply["id"])
    expect(response).to have_http_status(:created)
    expect(lot).to include("lot_number" => "GL2609", "balance" => 4, "origin" => "purchase", "expired" => false, "supply_name" => "Glicose GOD-PAP")
    again = receive(supply["id"], quantity: 2)
    expect([ again["id"], again["balance"] ]).to eq([ lot["id"], 6 ]) # nova entrada do mesmo lote
    refuses(422, "duplicate_lot") { receive(supply["id"], expires_on: (Time.zone.today + 100).iso8601) } # mesmo número com outra validade
    refuses(422, "expired_lot") { receive(supply["id"], lot_number: "GL2508", expires_on: (Time.zone.today - 1).iso8601) }
    refuses(422, "invalid_quantity") { receive(supply["id"], lot_number: "GL2610", quantity: 0) }

    move(lot["id"], "opening", 2)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("kind" => "opening", "quantity" => -2, "balance" => 4)
    refuses(422, "reason_required") { move(lot["id"], "loss", 1, "") }
    refuses(422, "reason_required") { move(lot["id"], "expiry", 1, "   ") }
    move(lot["id"], "loss", 1, "Frasco quebrado")
    expect(json_body["balance"]).to eq(3)
    refuses(422, "insufficient_balance") { move(lot["id"], "opening", 9) }
    refuses(403, "missing_role") { move(lot["id"], "adjustment", -1, "Contagem") } # ajuste só admin
    refuses(422, "invalid_kind") { move(lot["id"], "receipt", 1) }
    sign_in_as(step_up_enrolled!(admin))
    refuses(401, "mfa_required") { move(lot["id"], "adjustment", -1, "Contagem") } # ajuste com step-up
    stepped_up!(admin)
    move(lot["id"], "adjustment", -1, "Contagem de inventário")
    expect(json_body["balance"]).to eq(2)
    refuses(422, "insufficient_balance") { move(lot["id"], "adjustment", -5, "Contagem") }
    get "/lab/inventory/movements", params: { lot_id: lot["id"] }
    expect(json_body["movements"].map { |m| [ m["kind"], m["quantity"] ] })
      .to eq([ [ "adjustment", -1 ], [ "loss", -1 ], [ "opening", -2 ], [ "receipt", 2 ], [ "receipt", 4 ] ])
    expect(json_body["movements"].last).to include("document" => "NF 4471", "reason" => nil)
    get "/lab/inventory/lots", params: { supply_id: supply["id"], with_balance: "true" }
    expect(json_body["lots"].map { |l| [ l["lot_number"], l["balance"] ] }).to eq([ [ "GL2609", 2 ] ])
    get "/lab/inventory/lots", params: { provider_id: provider.id }
    expect(json_body["lots"].map { |l| l["lot_number"] }).to eq([ "GL2609" ])
    expect(LabSupplyLot.find(lot["id"]).balance).to eq(2)
    expect(DomainEvent.where(name: "lab_supply_movement.recorded").map { |e| e.payload.keys.sort }.uniq).to eq([ %w[kind lab_supply_movement_id] ])
    expect(DomainEvent.where(name: "lab_supply_lot.received").map { |e| e.payload.keys.sort }.uniq).to eq([ %w[lab_supply_id lab_supply_lot_id] ])
    expect(DomainEvent.where(name: "lab_supply_lot.received").count).to eq(2)
  end

  it "limites da entrada e do movimento; motivo até 1000 (C-E11)" do
    supply, lot = seeded_lot(quantity: 10)
    sign_in_as(staff)
    id = supply["id"]
    refuses(422, "invalid_lot_number") { receive(id, lot_number: "  ") }
    refuses(422, "invalid_lot_number") { receive(id, lot_number: "L" * 41) }
    refuses(422, "invalid_supplier") { receive(id, lot_number: "N1", supplier: "") }
    refuses(422, "invalid_supplier") { receive(id, lot_number: "N1", supplier: "s" * 121) }
    refuses(422, "invalid_origin") { receive(id, lot_number: "N1", origin: "gift") }
    refuses(422, "invalid_quantity") { receive(id, lot_number: "N1", quantity: 100_001) }
    refuses(422, "invalid_quantity") { receive(id, lot_number: "N1", quantity: "4") }
    refuses(422, "invalid_document") { receive(id, lot_number: "N1", document: "d" * 61) }
    refuses(422, "invalid_expires_on") { receive(id, lot_number: "N1", expires_on: "2026-13-01") }
    refuses(422, "invalid_expires_on") { receive(id, lot_number: "N1", expires_on: "18/10/2030") }
    receive(id, lot_number: "N2", origin: "donation", expires_on: Time.zone.today.iso8601, quantity: 100_000, document: nil)
    expect(response).to have_http_status(:created) # vence hoje: ainda aceito

    refuses(422, "invalid_quantity") { move(lot["id"], "opening", 0) }
    refuses(422, "invalid_quantity") { move(lot["id"], "opening", -1) }
    refuses(422, "invalid_quantity") { move(lot["id"], "loss", 100_001, "Muito") }
    refuses(422, "invalid_quantity") { move(lot["id"], "opening", "1") }
    refuses(422, "invalid_reason") { move(lot["id"], "loss", 1, "m" * 1001) }
    refuses(422, "invalid_reason") { move(lot["id"], "opening", 1, "m" * 1001) }
    move(lot["id"], "expiry", 1, "m" * 1000)
    expect(response).to have_http_status(:created)
    move(lot["id"], "opening", 1, "Bancada 2")
    expect(json_body).to include("reason" => "Bancada 2", "balance" => 8)
    stepped_up!(admin)
    refuses(422, "invalid_quantity") { move(lot["id"], "adjustment", 0, "Contagem") }
    refuses(422, "invalid_quantity") { move(lot["id"], "adjustment", -100_001, "Contagem") }
    refuses(422, "reason_required") { move(lot["id"], "adjustment", 1, nil) }
    move(lot["id"], "adjustment", 3, "Sobra na contagem")
    expect(json_body["balance"]).to eq(11)
  end

  it "outro laboratório: item, lote e movimento respondem 404; laboratório alheio na lista, 403" do
    supply, lot = seeded_lot
    outsider = lab_releaser!(lab_provider!, lead: true)
    sign_in_as(outsider)
    get "/lab/inventory/lots", params: { supply_id: supply["id"] }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    get "/lab/inventory/movements", params: { lot_id: lot["id"] }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    refuses(404, "not_found") { receive(supply["id"], quantity: 1) }
    refuses(404, "not_found") { move(lot["id"], "opening", 1) }
    [ "/lab/inventory/supplies", "/lab/inventory/lots", "/lab/inventory/alerts" ].each do |path|
      get path, params: { provider_id: provider.id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end

    sign_in_as(staff)
    refuses(404, "not_found") { receive(SecureRandom.uuid) }
    refuses(404, "not_found") { receive("nope") }
    refuses(404, "not_found") { move(SecureRandom.uuid, "opening", 1) }
    get "/lab/inventory/movements", params: { lot_id: "nope" }
    expect(response).to have_http_status(:not_found)
    get "/lab/inventory/lots"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "filter_required" ])
    get "/lab/inventory/lots", params: { supply_id: SecureRandom.uuid }
    expect(response).to have_http_status(:not_found)
    [ "/lab/inventory/supplies", "/lab/inventory/lots", "/lab/inventory/alerts" ].each do |path|
      get path, params: { provider_id: "nope" }
      expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    end
  end

  it "alertas: vencendo, abaixo do mínimo e resultados sem rastreio; sem trilha" do
    stepped_up!(admin)
    supply = create_supply
    receive(supply["id"], lot_number: "GL2603", expires_on: (Time.zone.today + 20).iso8601, quantity: 1)
    receive(supply["id"], lot_number: "GL2609", quantity: 1)
    instrument = qc_instrument!(provider)
    tracked = qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE",
                       analytes: [ LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "decimals" => 2, "entry_min" => nil,
                                                                  "entry_max" => nil, "critical_low" => nil, "critical_high" => nil) ])
    req = received_requisition!(provider: provider, exams: [ tracked ])
    type!(req.items.first, { creatinina: "0,9" })
    sign_in_as(staff)
    expect { get "/lab/inventory/alerts", params: { provider_id: provider.id } }.not_to(change { counts })
    expect(response).to have_http_status(:ok)
    expect(json_body["expiring"].map { |l| l.values_at("lot_number", "supply_name", "balance") }).to eq([ [ "GL2603", "Glicose GOD-PAP", 1 ] ])
    expect(json_body["expiring"].first["lot_id"]).to be_present
    expect(json_body["below_minimum"].map { |x| x.values_at("supply_id", "name", "unit", "balance", "minimum_stock") })
      .to eq([ [ supply["id"], "Glicose GOD-PAP", "kit", 2, 3 ] ])
    expect(json_body["untraced_results"]).to eq(1)
  end

  describe "alertas: bordas (payload exato)" do
    let(:today) { Time.zone.today }

    def supply!(name: "Glicose GOD-PAP", minimum_stock: 0, active: true, alert_days: 30)
      LabSupply.create!(exam_provider: provider, name: name, kind: "reagent", unit: "kit", tests_per_package: 500, minimum_stock: minimum_stock,
                        expiry_alert_days: alert_days, lab_exam_ids: [], active: active)
    end

    # Gravado direto (um lote vencido não entra pela API).
    def lot!(supply, number, expires_on, quantity)
      lot = LabSupplyLot.create!(lab_supply: supply, lot_number: number, expires_on: expires_on, supplier: "Distribuidora", origin: "purchase",
                                 created_by_user: admin)
      LabSupplyMovement.create!(lab_supply_lot: lot, kind: "receipt", quantity: quantity, recorded_by_user: admin, recorded_at: Time.current)
      lot
    end

    def alerts!
      sign_in_as(staff)
      before = counts
      get "/lab/inventory/alerts", params: { provider_id: provider.id }
      expect(response).to have_http_status(:ok)
      expect(counts).to eq(before) # sem trilha
      json_body
    end

    def lot_alert(lot, balance)
      { "id" => lot.id, "lot_id" => lot.id, "supply_id" => lot.lab_supply_id, "supply_name" => lot.lab_supply.name, "lot_number" => lot.lot_number,
        "expires_on" => lot.expires_on.iso8601, "supplier" => "Distribuidora", "origin" => "purchase", "balance" => balance,
        "expired" => lot.expires_on < today, "in_use" => [] }
    end

    def supply_alert(supply, balance)
      { "id" => supply.id, "supply_id" => supply.id, "provider_id" => provider.id, "name" => supply.name, "kind" => "reagent", "unit" => "kit",
        "tests_per_package" => 500, "minimum_stock" => supply.minimum_stock, "expiry_alert_days" => supply.expiry_alert_days,
        "lab_exam_ids" => [], "active" => supply.active, "balance" => balance, "below_minimum" => true }
    end

    it "janela de validade: vence no dia N = expiry_alert_days entra; N+1 não" do
      supply = supply!
      inside = lot!(supply, "N30", today + 30, 2)
      lot!(supply, "N31", today + 31, 2)
      expect(alerts!).to eq("expiring" => [ lot_alert(inside, 2) ], "below_minimum" => [], "untraced_results" => 0)
    end

    it "lote vencido com saldo: aparece como vencido e não conta para o mínimo" do
      supply = supply!(minimum_stock: 3)
      expired = lot!(supply, "V1", today - 1, 5)
      expect(alerts!).to eq("expiring" => [ lot_alert(expired, 5).merge("expired" => true) ], "below_minimum" => [ supply_alert(supply, 0) ],
                            "untraced_results" => 0)
    end

    it "C-E28: lote vencido que levaria o item acima do mínimo não conta — lista e alerta dizem abaixo do mínimo" do
      supply = supply!(minimum_stock: 3)
      expired = lot!(supply, "V2", today - 1, 10)
      valid = lot!(supply, "V3", today + 200, 2)
      body = alerts!
      expect(body).to eq("expiring" => [ lot_alert(expired, 10).merge("expired" => true) ], "below_minimum" => [ supply_alert(supply, 2) ],
                         "untraced_results" => 0)
      get "/lab/inventory/supplies", params: { provider_id: provider.id }
      expect(json_body["supplies"]).to eq([ supply_alert(supply, 12).except("supply_id") ]) # saldo total 12, abaixo do mínimo pelo saldo válido 2
      expect(valid.balance).to eq(2)
    end

    it "lote sem saldo não é alertado como vencendo" do
      supply = supply!
      lot = lot!(supply, "Z1", today + 5, 2)
      LabSupplyMovement.create!(lab_supply_lot: lot, kind: "opening", quantity: -2, recorded_by_user: admin, recorded_at: Time.current)
      expect(alerts!).to eq("expiring" => [], "below_minimum" => [], "untraced_results" => 0)
    end

    it "item inativo fica fora do abaixo do mínimo" do
      supply = supply!(minimum_stock: 5, active: false)
      lot!(supply, "I1", today + 200, 1)
      expect(alerts!).to eq("expiring" => [], "below_minimum" => [], "untraced_results" => 0)
    end

    it "mínimo 0 nunca fica abaixo do mínimo" do
      supply!(minimum_stock: 0)
      expect(alerts!).to eq("expiring" => [], "below_minimum" => [], "untraced_results" => 0)
    end

    context "resultados sem rastreio" do
      let(:tracked) do
        qc_exam!(provider: provider, instrument: qc_instrument!(provider), sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE",
                 analytes: [ LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "decimals" => 2, "entry_min" => nil,
                                                            "entry_max" => nil, "critical_low" => nil, "critical_high" => nil) ])
      end

      def typed_result(exam)
        req = received_requisition!(provider: provider, exams: [ exam ])
        type!(req.items.first, exam == tracked ? { creatinina: "0,9" } : { glicose: "98" }).results.sole
      end

      # Linha a mais do mesmo componente (o resultado é só acréscimo).
      def extra_row!(base, **over)
        LabResult.create!({ lab_requisition_item: base.lab_requisition_item, analyte_key: base.analyte_key, value: base.value, unit: base.unit,
                            flag: base.flag, source: base.source, entered_by_user: base.entered_by_user, entered_at: Time.current,
                            created_at: Time.current }.merge(over))
      end

      def untraced = alerts!.fetch("untraced_results")

      it "conta o resultado de exame com aparelho sem lote de reagente" do
        typed_result(tracked)
        expect(alerts!).to eq("expiring" => [], "below_minimum" => [], "untraced_results" => 1)
      end

      it "não conta o resultado com lote de reagente" do
        base = typed_result(tracked)
        extra_row!(base, reagent_lot: lot!(supply!, "R1", today + 200, 1))
        expect(untraced).to eq(1) # só a linha sem lote
      end

      it "não conta exame sem aparelho" do
        typed_result(exam)
        expect(alerts!).to eq("expiring" => [], "below_minimum" => [], "untraced_results" => 0)
      end

      it "não conta a cópia escolhida" do
        base = typed_result(tracked)
        extra_row!(base, chosen: true, chosen_from: base)
        expect(untraced).to eq(1)
      end

      it "não conta resultado com mais de 30 dias" do
        base = typed_result(tracked)
        extra_row!(base, created_at: 31.days.ago)
        extra_row!(base, created_at: 29.days.ago)
        expect(untraced).to eq(2) # a de hoje e a de 29 dias
      end
    end
  end

  it "estoque desligado: 403" do
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_inventory", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(staff)
    get "/lab/inventory/alerts", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "lab_inventory")
    stepped_up!(admin)
    refuses(403, "feature_disabled") { create_supply }
  end
end
