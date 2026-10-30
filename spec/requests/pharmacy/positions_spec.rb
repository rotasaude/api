require "rails_helper"

# Módulo 27a, Task 8 (ADR 0045; contrato §4, §9 e H10/H12): posição, extrato do
# lote e alertas. Leitura SEM trilha e sem dado pessoal: o almoxarife do central
# lê todos os locais; os demais, os seus (local sem papel → 403); lote ou local
# inexistente nunca vira 500; todo 422 traz `problems`. O "hoje" é o da cidade.
RSpec.describe "Farmácia — posição, extrato e alertas", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:losartana) { catalog_item(268_856) }
  let(:amoxicilina) { catalog_item(271_089) }
  let(:central_keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:today) { Time.zone.today }

  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def disable_pharmacy! = Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
  def events = DomainEvent.order(:occurred_at, :id).pluck(:name, :payload)
  def settings = Pharmacy::Settings.current

  def lot_json(lot, item = paracetamol)
    { "id" => lot.id,
      "item" => { "catalog_item_id" => item.id, "catmat_code" => item.catmat_code, "name" => item.label, "unit" => item.unit,
                  "dispensing_unit" => "comprimido", "controlled" => false, "controlled_list" => nil },
      "lot_number" => lot.lot_number, "expires_on" => lot.expires_on.iso8601, "manufacturer" => lot.manufacturer }
  end

  def location_json(location, unit_record = nil)
    { "id" => location.id, "name" => location.name, "kind" => location.kind, "active" => true,
      "health_unit" => unit_record && { "id" => unit_record.id, "name" => unit_record.name } }
  end

  def positions(params = {}, as: central_keeper, **query)
    sign_in_as(as)
    get "/pharmacy/positions", params: params.merge(query)
    json_body
  end

  def keys_of(body) = body.fetch("positions").map { |row| [ row.dig("location", "id"), row.dig("item", "catalog_item_id") ] }

  def send_to_unit!(*lines, to: farmacia)
    result = Pharmacy::SendTransfer.call(from: central, to: to, items: lines.map { |lot, quantity| { "lot_id" => lot.id, "quantity" => quantity } },
                                         by: pharmacy_staff!(central, "stock_keeper"), now: Time.current)
    raise result.inspect if result.failure?

    result.payload.fetch(:transfer)
  end

  def adjust!(location, lot, by:, **attrs)
    result = Pharmacy::RequestAdjustment.call(**{ location: location, lot: lot, kind: "adjustment", counted_quantity: nil, quantity: nil,
                                                  reason: "Contagem do inventário de outubro", by: by, settings: settings }.merge(attrs))
    raise result.inspect if result.failure?

    result.payload.fetch(:adjustment)
  end

  # Retirada gravada crua (a dispensação da Task 11 ainda não existe): receita
  # externa, dispensação, item e o movimento `dispensing`.
  def dispense!(location, lot, quantity, by:, at: Time.current)
    patient = registry_patient!
    external = ExternalPrescription.create!(patient: patient, stock_location: location, prescriber_name: "Dra. Beltrana", council: "CRM",
                                            council_state: "PR", council_number: "12345", issued_on: today, recorded_by_user: by)
    prescription_item = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: lot.catalog_item_id,
                                                         catmat_code: lot.catmat_code, quantity: quantity, quantity_unit: "comprimido",
                                                         dosage_instructions: "1 comprimido ao dia")
    dispensation = Dispensation.create!(stock_location: location, patient: patient, external_prescription: external, dispensed_by_user: by,
                                        dispensed_by_role: "pharmacist", dispensed_at: Time.current)
    item = DispensationItem.create!(dispensation: dispensation, external_prescription_item: prescription_item, stock_lot: lot,
                                    catalog_item_id: lot.catalog_item_id, quantity: quantity)
    movement = Pharmacy::Ledger.record!(location: location, lot: lot, kind: "dispensing", quantity: BigDecimal(quantity.to_s), by: by, document: item, at: at)
    [ dispensation, patient, movement ]
  end

  describe "GET /pharmacy/positions" do
    let!(:lot_a) { stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "A-1", expires_on: today + 60) }
    let!(:lot_b) { stocked_lot!(central, item: paracetamol, quantity: "30", lot_number: "A-2", expires_on: today + 300) }
    let!(:lot_c) { stocked_lot!(central, item: losartana, quantity: "10", lot_number: "C-1", expires_on: today + 300) }

    it "o almoxarife do central vê todos os locais sem location_id: forma <position> completa, com as marcas por lote" do
      send_to_unit!([ lot_a, "40" ])
      body = positions
      expect(body.keys).to eq(%w[positions next_before])
      expect(body["next_before"]).to be_nil
      expect(keys_of(body)).to match_array([ [ central.id, paracetamol.id ], [ central.id, losartana.id ], [ farmacia.id, paracetamol.id ] ])

      row = body["positions"].find { |position| position.dig("location", "id") == central.id && position.dig("item", "catalog_item_id") == paracetamol.id }
      expect(row).to eq(
        "location" => location_json(central), "item" => lot_json(lot_a)["item"], "balance" => "50.00", "minimum" => nil,
        "below_minimum" => false, "expiring_soon" => true,
        "lots" => [ { "lot" => lot_json(lot_a), "balance" => "20.00", "in_transit" => "0.00", "expiring_soon" => true, "expired" => false },
                    { "lot" => lot_json(lot_b), "balance" => "30.00", "in_transit" => "0.00", "expiring_soon" => false, "expired" => false } ]
      )
      arriving = body["positions"].find { |position| position.dig("location", "id") == farmacia.id }
      expect(arriving).to include("balance" => "0.00", "location" => location_json(farmacia, unit))
      expect(arriving["lots"]).to eq([ { "lot" => lot_json(lot_a), "balance" => "0.00", "in_transit" => "40.00", "expiring_soon" => true, "expired" => false } ])
    end

    it "lote vencido: expired true e expiring_soon false no lote, e a posição entra em expiring_soon" do
      stocked_lot!(central, item: amoxicilina, quantity: "12", lot_number: "OLD", expires_on: today - 3)
      body = positions(location_id: central.id, catalog_item_id: amoxicilina.id)
      expect(body["positions"].sole).to include("expiring_soon" => true, "balance" => "12.00")
      expect(body["positions"].sole["lots"].sole).to include("expired" => true, "expiring_soon" => false, "balance" => "12.00")
    end

    it "a farmacêutica da UBS sem location_id vê só o local dela; com o location_id do central → 403 missing_role" do
      stocked_lot!(farmacia, item: amoxicilina, quantity: "7", lot_number: "UBS-1")
      body = positions({}, as: pharmacist)
      expect(keys_of(body)).to eq([ [ farmacia.id, amoxicilina.id ] ])

      get "/pharmacy/positions", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/pharmacy/positions", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:ok)
      expect(keys_of(json_body)).to eq([ [ farmacia.id, amoxicilina.id ] ])
    end

    it "qualquer papel do local lê (auxiliar), e o almoxarife do central lê um local de unidade com location_id" do
      stocked_lot!(farmacia, item: amoxicilina, quantity: "7", lot_number: "UBS-1")
      expect(keys_of(positions({ location_id: farmacia.id }, as: assistant))).to eq([ [ farmacia.id, amoxicilina.id ] ])
      expect(keys_of(positions({ location_id: farmacia.id }, as: central_keeper))).to eq([ [ farmacia.id, amoxicilina.id ] ])
    end

    it "usuário sem papel em local nenhum → 403, com ou sem location_id; Membership revogada com vínculo ativo → 403" do
      sign_in_as(staff_with("sem-papel@cidade.gov.br"))
      get "/pharmacy/positions"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/pharmacy/positions", params: { location_id: central.id }
      expect(response).to have_http_status(:forbidden)

      revoked = pharmacy_staff!(farmacia, "pharmacist")
      revoked.memberships.find_by!(role: "pharmacist").revoke!
      sign_in_as(revoked)
      get "/pharmacy/positions", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:forbidden)
    end

    it "location_id que não é uuid ou não existe → 422 com problems (nunca 500)" do
      sign_in_as(central_keeper)
      [ "lixo", SecureRandom.uuid, "" ].each do |value|
        get "/pharmacy/positions", params: { location_id: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      end
    end

    it "expiring=false e below_minimum=false contam como ausentes; =true filtra; outro valor → 422" do
      StockMinimum.create!(stock_location: central, catalog_item_id: losartana.id, minimum: 50, updated_by_user: central_keeper)
      stocked_lot!(central, item: amoxicilina, quantity: "9", lot_number: "OLD", expires_on: today - 3)
      all = keys_of(positions)

      expect(keys_of(positions(expiring: "false", below_minimum: "false"))).to eq(all)
      expect(keys_of(positions(expiring: "false"))).to eq(all)
      expect(keys_of(positions(expiring: "true"))).to match_array([ [ central.id, paracetamol.id ], [ central.id, amoxicilina.id ] ])
      expect(keys_of(positions(below_minimum: "true"))).to eq([ [ central.id, losartana.id ] ])
      expect(keys_of(positions(expiring: "true", below_minimum: "true"))).to eq([])

      %w[1 yes TRUE sim].each do |value|
        get "/pharmacy/positions", params: { expiring: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "expiring") ])
      end
      get "/pharmacy/positions", params: { below_minimum: "talvez" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "below_minimum") ])
      get "/pharmacy/positions", params: { expiring: [ "true" ] }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "catalog_item_id restringe ao item; o que não é uuid → 422 invalid_request com path" do
      expect(keys_of(positions(catalog_item_id: losartana.id))).to eq([ [ central.id, losartana.id ] ])
      expect(positions(catalog_item_id: SecureRandom.uuid)).to eq("positions" => [], "next_before" => nil)
      get "/pharmacy/positions", params: { catalog_item_id: "lixo" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "catalog_item_id") ])
    end

    it "q (2+ caracteres) vira ids pela busca do catálogo antes da consulta" do
      expect(keys_of(positions(q: "paracetamol"))).to eq([ [ central.id, paracetamol.id ] ])
      expect(keys_of(positions(q: "losartana"))).to eq([ [ central.id, losartana.id ] ])
      expect(positions(q: "zzzzinexistente")).to eq("positions" => [], "next_before" => nil)
      expect(positions(q: "paracetamol", catalog_item_id: losartana.id)).to eq("positions" => [], "next_before" => nil)
      expect(keys_of(positions(q: "paracetamol", catalog_item_id: paracetamol.id))).to eq([ [ central.id, paracetamol.id ] ])
      expect(keys_of(positions(q: "  "))).to match_array([ [ central.id, paracetamol.id ], [ central.id, losartana.id ] ])
    end

    it "q com 1 caractere, acima de 60 ou que não é texto → 422 com path q" do
      sign_in_as(central_keeper)
      [ "p", "x" * 61 ].each do |value|
        get "/pharmacy/positions", params: { q: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "q") ])
      end
      get "/pharmacy/positions", params: { q: [ "paracetamol" ] }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "q acha TODAS as 31 apresentações do mesmo princípio ativo com saldo (sem o limite de 30 da busca do catálogo); sem posição não aparece" do
      release = MedicationCatalogRelease.current
      items = (1..32).map do |n|
        MedicationCatalogItem.create!(catmat_code: 9_800_000 + n, active_ingredient: "ZETAMICINA", strength: "#{n} mg", dosage_form: "COMPRIMIDO",
                                      unit: "mg", source_description: "ZETAMICINA #{n} mg", search_text: "ZETAMICINA #{n} MG COMPRIMIDO",
                                      parse_status: "ok", first_release_id: release.id, last_release_id: release.id)
      end
      items.first(31).each_with_index { |item, index| stocked_lot!(central, item: item, quantity: "5", lot_number: "ZETA-#{index}") }

      body = positions(q: "zetamicina", limit: 100)
      expect(body["positions"].map { |row| row.dig("item", "catalog_item_id") }).to match_array(items.first(31).map(&:id))
      expect(Medications::Search.call(q: "zetamicina").size).to eq(30)
      expect(keys_of(positions(q: "zetamicina 31 mg"))).to eq([ [ central.id, items[30].id ] ])
    end

    it "q acha item escondido do catálogo que ainda tem saldo (a busca de receita não o mostra)" do
      hidden = catalog_item(271_089)
      stocked_lot!(central, item: hidden, quantity: "8", lot_number: "HID-1")
      hidden.update!(hidden: true)
      expect(Medications::Search.call(q: "amoxicilina").map { |hit| hit.fetch(:id) }).not_to include(hidden.id)

      expect(keys_of(positions(q: "amoxicilina"))).to eq([ [ central.id, hidden.id ] ])
    end

    it "paginação com limit=1 e cursor opaco: cada página traz um item, sem repetir, na ordem (local, item)" do
      send_to_unit!([ lot_a, "10" ])
      expected = [ [ central.id, paracetamol.id ], [ central.id, losartana.id ], [ farmacia.id, paracetamol.id ] ].sort
      seen = []
      token = nil
      4.times do
        body = positions({ limit: 1, before: token }.compact)
        seen.concat(keys_of(body))
        token = body["next_before"]
        break unless token

        expect(token).to be_a(String)
        expect(Pharmacy::Cursor.decode(token)).to eq(keys_of(body).last)
      end
      expect(token).to be_nil
      expect(seen).to eq(expected)
    end

    it "before inválido → 422 invalid_cursor com problems (texto solto, não-uuid, lista errada); limit inválido → invalid_limit" do
      sign_in_as(central_keeper)
      [ "lixo", Pharmacy::Cursor.encode([ "a", "b" ]), Pharmacy::Cursor.encode([ central.id ]), Pharmacy::Cursor.encode([ central.id, "x" ]), "" ].each do |value|
        get "/pharmacy/positions", params: { before: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cursor", "before") ])
      end
      %w[0 101 abc].each do |value|
        get "/pharmacy/positions", params: { limit: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_limit", "limit") ])
      end
    end

    it "chave desconhecida na query → 422 invalid_request com o path dela" do
      sign_in_as(central_keeper)
      get "/pharmacy/positions", params: { cpf: "123" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
    end

    it "sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      get "/pharmacy/positions"
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(central_keeper)
      disable_pharmacy!
      get "/pharmacy/positions"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end

    it "leitura sem trilha: nenhum evento (clinical_record.viewed incluído) por posição, extrato ou alertas" do
      sign_in_as(central_keeper)
      before = events
      get "/pharmacy/positions"
      get "/pharmacy/lots/#{lot_a.id}/movements", params: { location_id: central.id }
      get "/pharmacy/alerts", params: { location_id: central.id }
      expect(response).to have_http_status(:ok)
      expect(events).to eq(before)
      expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty
    end
  end

  describe "GET /pharmacy/lots/:id/movements" do
    let!(:lot) { stocked_lot!(farmacia, item: paracetamol, quantity: "30", lot_number: "X-1", expires_on: today + 200) }

    def statement(lot_id, params = {}, as: pharmacist, **query)
      sign_in_as(as)
      get "/pharmacy/lots/#{lot_id}/movements", params: params.merge(query)
      json_body
    end

    it "extrato de lote dispensado: document { type: dispensation, id } e o corpo não traz paciente, CPF nem receita" do
      dispensation, patient = dispense!(farmacia, lot, 5, by: pharmacist)
      body = statement(lot.id, location_id: farmacia.id)
      expect(response).to have_http_status(:ok)
      expect(body.keys).to eq(%w[lot balance movements next_before])
      expect(body["lot"]).to eq(lot_json(lot))
      expect(body["balance"]).to eq("25.00")
      expect(body["movements"].map { |row| row["kind"] }).to eq(%w[dispensing opening])

      row = body["movements"].first
      expect(row).to eq("id" => StockMovement.find_by!(kind: "dispensing").id, "kind" => "dispensing", "quantity" => "-5.00", "reason" => nil,
                        "at" => StockMovement.find_by!(kind: "dispensing").recorded_at.iso8601,
                        "by" => { "name" => pharmacist.professional.professional_name },
                        "document" => { "type" => "dispensation", "id" => dispensation.id, "number" => nil })
      raw = response.body
      [ patient.full_name, patient.mother_name, patient.cpf, patient.id, "Dra. Beltrana", "Beltrana", "ExternalPrescription", "comprimido ao dia" ].each do |secret|
        expect(raw).not_to include(secret.to_s)
      end
      expect(body["movements"].flat_map { |movement| movement.keys }.uniq).to match_array(%w[id kind quantity reason at by document])
    end

    it "cada documento: entrada com número, transferência, ajuste e perda; o motivo só vem no corpo e só onde existe" do
      central_lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "X-2")
      transfer = send_to_unit!([ central_lot, "20" ])
      Pharmacy::ReceiveTransfer.call(transfer: transfer, items: [ { "lot_id" => central_lot.id, "quantity_received" => "18",
                                                                     "reason" => "Duas caixas chegaram molhadas" } ], by: pharmacist, now: Time.current)
      adjustment = adjust!(farmacia, central_lot, by: pharmacy_staff!(farmacia, "stock_keeper"), kind: "loss", quantity: "3",
                                                  reason: "Frascos quebrados no armário")

      rows = statement(central_lot.id, { location_id: farmacia.id })["movements"]
      expect(rows.map { |row| [ row["kind"], row["quantity"], row.dig("document", "type") ] }).to eq(
        [ [ "loss", "-3.00", "adjustment" ], [ "loss", "-2.00", "transfer" ], [ "transfer_in", "20.00", "transfer" ] ]
      )
      expect(rows.map { |row| row["reason"] }).to eq([ "Frascos quebrados no armário", "Duas caixas chegaram molhadas", nil ])
      expect(rows.first["document"]).to eq("type" => "adjustment", "id" => adjustment.id, "number" => nil)
      expect(rows.second["document"]).to eq("type" => "transfer", "id" => transfer.id, "number" => nil)

      entry_rows = statement(central_lot.id, { location_id: central.id }, as: central_keeper)["movements"]
      entry = StockEntry.find_by!(stock_location_id: central.id)
      expect(entry_rows.map { |row| row["kind"] }).to eq(%w[transfer_out opening])
      expect(entry_rows.last["document"]).to eq("type" => "entry", "id" => entry.id, "number" => nil)
      invoice = stocked_lot!(central, item: paracetamol, quantity: "5", lot_number: "X-2", expires_on: central_lot.expires_on)
      newest = statement(invoice.id, { location_id: central.id }, as: central_keeper)["movements"].first
      expect(newest["document"]).to eq("type" => "entry", "id" => StockEntry.where(kind: "invoice").sole.id, "number" => StockEntry.where(kind: "invoice").sole.document_number)
    end

    it "by.name vem do perfil profissional; quem não tem perfil (almoxarife) vai com name null" do
      body = statement(lot.id, location_id: farmacia.id)
      expect(body["movements"].last["by"]).to eq("name" => nil)
      adjust!(farmacia, lot, by: pharmacist, kind: "loss", quantity: "1", reason: "Frasco quebrado na prateleira")
      expect(statement(lot.id, { location_id: farmacia.id })["movements"].first["by"]).to eq("name" => pharmacist.professional.professional_name)
    end

    it "a ordem é a da data do movimento (recorded_at), não a da gravação: lote vencido entra retroativo e a baixa de hoje vem primeiro" do
      old = stocked_lot!(central, item: losartana, quantity: "20", lot_number: "OLD", expires_on: today - 10)
      expect(StockMovement.find_by!(stock_lot_id: old.id).recorded_at.to_date).to eq(today - 10)
      adjust!(central, old, by: central_keeper, kind: "expiry", quantity: "20", reason: "Lote vencido descartado")
      rows = statement(old.id, { location_id: central.id }, as: central_keeper)["movements"]
      expect(rows.map { |row| row["kind"] }).to eq(%w[expiry opening])

      # Gravado DEPOIS, mas com data ANTERIOR: o extrato o põe por último.
      fresh = stocked_lot!(central, item: amoxicilina, quantity: "40", lot_number: "ORD")
      later = dispense!(central, fresh, 1, by: central_keeper, at: 2.days.ago).last
      rows = statement(fresh.id, { location_id: central.id }, as: central_keeper)["movements"]
      expect(rows.map { |row| row["kind"] }).to eq(%w[opening dispensing])
      expect(rows.last["id"]).to eq(later.id)
    end

    it "paginação com limit=1 e before: sem repetir; before inválido → 422 invalid_cursor" do
      adjust!(farmacia, lot, by: pharmacist, kind: "loss", quantity: "1", reason: "Frasco quebrado na prateleira")
      adjust!(farmacia, lot, by: pharmacist, kind: "loss", quantity: "2", reason: "Frascos molhados na enchente")
      first = statement(lot.id, { location_id: farmacia.id, limit: 1 })
      expect(first["movements"].map { |row| row["quantity"] }).to eq([ "-2.00" ])
      expect(first["next_before"]).to be_present
      second = statement(lot.id, { location_id: farmacia.id, limit: 1, before: first["next_before"] })
      expect(second["movements"].map { |row| row["quantity"] }).to eq([ "-1.00" ])
      third = statement(lot.id, { location_id: farmacia.id, limit: 5, before: second["next_before"] })
      expect(third["movements"].map { |row| row["kind"] }).to eq([ "opening" ])
      expect(third["next_before"]).to be_nil

      [ "lixo", Pharmacy::Cursor.encode([ "2026-01-01T00:00:00Z", "x" ]), Pharmacy::Cursor.encode([ "nao-e-data", "2026-01-01T00:00:00Z", SecureRandom.uuid ]),
         Pharmacy::Cursor.encode([ "2026-01-01T00:00:00Z", SecureRandom.uuid ]), Pharmacy::Cursor.encode([ "2026-01-01T00:00:00Z", "nao-e-data", SecureRandom.uuid ]) ].each do |value|
        get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: farmacia.id, before: value }
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cursor", "before") ])
      end
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: farmacia.id, limit: 0 }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_limit", "limit") ])
    end

    it "paginação com limit=1 atravessa o par transfer_in/loss gravado no mesmo instante: o cursor de 3 partes desempata por id, sem repetir nem pular" do
      central_lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "TIE-1")
      transfer = send_to_unit!([ central_lot, "20" ])
      travel_to(Time.zone.now.change(usec: 0)) do
        Pharmacy::ReceiveTransfer.call(transfer: transfer, items: [ { "lot_id" => central_lot.id, "quantity_received" => "18",
                                                                       "reason" => "Duas caixas chegaram molhadas" } ], by: pharmacist, now: Time.current)
      end
      pair = StockMovement.where(stock_location_id: farmacia.id, stock_lot_id: central_lot.id).to_a
      expect(pair.map(&:kind)).to match_array(%w[transfer_in loss])
      expect(pair.map(&:created_at).uniq.size).to eq(1)
      expect(pair.map(&:recorded_at).uniq.size).to eq(1)

      seen = []
      token = nil
      3.times do
        body = statement(central_lot.id, { location_id: farmacia.id, limit: 1, before: token }.compact)
        seen.concat(body["movements"].map { |row| row["id"] })
        token = body["next_before"]
        break unless token
      end
      expect(token).to be_nil
      expect(seen).to eq(pair.map(&:id).sort.reverse)
    end

    it "location_id obrigatório (422) e do usuário (403); o almoxarife do central lê o extrato de qualquer local" do
      sign_in_as(pharmacist)
      get "/pharmacy/lots/#{lot.id}/movements"
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(statement(lot.id, { location_id: farmacia.id }, as: central_keeper)["movements"].size).to eq(1)
      expect(statement(lot.id, { location_id: farmacia.id }, as: assistant)["movements"].size).to eq(1)
      sign_in_as(staff_with("sem-papel@cidade.gov.br"))
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:forbidden)
    end

    it "lote inexistente, que não é uuid ou que o local não conhece → 404; lote em trânsito para o local → 200 sem movimentos" do
      sign_in_as(pharmacist)
      [ SecureRandom.uuid, "lixo" ].each do |id|
        get "/pharmacy/lots/#{id}/movements", params: { location_id: farmacia.id }
        expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      end
      central_lot = stocked_lot!(central, item: losartana, quantity: "9", lot_number: "ALHEIO")
      get "/pharmacy/lots/#{central_lot.id}/movements", params: { location_id: farmacia.id }
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

      send_to_unit!([ central_lot, "4" ])
      get "/pharmacy/lots/#{central_lot.id}/movements", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("movements" => [], "balance" => "0.00", "next_before" => nil)
    end

    it "chave desconhecida na query → 422; sem sessão → 401; interruptor desligado → 403" do
      sign_in_as(pharmacist)
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: farmacia.id, cpf: "1" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      disable_pharmacy!
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: farmacia.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end

  describe "o \"hoje\" é o da cidade (America/Sao_Paulo, fora do UTC)" do
    let(:stock_keeper) { pharmacy_staff!(farmacia, "stock_keeper") }

    # 29/10 22:00 em São Paulo já é 30/10 01:00 em UTC.
    it "na virada do dia em UTC o lote que vence 'hoje' (29/10) não está vencido: posição e alertas contam vencendo, não vencido" do
      travel_to(Time.utc(2026, 10, 30, 1, 0, 0)) do
        expect(Time.zone.today).to eq(Date.new(2026, 10, 29))
        expect(Time.now.utc.to_date).to eq(Date.new(2026, 10, 30))
        stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "HOJE", expires_on: Date.new(2026, 10, 29))
        stocked_lot!(farmacia, item: losartana, quantity: "10", lot_number: "ONTEM", expires_on: Date.new(2026, 10, 28))

        body = positions({ location_id: farmacia.id }, as: pharmacist)
        flags = body["positions"].flat_map { |row| row["lots"] }.to_h { |row| [ row.dig("lot", "lot_number"), row.values_at("expiring_soon", "expired") ] }
        expect(flags).to eq("HOJE" => [ true, false ], "ONTEM" => [ false, true ])

        sign_in_as(pharmacist)
        get "/pharmacy/alerts", params: { location_id: farmacia.id }
        expect(json_body).to include("expiring" => 1, "expired" => 1)
      end
    end

    it "na outra ponta (28/10 23:00 em São Paulo, já 29/10 em UTC) o lote de 28/10 ainda não venceu" do
      travel_to(Time.utc(2026, 10, 29, 2, 0, 0)) do
        expect(Time.zone.today).to eq(Date.new(2026, 10, 28))
        stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "HOJE", expires_on: Date.new(2026, 10, 28))

        row = positions({ location_id: farmacia.id }, as: pharmacist)["positions"].sole["lots"].sole
        expect(row.values_at("expiring_soon", "expired")).to eq([ true, false ])
        sign_in_as(pharmacist)
        get "/pharmacy/alerts", params: { location_id: farmacia.id }
        expect(json_body).to include("expiring" => 1, "expired" => 0)
      end
    end
  end

  describe "GET /pharmacy/alerts" do
    let(:stock_keeper) { pharmacy_staff!(farmacia, "stock_keeper") }

    def alerts(params = { location_id: farmacia.id }, as: pharmacist)
      sign_in_as(as)
      get "/pharmacy/alerts", params: params
      json_body
    end

    it "as cinco contagens: expiring NÃO inclui os vencidos, lote sem saldo não conta, mínimo conta item sem movimento" do
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "V-30", expires_on: today + 30)
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "V-HOJE", expires_on: today)
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "V-200", expires_on: today + 200)
      stocked_lot!(farmacia, item: losartana, quantity: "10", lot_number: "V-VENCIDO", expires_on: today - 1)
      empty = stocked_lot!(farmacia, item: amoxicilina, quantity: "5", lot_number: "V-ZERO", expires_on: today + 10)
      adjust!(farmacia, empty, by: stock_keeper, kind: "loss", quantity: "5", reason: "Frascos quebrados no armário")
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: paracetamol.id, minimum: 100, updated_by_user: stock_keeper)
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: losartana.id, minimum: 5, updated_by_user: stock_keeper)
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: amoxicilina.id, minimum: 1, updated_by_user: stock_keeper)
      central_lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "C-1")
      send_to_unit!([ central_lot, "10" ])
      send_to_unit!([ central_lot, "5" ])
      pending = stocked_lot!(farmacia, item: losartana, quantity: "100", lot_number: "V-CONT", expires_on: today + 400)
      adjust!(farmacia, pending, by: stock_keeper, counted_quantity: "50")
      received = send_to_unit!([ central_lot, "3" ])
      Pharmacy::ReceiveTransfer.call(transfer: received, items: [ { "lot_id" => central_lot.id, "quantity_received" => "3" } ], by: pharmacist, now: Time.current)

      body = alerts
      expect(body).to eq("expiring" => 2, "expired" => 1, "below_minimum" => 2, "in_transit" => 2, "pending_adjustments" => 1)
      expect(body.values).to all(be_an(Integer))
      expect(body.keys).to eq(%w[expiring expired below_minimum in_transit pending_adjustments])
    end

    it "as contagens são do local pedido: o central não herda o que é da UBS" do
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "V-30", expires_on: today + 30)
      central_lot = stocked_lot!(central, item: losartana, quantity: "10", lot_number: "C-OLD", expires_on: today - 5)
      expect(alerts({ location_id: central.id }, as: central_keeper)).to eq("expiring" => 0, "expired" => 1, "below_minimum" => 0, "in_transit" => 0,
                                                                              "pending_adjustments" => 0)
      expect(alerts({ location_id: farmacia.id }, as: central_keeper)).to include("expiring" => 1, "expired" => 0)
      expect(central_lot).to be_present
    end

    it "a contagem de abaixo do mínimo bate com o filtro da posição" do
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "M-1")
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: paracetamol.id, minimum: 11, updated_by_user: stock_keeper)
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: amoxicilina.id, minimum: 2, updated_by_user: stock_keeper)
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: losartana.id, minimum: 0, updated_by_user: stock_keeper)
      count = alerts["below_minimum"]
      expect(count).to eq(2)
      expect(positions({ location_id: farmacia.id, below_minimum: "true" }, as: pharmacist)["positions"].size).to eq(count)
    end

    it "o parâmetro expiry_alert_days da cidade vale (30 dias deixa de contar o lote de 60)" do
      stocked_lot!(farmacia, item: paracetamol, quantity: "10", lot_number: "V-60", expires_on: today + 60)
      expect(alerts["expiring"]).to eq(1)
      PharmacySetting.where(id: 1).update_all(expiry_alert_days: 30)
      expect(alerts["expiring"]).to eq(0)
    end

    it "local sem lote nenhum: tudo zero; location_id obrigatório (422), inexistente (422) e do usuário (403)" do
      expect(alerts).to eq("expiring" => 0, "expired" => 0, "below_minimum" => 0, "in_transit" => 0, "pending_adjustments" => 0)
      sign_in_as(pharmacist)
      get "/pharmacy/alerts"
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      get "/pharmacy/alerts", params: { location_id: SecureRandom.uuid }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      get "/pharmacy/alerts", params: { location_id: central.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(staff_with("sem-papel@cidade.gov.br"))
      get "/pharmacy/alerts", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:forbidden)
    end

    it "auxiliar e almoxarife do local leem; chave desconhecida → 422; sem sessão → 401; interruptor desligado → 403" do
      expect(alerts({ location_id: farmacia.id }, as: assistant)).to include("expiring" => 0)
      expect(alerts({ location_id: farmacia.id }, as: stock_keeper)).to include("expiring" => 0)
      get "/pharmacy/alerts", params: { location_id: farmacia.id, q: "x" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "q") ])
      disable_pharmacy!
      get "/pharmacy/alerts", params: { location_id: farmacia.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
      reset!
      host! test_city_host
      get "/pharmacy/alerts", params: { location_id: farmacia.id }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
