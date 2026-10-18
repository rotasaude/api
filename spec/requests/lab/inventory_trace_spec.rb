require "rails_helper"

# Spec §6.3, §6.7 e contrato §5, §7 (F-21.33): lote em uso por aparelho e
# exame (marcar outro encerra o anterior; o mesmo de novo = 200, nada criado,
# C-E6); resultado e valor de controle guardam o lote em uso no momento em
# que entram (ou nada: "sem rastreio"); escolher repetição mantém o lote da
# medida; rastreio por lote sem nome de paciente, com trilha, em JSON e CSV.
# Aparelho ou lote de outro laboratório: 404 (C-E27). O lote em uso é lido
# sem interruptor (Desvio 9). Toda recusa: status + código + nada gravado.
RSpec.describe "Estoque — lote em uso e rastreio", type: :request do
  before { qc_city!(inventory: true) }

  let(:s) { qc_scenario! }
  let(:staff) { lab_staff! }
  let(:supply) do
    LabSupply.create!(exam_provider: s.provider, name: "Glicose GOD-PAP", kind: "reagent", unit: "kit", tests_per_package: 500, minimum_stock: 1,
                      expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
  end

  def receive!(number, supply: self.supply)
    Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => number, "expires_on" => (Time.zone.today + 200).iso8601,
                                      "supplier" => "Distribuidora", "origin" => "purchase", "quantity" => 3 }, by: staff).payload[:lot]
  end

  def use!(lot, exam: s.exam, instrument: s.instrument)
    json_post "/lab/inventory/in_use", lot_id: lot.respond_to?(:id) ? lot.id : lot, instrument_id: instrument.respond_to?(:id) ? instrument.id : instrument,
                                       lab_exam_id: exam.respond_to?(:id) ? exam.id : exam
  end

  def counts = [ LabSupplyInUse.count, LabSupplyInUse.current.count, DomainEvent.count ]

  # status + código + nada gravado
  def refuses(status, error)
    before = counts
    yield
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(counts).to eq(before)
  end

  it "marcar o lote em uso encerra o anterior; o mesmo de novo é 200 sem nada novo; recusas de tipo, validade, exame e aparelho" do
    first = receive!("GL1")
    second = receive!("GL2")
    sign_in_as(staff)
    use!(first)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("lot_id" => first.id, "lot_number" => "GL1", "supply_name" => "Glicose GOD-PAP", "exam_name" => "Glicose",
                                 "instrument_id" => s.instrument.id, "lab_exam_id" => s.exam.id, "ended_at" => nil)
    current_id = json_body["id"]

    # C-E6: o mesmo lote de novo — 200 com o registro atual, nada criado.
    before = counts
    use!(first)
    expect(response).to have_http_status(:ok)
    expect(json_body["id"]).to eq(current_id)
    expect(counts).to eq(before)

    use!(second)
    expect(response).to have_http_status(:created)
    get "/lab/inventory/in_use", params: { instrument_id: s.instrument.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["in_use"].map { |u| u["lot_number"] }).to eq([ "GL2" ])
    ended = LabSupplyInUse.where(lab_supply_lot_id: first.id).sole
    expect([ ended.ended_at.present?, ended.ended_by_user_id ]).to eq([ true, staff.id ])
    expect(DomainEvent.where(name: "lab_supply_in_use.changed").map { |e| e.payload.keys.sort })
      .to eq([ %w[lab_exam_id lab_instrument_id lab_supply_in_use_id] ] * 2)

    tube = LabSupply.create!(exam_provider: s.provider, name: "Tubo fluoreto", kind: "consumable", unit: "caixa", minimum_stock: 1,
                             expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
    tube_lot = receive!("TB1", supply: tube)
    refuses(422, "lot_not_reagent") { use!(tube_lot) }
    other_exam = qc_exam!(provider: s.provider, instrument: s.instrument, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE")
    refuses(422, "exam_not_linked") { use!(second, exam: other_exam) }
    refuses(422, "exam_not_linked") { use!(second, exam: "nope") }
    refuses(422, "exam_not_linked") { use!(second, exam: SecureRandom.uuid) }
    old = LabSupplyLot.create!(lab_supply: supply, lot_number: "GL0", expires_on: Time.zone.today - 1, supplier: "D", origin: "purchase",
                               created_by_user: staff, created_at: Time.current)
    refuses(422, "expired_lot") { use!(old) }
    refuses(422, "invalid_instrument") { use!(second, instrument: SecureRandom.uuid) }
    refuses(422, "invalid_instrument") { use!(second, instrument: "nope") }
    inactive = qc_instrument!(s.provider, name: "Parado", hl7_equipment_id: "BIO-09").tap { |i| i.update!(active: false) }
    refuses(422, "invalid_instrument") { use!(second, instrument: inactive) }
    refuses(422, "invalid_instrument") { use!(second, instrument: qc_instrument!(lab_provider!, hl7_equipment_id: "BIO-77")) }
    refuses(404, "not_found") { use!(SecureRandom.uuid) }
    refuses(404, "not_found") { use!("nope") }
    expect(DomainEvent.where(name: "lab_supply_in_use.changed").count).to eq(2)
  end

  it "resultado e controle guardam o lote em uso; repetição escolhida mantém o lote; sem lote = sem rastreio" do
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = req.items.first
    type!(item, { glicose: "98" })
    expect(item.results.last.reagent_lot_id).to be_nil # antes de haver lote em uso
    lot = receive!("GL1")
    sign_in_as(staff)
    use!(lot)
    type!(item, { glicose: "99" })
    measured = item.results.reload.last
    expect(measured.reagent_lot_id).to eq(lot.id)
    get "/lab/entry", params: { item_id: item.id }
    expect(json_body["items"].sole["results"].map { |r| r["reagent_lot"] }).to eq([ nil, { "id" => lot.id, "lot_number" => "GL1" } ])
    value = qc_value!(s, "Nível 1", 0.1, by: staff)[:value]
    expect(value.reagent_lot_id).to eq(lot.id)
    use!(receive!("GL2"))
    lead = lab_releaser!(s.provider, lead: true)
    copy = Lab::ChooseResult.call(result: measured, by: lead).payload[:result]
    expect(copy.reagent_lot_id).to eq(lot.id) # a medida foi com o GL1

    events = DomainEvent.count
    get "/lab/inventory/lots/#{lot.id}/trace"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("lot_id" => lot.id, "lot_number" => "GL1")
    expect(json_body["results"]).to eq([ { "requisition_number" => req.number, "sigtap_code" => "0202010473", "entered_at" => measured.entered_at.iso8601 } ])
    expect(json_body["qc_values"].map { |v| [ v["run_id"], v["analyte_key"] ] }).to eq([ [ value.lab_qc_run_id, "glicose" ] ])
    expect(response.body).not_to include(req.patient.display_name)
    expect(DomainEvent.count).to eq(events + 1)
    expect(DomainEvent.where(name: "lab_supply_lot.traced").map(&:payload)).to eq([ { "lab_supply_lot_id" => lot.id, "user_id" => staff.id } ])
    get "/lab/inventory/lots/#{lot.id}/trace.csv"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.headers["Content-Disposition"]).to include("attachment", "rastreio-lote-gl1.csv")
    expect(response.body.lines.first.strip).to eq("tipo,requisicao_ou_corrida,exame_ou_analito,data")
    expect(response.body).to include(req.number, "resultado", "controle", value.lab_qc_run_id)
    expect(response.body).not_to include(req.patient.display_name)
    expect(DomainEvent.where(name: "lab_supply_lot.traced").count).to eq(2)
  end

  it "liberação mostra o lote da linha" do
    lot = receive!("GL1")
    sign_in_as(staff)
    use!(lot)
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    type!(req.items.first, { glicose: "99" })
    lead = lab_releaser!(s.provider, lead: true)
    sign_in_as(lead)
    get "/lab/releases/#{req.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].sole["results"].map { |r| r["reagent_lot"] }).to eq([ { "id" => lot.id, "lot_number" => "GL1" } ])
  end

  it "outro laboratório: aparelho e lote respondem 404, nada gravado; desconhecidos também" do
    lot = receive!("GL1")
    outsider = lab_releaser!(lab_provider!, lead: true)
    sign_in_as(outsider)
    refuses(404, "not_found") { use!(lot) }
    get "/lab/inventory/in_use", params: { instrument_id: s.instrument.id }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    refuses(404, "not_found") { get "/lab/inventory/lots/#{lot.id}/trace" }
    refuses(404, "not_found") { get "/lab/inventory/lots/#{lot.id}/trace.csv" }

    sign_in_as(staff)
    refuses(404, "not_found") { get "/lab/inventory/lots/#{SecureRandom.uuid}/trace" }
    refuses(404, "not_found") { get "/lab/inventory/lots/nope/trace" }
    get "/lab/inventory/in_use", params: { instrument_id: SecureRandom.uuid }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    get "/lab/inventory/in_use"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
  end

  it "estoque desligado: rotas 403, mas o lote em uso já gravado continua anotado nos resultados (Desvio 9)" do
    lot = receive!("GL1")
    second = receive!("GL2")
    sign_in_as(staff)
    use!(lot)
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_inventory", enabled: false, maintainer: ledi_maintainer!)
    refuses(403, "feature_disabled") { use!(second) }
    refuses(403, "feature_disabled") { get "/lab/inventory/lots/#{lot.id}/trace" }
    get "/lab/inventory/in_use", params: { instrument_id: s.instrument.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])

    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = type!(req.items.first, { glicose: "99" })
    expect(item.results.last.reagent_lot_id).to eq(lot.id)
  end

  it "exame sem aparelho ou par sem lote: resultado sem rastreio" do
    lot = receive!("GL1")
    sign_in_as(staff)
    use!(lot)
    loose = lab_exam!(provider: s.provider, sigtap_code: "0202010317", name: "Creatinina", analytes: LabHelpers::GLUCOSE)
    req = received_requisition!(provider: s.provider, exams: [ loose ])
    item = type!(req.items.first, { glicose: "50" })
    expect(item.results.last.reagent_lot_id).to be_nil
  end
end
