require "rails_helper"

# Módulo 32b (ADR 0050; contrato §5 e §12 Q2, Q5; plano, Desvios 5, 7, 10 e
# 11): GET /urgency/encounters/:id/medication_schedule — o aprazamento da
# prescrição ativa, calculado na leitura. Lê quem checa a medicação na UPA
# (2235*, 3222*, 225*); grava a trilha `medication_schedule`; traz a última
# administração por item (qualquer versão), `stock_deduction` e, com ele, os
# lotes em FEFO do local `unit` da UPA.
RSpec.describe "Urgência — aprazamento da medicação", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  let(:nurse) { observation_nurse!(upa) }
  let(:technician) { upa_nurse!(upa, cbo: "322205") }
  let!(:catalog) { import_test_catalog! }
  let(:losartana) { catalog_item(268_856) }
  let(:encounter) { in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) } }
  let(:trail) { DomainEvent.where(name: "clinical_record.viewed") }
  before { ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  def item(catalog_item = losartana, **over)
    { catalog_item_id: catalog_item.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
  end

  def issue!(target = encounter, items = [ item ])
    result = Urgency::IssuePrescription.call(encounter: target, items: items.map(&:deep_stringify_keys), by: doctor,
                                             catalog: { losartana.id => losartana, catalog_item(267_197).id => catalog_item(267_197) })
    raise "issue! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:prescription)
  end

  def schedule(target = encounter, **params) = get("/urgency/encounters/#{target.id}/medication_schedule", params: params)

  def administer!(row, status: "administered", at: Time.current, lot: nil, quantity: nil, by: nurse)
    link = Urgency::Access.nursing_or_physician_link(by, upa.id)
    attrs = { urgency_prescription_item: row, urgency_encounter: row.urgency_prescription.urgency_encounter, status: status, scheduled_at: at.change(sec: 0),
              recorded_by_user: by, professional_link: link, cbo_code: link.cbo_code, recorded_at: Time.current, stock_lot: lot, stock_quantity: quantity }
    if status == "administered"
      attrs[:administered_at] = at
    else
      attrs[:reason] = "Paciente em jejum para exame"
    end
    UrgencyAdministration.create!(attrs)
  end

  describe "leitura" do
    it "o técnico 3222 lê, a trilha medication_schedule é gravada e a query só aceita o nome da chave" do
      v1 = issue!
      sign_in_as(technician)
      expect { schedule }.to change { trail.count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(trail.last.payload).to include("resource" => "medication_schedule", "access" => "urgency", "user_id" => technician.id)
      expect(json_body).to include("prescription_id" => v1.id, "version" => 1, "stock_deduction" => false)
      row = json_body["items"].sole
      expect(row).to include("item_id" => v1.items.first.id, "dose" => "50", "dose_unit" => "mg", "route" => "oral", "recent" => nil, "remaining" => nil,
                             "last_administration" => nil)
      expect(row["catalog_item"]).to include("catalog_item_id" => losartana.id)
      expect(row["slots"]).not_to be_empty
      expect(row["slots"].first).to include("administration" => nil)
      expect(row).not_to have_key("lots")

      schedule(encounter, cpf: "1")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("cpf")
    end

    it "enfermagem e médico leem; recepção, sem vínculo e id malformado/inexistente recusam" do
      issue!
      [ nurse, doctor ].each do |reader|
        sign_in_as(reader)
        schedule
        expect(response).to have_http_status(:ok)
      end
      sign_in_as(upa_reception!)
      expect { schedule }.not_to(change { trail.count })
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
      sign_in_as(upa_nurse!(upa!))
      schedule
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_link")
      sign_in_as(nurse)
      get "/urgency/encounters/nao-e-uuid/medication_schedule"
      expect(response).to have_http_status(:not_found)
      get "/urgency/encounters/#{SecureRandom.uuid}/medication_schedule"
      expect(response).to have_http_status(:not_found)
    end

    it "sem prescrição ativa → prescription_id nulo e itens vazios" do
      sign_in_as(nurse)
      schedule
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("prescription_id" => nil, "items" => [], "stock_deduction" => false)
    end

    it "a v2 ativa aparece e a v1 não; a última administração vem de qualquer versão" do
      v1 = issue!
      given = administer!(v1.items.first, at: 3.hours.ago)
      v2 = issue!
      sign_in_as(nurse)
      schedule
      expect(json_body).to include("prescription_id" => v2.id, "version" => 2)
      row = json_body["items"].sole
      expect(row["item_id"]).to eq(v2.items.first.id)
      expect(row["item_id"]).not_to eq(v1.items.first.id)
      expect(row["last_administration"]).to include("id" => given.id, "status" => "administered", "reason" => nil,
                                                    "by" => { "name" => nurse.professional.professional_name, "cbo_code" => "223505" })
      expect(row["last_administration"].keys).to match_array(%w[id status scheduled_at administered_at reason stock_lot stock_quantity recorded_at by])
    end

    it "last_administration é a mais recente do mesmo medicamento (não de outro item) e traz o motivo da não administrada" do
      v1 = issue!(encounter, [ item, item(catalog_item(267_197), dose: "5") ])
      older = administer!(v1.items.first, at: 5.hours.ago)
      newer = administer!(v1.items.first, status: "refused", at: 1.hour.ago)
      other = administer!(v1.items.second, at: 30.minutes.ago)
      sign_in_as(nurse)
      schedule
      first, second = json_body["items"]
      expect(first["last_administration"]).to include("id" => newer.id, "status" => "refused", "administered_at" => nil,
                                                      "reason" => "Paciente em jejum para exame")
      expect(first["last_administration"]["id"]).not_to eq(older.id)
      expect(second["last_administration"]["id"]).to eq(other.id)
    end

    it "o horário checado traz a administração; if_needed traz recent e remaining só com administered" do
      v1 = issue!(encounter, [ item(frequency: { kind: "once" }), item(catalog_item(267_197), dose: "5", frequency: { kind: "if_needed", max_per_day: 3 }) ])
      once, prn = v1.items.order(:position).to_a
      slot = administer!(once, at: once.first_dose_at)
      administer!(prn, at: 2.hours.ago)
      administer!(prn, status: "refused", at: 1.hour.ago)
      sign_in_as(nurse)
      schedule
      first, second = json_body["items"]
      expect(first["slots"].sole).to include("scheduled_at" => once.first_dose_at.iso8601)
      expect(first["slots"].sole["administration"]["id"]).to eq(slot.id)
      expect(second["slots"]).to eq([])
      expect(second["remaining"]).to eq(2)
      expect(second["recent"].size).to eq(2)
    end
  end

  describe "estoque" do
    let(:location) { unit_location!(upa) }
    before do
      pharmacy_city!
      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
    end

    it "stock_deduction true: lotes em FEFO sem vencido, bloqueado, de outra unidade, com saldo zero nem saldo de outros locais" do
      issue!
      late = lot!(location, "L-C", "10", Time.zone.today + 90)
      early = lot!(location, "L-A", "5.5", Time.zone.today + 30)
      tie = lot!(location, "L-B", "2", Time.zone.today + 30)
      today = lot!(location, "L-HOJE", "1", Time.zone.today)
      expired = lot!(location, "L-VENC", "9", Time.zone.today - 1)
      blocked = lot!(location, "L-BLOQ", "9", Time.zone.today + 10)
      zero = lot!(location, "L-ZERO", "3", Time.zone.today + 20)
      other_unit = lot!(location, "L-UNID", "9", Time.zone.today + 5, unit: "frasco")
      central = central_location!
      lot!(central, "L-A", "50", Time.zone.today + 30)
      only_central = lot!(central, "L-CENTRAL", "50", Time.zone.today + 2)
      zero_out(location, zero)
      block!(location, blocked)

      sign_in_as(nurse)
      schedule
      expect(response).to have_http_status(:ok)
      expect(json_body["stock_deduction"]).to be(true)
      lots = json_body["items"].sole["lots"]
      expect(lots.map { |l| l["lot_number"] }).to eq(%w[L-HOJE L-A L-B L-C])
      expect(lots.first).to eq("id" => today.id, "lot_number" => "L-HOJE", "expires_on" => (Time.zone.today).iso8601, "balance" => "1.00")
      expect(lots.second).to eq("id" => early.id, "lot_number" => "L-A", "expires_on" => (Time.zone.today + 30).iso8601, "balance" => "5.50")
      expect(lots.map { |l| l["id"] }).to eq([ today.id, early.id, tie.id, late.id ])
      expect(lots.map { |l| l["id"] }).not_to include(expired.id, blocked.id, zero.id, other_unit.id, only_central.id)
    end

    it "sem local de estoque `unit` ativo na UPA → lots []; com o interruptor desligado, sem stock_deduction nem lots" do
      issue!
      sign_in_as(nurse)
      schedule
      expect(json_body).to include("stock_deduction" => true)
      expect(json_body["items"].sole["lots"]).to eq([])

      location.update!(active: false)
      schedule
      expect(json_body["items"].sole["lots"]).to eq([])

      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      schedule
      expect(json_body).to include("stock_deduction" => false)
      expect(json_body["items"].sole).not_to have_key("lots")
    end
  end

  # Zera o saldo do lote no local pelo caminho real do estoque (baixa de administração).
  # Lote da losartana na unidade de dispensação do item (a da prescrição) e com saldo no local.
  def lot!(location, number, quantity, expires_on, unit: Pharmacy::DispensingUnit.for(losartana))
    StockLot.find_by(catalog_item_id: losartana.id, lot_number: number) ||
      StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: number, expires_on: expires_on,
                       dispensing_unit: unit, created_by_user: pharmacy_admin!)
    stocked_lot!(location, item: losartana, quantity: quantity, lot_number: number, expires_on: expires_on)
  end

  def zero_out(location, lot)
    link = Urgency::Access.physician_link(doctor, upa.id)
    adm = UrgencyAdministration.create!(urgency_prescription_item: UrgencyPrescriptionItem.first, urgency_encounter: encounter, status: "administered",
                                        administered_at: Time.current, recorded_by_user: doctor, professional_link: link, cbo_code: link.cbo_code,
                                        recorded_at: Time.current, stock_lot: lot, stock_quantity: balance_of(location, lot))
    Pharmacy::Ledger.record!(location: location, lot: lot, kind: "administration", quantity: balance_of(location, lot), by: doctor, document: adm)
  end

  def block!(location, lot) = lot_block!(location, lot)
end
