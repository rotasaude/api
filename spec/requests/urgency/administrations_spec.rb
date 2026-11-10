require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

# Módulo 32b (ADR 0050; contrato §6 e §12 Q5, Q6; plano, Desvios 6, 8 e 10):
# POST /urgency/administrations — a checagem da medicação, imutável, sem
# estoque (o interruptor desligado ou não utilizável). Checa quem tem vínculo
# ativo na UPA do encontro com CBO 2235*, 3222* ou 225*. Ordem das recusas:
# encontro fechado → acesso → item de versão não ativa → forma → horário
# (slot_invalid, slot_not_due, slot_taken, max_per_day_reached) → estoque.
RSpec.describe "Urgência — checagem da medicação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  let(:nurse) { observation_nurse!(upa) }
  let(:technician) { upa_nurse!(upa, cbo: "322205") }
  let!(:catalog) { import_test_catalog! }
  let(:losartana) { catalog_item(268_856) }
  let(:diazepam) { catalog_item(267_197) }
  let(:encounter) { in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) } }
  let(:checked) { DomainEvent.where(name: "urgency.medication_checked") }
  before { ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  def item(catalog_item = losartana, **over)
    { catalog_item_id: catalog_item.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
  end

  def issue!(target = encounter, items = [ item ])
    result = Urgency::IssuePrescription.call(encounter: target, items: items.map(&:deep_stringify_keys), by: doctor,
                                             catalog: { losartana.id => losartana, diazepam.id => diazepam })
    raise "issue! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:prescription)
  end

  def check(row, **body) = json_post("/urgency/administrations", { prescription_item_id: row.id }.merge(body))
  def administer(row, at = row.first_dose_at, **body) = check(row, scheduled_at: at.iso8601, status: "administered", **body)

  def expect_refusal(status, error, path = nil)
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(json_body["path"]).to eq(path) if path
  end

  describe "horário (interval e once)" do
    before { sign_in_as(nurse) }

    it "administra o horário devido → 201 sem movimento nem falta; o mesmo horário → 409 slot_taken; fora do aprazamento → 422 slot_invalid" do
      row = issue!.items.first
      expect { administer(row) }.to change(UrgencyAdministration, :count).by(1)
        .and(not_change(StockMovement, :count)).and(not_change(UrgencyStockShortfall, :count))
      expect(response).to have_http_status(:created)
      expect(json_body["shortfall"]).to be_nil
      adm = json_body["administration"]
      expect(adm.keys).to match_array(%w[id status scheduled_at administered_at reason stock_lot stock_quantity recorded_at by])
      expect(adm).to include("status" => "administered", "scheduled_at" => row.first_dose_at.iso8601, "reason" => nil, "stock_lot" => nil,
                             "stock_quantity" => nil, "by" => { "name" => nurse.professional.professional_name, "cbo_code" => "223505" })
      stored = UrgencyAdministration.find(adm["id"])
      expect(stored).to have_attributes(urgency_encounter_id: encounter.id, recorded_by_user_id: nurse.id, cbo_code: "223505",
                                        professional_link_id: Urgency::Access.nursing_or_physician_link(nurse, upa.id).id)
      expect(stored.administered_at).to be_within(2.seconds).of(Time.current)

      expect { administer(row) }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:conflict, "slot_taken")

      administer(row, row.first_dose_at + 30.minutes)
      expect_refusal(:unprocessable_entity, "slot_invalid", "scheduled_at")
    end

    it "um horário pode ser checado até 60 min antes: a 61 min → 422 slot_not_due; a 59 min → 201" do
      row = issue!(encounter, [ item(frequency: { kind: "interval", interval_hours: 2 }) ]).items.first
      due = row.first_dose_at + 2.hours

      travel_to(due - 61.minutes) do
        sign_in_as(nurse)
        administer(row, due)
        expect_refusal(:unprocessable_entity, "slot_not_due", "scheduled_at")
      end
      travel_to(due - 59.minutes) do
        sign_in_as(nurse)
        administer(row, due)
        expect(response).to have_http_status(:created)
      end
    end

    it "horário passado, ainda não checado, é aceito com o encontro aberto" do
      row = issue!(encounter, [ item(first_dose_at: 50.minutes.ago.iso8601) ]).items.first
      expect(row.first_dose_at).to be < 40.minutes.ago
      administer(row)
      expect(response).to have_http_status(:created)
      expect(json_body.dig("administration", "scheduled_at")).to eq(row.first_dose_at.iso8601)
    end

    it "dose em dobro entre versões: o mesmo medicamento no mesmo horário da v2 → 409 slot_taken; o item da v1 → 422 prescription_not_active" do
      v1 = issue!
      administer(v1.items.first)
      expect(response).to have_http_status(:created)
      v2 = issue!(encounter, [ item(first_dose_at: v1.items.first.first_dose_at.iso8601) ])

      expect { administer(v2.items.first) }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:conflict, "slot_taken")

      administer(v1.items.first, v1.items.first.first_dose_at + 8.hours)
      expect_refusal(:unprocessable_entity, "prescription_not_active")
    end

    it "dois itens do mesmo medicamento na mesma versão, o mesmo horário: o segundo → 409 slot_taken" do
      first, second = issue!(encounter, [ item, item(dose: "25") ]).items.order(:position).to_a
      administer(first)
      expect(response).to have_http_status(:created)
      expect { administer(second) }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:conflict, "slot_taken")
    end

    it "a rede do índice idx_urgency_administrations_slot (a conferência do Ruby desligada) → 409 slot_taken" do
      row = issue!.items.first
      allow(Urgency::RecordAdministration).to receive(:slot_taken?).and_return(false)
      administer(row)
      expect(response).to have_http_status(:created)
      expect { administer(row) }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:conflict, "slot_taken")
      expect(Urgency::RecordAdministration).to have_received(:slot_taken?).twice
    end

    it "once e interval exigem scheduled_at; status fora da lista → 422 com o path" do
      row = issue!(encounter, [ item(frequency: { kind: "once" }) ]).items.first
      check(row, status: "administered")
      expect_refusal(:unprocessable_entity, "invalid_request", "scheduled_at")
      check(row, scheduled_at: "amanhã", status: "administered")
      expect_refusal(:unprocessable_entity, "invalid_request", "scheduled_at")
      check(row, scheduled_at: row.first_dose_at.iso8601, status: "given")
      expect_refusal(:unprocessable_entity, "invalid_request", "status")
      expect(UrgencyAdministration.count).to eq(0)
    end
  end

  describe "status, motivo e administered_at" do
    before { sign_in_as(nurse) }

    it "refused sem motivo → 422 reason; com motivo → 201 (motivo devolvido); administered com motivo → 422 reason" do
      row = issue!.items.first
      check(row, scheduled_at: row.first_dose_at.iso8601, status: "refused")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      check(row, scheduled_at: row.first_dose_at.iso8601, status: "refused", reason: "curto")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      administer(row, reason: "Paciente aceitou a medicação")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")

      check(row, scheduled_at: row.first_dose_at.iso8601, status: "refused", reason: "  Paciente recusou a medicação  ")
      expect(response).to have_http_status(:created)
      expect(json_body["administration"]).to include("status" => "refused", "administered_at" => nil, "reason" => "Paciente recusou a medicação")
    end

    it "administered_at: só em administered, até agora + 5 min e nunca antes do prescribed_at da versão" do
      prescription = issue!
      row = prescription.items.first
      check(row, scheduled_at: row.first_dose_at.iso8601, status: "not_administered", reason: "Paciente em jejum para exame",
                 administered_at: Time.current.iso8601)
      expect_refusal(:unprocessable_entity, "invalid_request", "administered_at")
      administer(row, administered_at: 6.minutes.from_now.iso8601)
      expect_refusal(:unprocessable_entity, "invalid_request", "administered_at")
      administer(row, administered_at: (prescription.prescribed_at - 1.minute).iso8601)
      expect_refusal(:unprocessable_entity, "invalid_request", "administered_at")

      at = 4.minutes.from_now.change(usec: 0)
      administer(row, administered_at: at.iso8601)
      expect(response).to have_http_status(:created)
      expect(json_body.dig("administration", "administered_at")).to eq(at.iso8601)
    end
  end

  describe "se necessário (if_needed)" do
    before { sign_in_as(nurse) }

    it "não aceita scheduled_at; max_per_day 2 → a terceira administrada em 24 h → 422 max_per_day_reached (a recusada não conta)" do
      row = issue!(encounter, [ item(diazepam, dose: "5", dose_unit: "mg", frequency: { kind: "if_needed", max_per_day: 2 }) ]).items.first
      check(row, scheduled_at: Time.current.iso8601, status: "administered")
      expect_refusal(:unprocessable_entity, "invalid_request", "scheduled_at")

      check(row, status: "administered")
      expect(response).to have_http_status(:created)
      expect(json_body.dig("administration", "scheduled_at")).to be_nil
      check(row, status: "refused", reason: "Paciente recusou a medicação")
      expect(response).to have_http_status(:created)
      check(row, status: "administered")
      expect(response).to have_http_status(:created)

      expect { check(row, status: "administered") }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:unprocessable_entity, "max_per_day_reached")
      check(row, status: "not_administered", reason: "Paciente dormindo, sem dor")
      expect(response).to have_http_status(:created)
    end
  end

  describe "estoque desligado ou não utilizável" do
    before { sign_in_as(nurse) }

    it "stock_lot_id ou stock_quantity com o interruptor desligado → 422 stock_deduction_disabled (path do campo); fora de administered → invalid_request" do
      row = issue!.items.first
      expect { administer(row, stock_lot_id: SecureRandom.uuid) }.not_to change(UrgencyAdministration, :count)
      expect_refusal(:unprocessable_entity, "stock_deduction_disabled", "stock_lot_id")
      administer(row, stock_quantity: "1")
      expect_refusal(:unprocessable_entity, "stock_deduction_disabled", "stock_quantity")
      check(row, scheduled_at: row.first_dose_at.iso8601, status: "refused", reason: "Paciente recusou a medicação", stock_quantity: "1")
      expect_refusal(:unprocessable_entity, "invalid_request", "stock_quantity")
    end

    it "interruptor ligado, mas a farmácia desligada (não utilizável) → 422 stock_deduction_disabled, sem movimento nem falta" do
      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      expect(Platform::Features.enabled?(city, Urgency::StockGate::KEY)).to be(true)
      expect(Urgency::StockGate.usable?(city)).to be(false)

      row = issue!.items.first
      expect { administer(row, stock_lot_id: SecureRandom.uuid) }.to not_change(UrgencyAdministration, :count)
        .and(not_change(StockMovement, :count)).and(not_change(UrgencyStockShortfall, :count))
      expect_refusal(:unprocessable_entity, "stock_deduction_disabled", "stock_lot_id")

      administer(row)
      expect(response).to have_http_status(:created)
      expect(json_body["shortfall"]).to be_nil
    end

    it "com o interruptor utilizável e administered, baixa o estoque pelo FEFO (Task 10)" do
      pharmacy_city!
      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      location = unit_location!(upa)
      unit = Pharmacy::DispensingUnit.for(losartana) # a do item (`stock_unit`); a amostra de teste cai em "unidade"
      StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: "T10-FEFO", expires_on: Time.zone.today + 60,
                       dispensing_unit: unit, created_by_user: pharmacy_admin!)
      lot = stocked_lot!(location, item: losartana, quantity: "3", lot_number: "T10-FEFO", expires_on: Time.zone.today + 60)

      row = issue!.items.first
      expect { administer(row) }.to change(StockMovement, :count).by(1).and(not_change(UrgencyStockShortfall, :count))
      expect(response).to have_http_status(:created)
      expect(json_body["shortfall"]).to be_nil
      expect(json_body["administration"]).to include("stock_quantity" => "1.00")
      expect(json_body.dig("administration", "stock_lot", "id")).to eq(lot.id)
      expect(balance_of(location, lot)).to eq(2)
    end
  end

  describe "quem checa e a ordem das recusas" do
    it "o técnico 3222 e o médico checam; a recepção → 403 missing_role; sem vínculo na UPA → 403 missing_link" do
      row = issue!(encounter, [ item, item(diazepam, dose: "5", dose_unit: "mg") ]).items.order(:position).to_a
      sign_in_as(technician)
      administer(row.first)
      expect(response).to have_http_status(:created)
      expect(json_body.dig("administration", "by", "cbo_code")).to eq("322205")
      expect(UrgencyAdministration.find(json_body.dig("administration", "id")).cbo_code).to eq("322205")

      sign_in_as(doctor)
      administer(row.second)
      expect(response).to have_http_status(:created)

      sign_in_as(upa_reception!)
      administer(row.first, row.first.first_dose_at + 8.hours)
      expect_refusal(:forbidden, "missing_role")
      sign_in_as(upa_nurse!(upa!))
      administer(row.first, row.first.first_dose_at + 8.hours)
      expect_refusal(:forbidden, "missing_link")
    end

    it "encontro fechado → 409 encounter_closed antes do acesso; acesso antes da versão; versão antes da forma; forma antes do horário" do
      v1 = issue!
      v2 = issue!
      sign_in_as(upa_reception!)
      check(v1.items.first, status: "x")
      expect_refusal(:forbidden, "missing_role")
      sign_in_as(nurse)
      check(v1.items.first, status: "x")
      expect_refusal(:unprocessable_entity, "prescription_not_active")
      check(v2.items.first, scheduled_at: (v2.items.first.first_dose_at + 30.minutes).iso8601, status: "refused")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")

      target = encounter
      finalized_urgency!(target, doctor: doctor)
      Urgency::RecordOutcome.call(encounter: target, attrs: { "kind" => "death" }, by: doctor).tap { |r| raise r.reason.to_s if r.failure? }
      sign_in_as(upa_reception!)
      administer(v2.items.first)
      expect_refusal(:conflict, "encounter_closed")
    end

    it "item inexistente → 404; id malformado ou ausente → 422; chave desconhecida e query → 422 com o nome da chave" do
      row = issue!.items.first
      sign_in_as(nurse)
      json_post("/urgency/administrations", prescription_item_id: SecureRandom.uuid, status: "administered")
      expect_refusal(:not_found, "not_found")
      json_post("/urgency/administrations", prescription_item_id: "nao-e-uuid", status: "administered")
      expect_refusal(:unprocessable_entity, "invalid_request", "prescription_item_id")
      json_post("/urgency/administrations", status: "administered")
      expect_refusal(:unprocessable_entity, "invalid_request", "prescription_item_id")
      administer(row, dose: "50")
      expect_refusal(:unprocessable_entity, "invalid_request", "dose")
      post "/urgency/administrations?cpf=1", params: { prescription_item_id: row.id, status: "administered" }.to_json,
                                             headers: { "CONTENT_TYPE" => "application/json" }
      expect_refusal(:unprocessable_entity, "invalid_request", "cpf")
      expect(UrgencyAdministration.count).to eq(0)
    end
  end

  it "o evento urgency.medication_checked leva só encounter_id e administration_id" do
    row = issue!.items.first
    sign_in_as(nurse)
    expect { administer(row) }.to change { checked.count }.by(1)
    expect(checked.last.payload).to eq("encounter_id" => encounter.id, "administration_id" => json_body.dig("administration", "id"))
  end
end
