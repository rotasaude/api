require "rails_helper"

# Spec §6.8 e Desvio 13 (F-21.34; C-E8, C-E30): testes realizados no mês
# (entradas de resultado — a repetição conta, a cópia escolhida não, o
# calculado não — e controles por nível e corrida) × testes das aberturas
# (embalagens abertas × rendimento); desvio em %; nada é baixado; tela e CSV.
RSpec.describe "Estoque — consumo estimado", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { qc_city!(inventory: true) }

  let(:s) { qc_scenario! }
  let(:staff) { lab_staff! }
  let(:supply) do
    LabSupply.create!(exam_provider: s.provider, name: "Glicose GOD-PAP", kind: "reagent", unit: "kit", tests_per_package: 100,
                      minimum_stock: 1, expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
  end

  def lot!(supply: self.supply, number: "GL1")
    Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => number, "expires_on" => (Time.zone.today + 200).iso8601,
                                      "supplier" => "Distribuidora", "origin" => "purchase", "quantity" => 5 }, by: staff).payload[:lot]
  end

  def open!(lot) = Lab::Inventory::RecordMovement.call(lot: lot, kind: "opening", quantity: 1, reason: nil, by: staff, admin: false)

  def month_of(date) = date.strftime("%Y-%m")

  def rows(month = month_of(Time.zone.today), provider: s.provider)
    get "/lab/inventory/consumption", params: { provider_id: provider.id, month: month }
    json_body["rows"]
  end

  def total(rows) = rows.find { |r| r["instrument_id"].nil? }

  it "conta testes e aberturas do mês e calcula o desvio" do
    lot = lot!
    open!(lot)
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = req.items.first
    type!(item, { glicose: "98" })
    type!(item, { glicose: "99" }) # repetição: conta
    other = received_requisition!(provider: s.provider, exams: [ s.exam ]).items.first
    type!(other, { glicose: "101" })
    Lab::ChooseResult.call(result: item.results.reload.first, by: lab_releaser!(s.provider, lead: true)) # cópia: não conta
    qc_value!(s, "Nível 1", 0.1, by: staff)
    qc_value!(s, "Nível 2", -0.1, by: staff)
    sign_in_as(staff)
    month = month_of(Time.zone.today)
    events = DomainEvent.count
    get "/lab/inventory/consumption", params: { provider_id: s.provider.id, month: month }
    expect(json_body["rows"]).to eq([
      { "supply_id" => supply.id, "name" => "Glicose GOD-PAP", "instrument_id" => nil, "tests_performed" => 5, "tests_opened" => 100,
        "deviation_pct" => -95.0 },
      { "supply_id" => supply.id, "name" => "Glicose GOD-PAP", "instrument_id" => s.instrument.id, "tests_performed" => 5,
        "tests_opened" => nil, "deviation_pct" => nil }
    ])
    expect(lot.reload.balance).to eq(4) # nada baixado pelo consumo
    expect(DomainEvent.count).to eq(events) # leitura sem trilha
    get "/lab/inventory/consumption.csv", params: { provider_id: s.provider.id, month: month }
    expect(response.body.lines.first.strip).to eq("item,aparelho,testes_realizados,testes_das_aberturas,desvio_pct")
    expect(response.body.lines[1].strip).to eq("Glicose GOD-PAP,total,5,100,\"-95,0\"")
    expect(response.body.lines[2].strip).to eq("Glicose GOD-PAP,#{s.instrument.name},5,,")
    get "/lab/inventory/consumption", params: { provider_id: s.provider.id, month: "2026-13" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_month" ])
  end

  it "item sem abertura no mês: tests_opened e desvio nulos, sem divisão por zero" do
    supply
    type!(received_requisition!(provider: s.provider, exams: [ s.exam ]).items.first, { glicose: "98" })
    sign_in_as(staff)
    expect(total(rows)).to include("tests_performed" => 1, "tests_opened" => nil, "deviation_pct" => nil)
  end

  it "o desvio é positivo quando se realiza mais do que as aberturas rendem" do
    small = LabSupply.create!(exam_provider: s.provider, name: "Glicose pequeno", kind: "reagent", unit: "kit", tests_per_package: 2,
                              minimum_stock: 0, expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
    open!(lot!(supply: small, number: "P1"))
    3.times { type!(received_requisition!(provider: s.provider, exams: [ s.exam ]).items.first, { glicose: "98" }) }
    sign_in_as(staff)
    expect(total(rows)).to include("tests_performed" => 3, "tests_opened" => 2, "deviation_pct" => 50.0)
  end

  it "exame calculado não conta: a entrada de colesterol com LDL calculado é um teste só" do
    lipid = qc_exam!(provider: s.provider, instrument: s.instrument, sigtap_code: "0202010295", name: "Perfil lipídico",
                     analytes: LabHelpers::LIPIDS, instrument_test_code: "LIP")
    LabSupply.create!(exam_provider: s.provider, name: "Lipídeos", kind: "reagent", unit: "kit", tests_per_package: 50, minimum_stock: 0,
                      expiry_alert_days: 30, lab_exam_ids: [ lipid.id ])
    item = received_requisition!(provider: s.provider, exams: [ lipid ]).items.first
    type!(item, { ct: "200", hdl: "50", tg: "100" })
    expect(item.results.where(analyte_key: "ldl")).to exist # o calculado foi gravado
    sign_in_as(staff)
    all = rows
    lipid_total = all.find { |r| r["name"] == "Lipídeos" && r["instrument_id"].nil? }
    expect(lipid_total["tests_performed"]).to eq(1)
  end

  it "bordas do período: o primeiro instante do mês entra, o primeiro do seguinte não; aberturas também" do
    lot = lot!
    item_in, item_next, item_before = Array.new(3) { received_requisition!(provider: s.provider, exams: [ s.exam ]).items.first }
    april = Time.zone.local(2026, 4, 1, 0, 0, 0)
    travel_to(april - 1.second) { type!(item_before, { glicose: "98" }); open!(lot) }
    travel_to(april) { type!(item_in, { glicose: "98" }); open!(lot) }
    travel_to(Time.zone.local(2026, 4, 30, 23, 59, 59)) { type!(item_in, { glicose: "99" }); qc_value!(s, "Nível 1", 0, by: staff, now: Time.current) }
    travel_to(Time.zone.local(2026, 5, 1, 0, 0, 0)) { type!(item_next, { glicose: "98" }); open!(lot); qc_value!(s, "Nível 2", 0, by: staff, now: Time.current) }
    sign_in_as(staff)
    expect(total(rows("2026-04"))).to include("tests_performed" => 3, "tests_opened" => 100)
    expect(total(rows("2026-03"))).to include("tests_performed" => 1, "tests_opened" => 100)
    expect(total(rows("2026-05"))).to include("tests_performed" => 2, "tests_opened" => 100)
  end

  it "controles contam um por nível e corrida, e só de analitos ligados ao exame do item" do
    other_exam = qc_exam!(provider: s.provider, instrument: s.instrument, sigtap_code: "0202010295", name: "Outro", instrument_test_code: "OUT")
    supply
    sign_in_as(staff)
    qc_value!(s, "Nível 1", 0, by: staff)
    qc_value!(s, "Nível 1", 0.2, by: staff, now: Time.current + 1.minute)
    qc_value!(s, "Nível 2", 0, by: staff)
    expect(other_exam).to be_present
    expect(total(rows)).to include("tests_performed" => 3)
  end

  it "só entra item reagente do laboratório da consulta; sem item, a lista é vazia" do
    LabSupply.create!(exam_provider: s.provider, name: "Calibrador", kind: "calibrator", unit: "frasco", minimum_stock: 0, expiry_alert_days: 30,
                      lab_exam_ids: [ s.exam.id ])
    sign_in_as(staff)
    expect(rows).to eq([])
  end

  it "mês malformado: 422 invalid_month; laboratório alheio: 403; sem sessão: 401" do
    supply
    get "/lab/inventory/consumption", params: { provider_id: s.provider.id, month: month_of(Time.zone.today) }
    expect(response).to have_http_status(:unauthorized)
    sign_in_as(staff)
    [ nil, "", "2026-00", "2026-13", "2026-4", "2026-04-01", "abril" ].each do |bad|
      get "/lab/inventory/consumption", params: { provider_id: s.provider.id, month: bad }
      expect([ bad, response.status, json_body["error"] ]).to eq([ bad, 422, "invalid_month" ])
    end
    outsider = lab_releaser!(lab_provider!, lead: true)
    sign_in_as(outsider)
    get "/lab/inventory/consumption", params: { provider_id: s.provider.id, month: month_of(Time.zone.today) }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    get "/lab/inventory/consumption.csv", params: { provider_id: s.provider.id, month: month_of(Time.zone.today) }
    expect(response).to have_http_status(:forbidden)
  end
end
