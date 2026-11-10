require "rails_helper"

# Módulo 32b (ADR 0050; contrato §5 e §12 P1, Q4, Q6; plano, Desvios 3, 4 e 9):
# a prescrição interna do médico da UPA, em versões (POST
# /urgency/encounters/:id/prescriptions), a suspensão (POST
# /urgency/prescriptions/:id/suspend) e a busca de medicamento da prescrição
# (POST /urgency/medication_search, sob urgency_care, sem clinical_documents).
# Qualquer lista da Portaria 344 vale (P1); dose e quantidades são String
# decimal (Q6); nada clínico em evento nem log.
RSpec.describe "Urgência — prescrição interna", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  let(:nurse) { observation_nurse!(upa) }
  let!(:catalog) { import_test_catalog! }
  let(:losartana) { catalog_item(268_856) }
  let(:diazepam) { catalog_item(267_197) }
  let(:encounter) { in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) } }
  before { ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  def item(catalog_item = losartana, **over)
    { catalog_item_id: catalog_item.id, dose: "50", dose_unit: "mg", route: "oral",
      frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
  end

  def issue(target = encounter, items = [ item ], **body) = json_post("/urgency/encounters/#{target.id}/prescriptions", { items: items }.merge(body))
  def suspend(prescription, **body) = json_post("/urgency/prescriptions/#{prescription.id}/suspend", body)
  def events(name) = DomainEvent.where(name: name)

  def expect_refusal(status, error, path = nil)
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(json_body["path"]).to eq(path) if path
  end

  describe "emitir e alterar" do
    before { sign_in_as(doctor) }

    it "emite a v1 → 201 com os itens; o evento leva só ids" do
      issue(encounter, [ item(losartana, instructions: "Em jejum", stock_quantity_per_dose: "2"),
                         item(diazepam, dose: "2.5", frequency: { kind: "if_needed", max_per_day: 3 }) ])
      expect(response).to have_http_status(:created)
      body = json_body["prescription"]
      expect(body).to include("encounter_id" => encounter.id, "version" => 1, "status" => "active", "supersedes_id" => nil,
                              "status_changed_at" => nil, "suspension_reason" => nil)
      expect(body["prescribed_by"]).to include("cbo_code" => "225125")
      first, second = body["items"]
      expect(first).to include("position" => 1, "controlled" => false, "controlled_list" => nil, "dose" => "50", "dose_unit" => "mg",
                               "route" => "oral", "instructions" => "Em jejum", "stock_quantity_per_dose" => "2.00",
                               "frequency" => { "kind" => "interval", "interval_hours" => 8, "max_per_day" => nil })
      expect(first["catalog_item"]).to include("catalog_item_id" => losartana.id, "catmat_code" => 268_856)
      expect(first["stock_unit"]).to eq(Pharmacy::DispensingUnit.for(losartana))
      expect(second).to include("position" => 2, "dose" => "2.5", "stock_quantity_per_dose" => "1.00",
                                "frequency" => { "kind" => "if_needed", "interval_hours" => nil, "max_per_day" => 3 })
      expect(Time.zone.parse(first["first_dose_at"])).to be_within(61.seconds).of(Time.current)
      expect(Time.zone.parse(first["first_dose_at"]).sec).to eq(0)

      record = UrgencyPrescription.find(body["id"])
      expect(record).to have_attributes(prescribed_by_user_id: doctor.id, status: "active")
      expect(events("urgency.prescription_issued").sole.payload).to eq("encounter_id" => encounter.id, "prescription_id" => record.id)
    end

    it "diazepam (B1) é aceito, com controlled e controlled_list copiados do catálogo (P1)" do
      issue(encounter, [ item(diazepam, dose: "5") ])
      expect(response).to have_http_status(:created)
      expect(json_body.dig("prescription", "items", 0)).to include("controlled" => true, "controlled_list" => "B1")
      expect(UrgencyPrescriptionItem.sole.controlled_list).to eq("B1")
    end

    it "emitir de novo → v2 active com supersedes_id = v1; v1 superseded e os itens dela intactos" do
      issue
      v1 = UrgencyPrescription.find(json_body.dig("prescription", "id"))
      v1_item_ids = v1.items.map(&:id)
      issue(encounter, [ item(diazepam, dose: "5") ])
      expect(response).to have_http_status(:created)
      expect(json_body["prescription"]).to include("version" => 2, "status" => "active", "supersedes_id" => v1.id)
      expect(v1.reload).to have_attributes(status: "superseded", status_changed_by_user_id: doctor.id)
      expect(v1.status_changed_at).to be_present
      expect(v1.items.map(&:id)).to eq(v1_item_ids)
      expect(UrgencyPrescription.where(urgency_encounter_id: encounter.id).active_versions.count).to eq(1)
      expect(events("urgency.prescription_issued").count).to eq(2)
    end

    it "first_dose_at: padrão = agora truncado ao minuto; aceita de agora − 1 h a agora + 24 h" do
      now = Time.zone.now.change(sec: 0)
      issue(encounter, [ item(first_dose_at: (now + 2.hours).iso8601) ])
      expect(response).to have_http_status(:created)
      expect(Time.zone.parse(json_body.dig("prescription", "items", 0, "first_dose_at"))).to eq(now + 2.hours)
      issue(encounter, [ item(first_dose_at: (Time.current - 30.minutes).iso8601) ])
      expect(response).to have_http_status(:created)
    end
  end

  describe "recusas de forma" do
    before { sign_in_as(doctor) }

    def expect_no_prescription = expect(UrgencyPrescription.count).to eq(0)

    it "item escondido do catálogo → 422 catalog_item_invalid em items.0.catalog_item_id" do
      hidden = catalog_item(271_089)
      hidden.update!(hidden: true)
      issue(encounter, [ item(hidden) ])
      expect_refusal(:unprocessable_entity, "catalog_item_invalid", "items.0.catalog_item_id")
      expect(json_body["problems"]).to eq([ { "path" => "items.0.catalog_item_id", "error" => "catalog_item_invalid" } ])
      issue(encounter, [ item(losartana, catalog_item_id: SecureRandom.uuid) ])
      expect_refusal(:unprocessable_entity, "catalog_item_invalid", "items.0.catalog_item_id")
      expect_no_prescription
    end

    it "dose como número JSON, zero ou fora do formato → 422 invalid_request em items.0.dose" do
      [ 500, "0", "0.000", "1e3", "1,5", "0.0001", "", nil ].each do |dose|
        issue(encounter, [ item(dose: dose) ])
        expect_refusal(:unprocessable_entity, "invalid_request", "items.0.dose")
      end
      expect_no_prescription
    end

    it "dose_unit, route e frequency.kind fora do domínio; instruções longas; quantidade de estoque inválida" do
      issue(encounter, [ item(dose_unit: "kg") ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.dose_unit")
      issue(encounter, [ item(route: "dermal") ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.route")
      issue(encounter, [ item(frequency: { kind: "daily" }) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.frequency.kind")
      issue(encounter, [ item(instructions: "x" * 501) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.instructions")
      [ 2, "0", "-1", "1,5" ].each do |quantity|
        issue(encounter, [ item(stock_quantity_per_dose: quantity) ])
        expect_refusal(:unprocessable_entity, "invalid_request", "items.0.stock_quantity_per_dose")
      end
      expect_no_prescription
    end

    it "interval sem interval_hours e if_needed com interval_hours → os dois em problems" do
      issue(encounter, [ item(frequency: { kind: "interval" }), item(diazepam, frequency: { kind: "if_needed", max_per_day: 2, interval_hours: 4 }) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"].map { |p| p["path"] })
        .to contain_exactly("items.0.frequency.interval_hours", "items.1.frequency.interval_hours")
      issue(encounter, [ item(frequency: { kind: "interval", interval_hours: 25 }) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.frequency.interval_hours")
      issue(encounter, [ item(frequency: { kind: "if_needed" }) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.frequency.max_per_day")
      issue(encounter, [ item(frequency: { kind: "once", max_per_day: 2 }) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.frequency.max_per_day")
      expect_no_prescription
    end

    it "first_dose_at fora da janela ou malformado → 422 em items.0.first_dose_at" do
      [ (Time.current - 2.hours).iso8601, (Time.current + 25.hours).iso8601, "amanha", 5 ].each do |value|
        issue(encounter, [ item(first_dose_at: value) ])
        expect_refusal(:unprocessable_entity, "invalid_request", "items.0.first_dose_at")
      end
      expect_no_prescription
    end

    it "0 ou 21 itens, items não-lista, chave desconhecida no corpo, no item ou na frequência → 422 com o path" do
      issue(encounter, [])
      expect_refusal(:unprocessable_entity, "invalid_request", "items")
      issue(encounter, Array.new(21) { item })
      expect_refusal(:unprocessable_entity, "invalid_request", "items")
      issue(encounter, "x")
      expect_refusal(:unprocessable_entity, "invalid_request", "items")
      issue(encounter, [ item, "x" ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.1")
      issue(encounter, [ item(note: "x") ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.note")
      issue(encounter, [ item(frequency: { kind: "once", times: 1 }) ])
      expect_refusal(:unprocessable_entity, "invalid_request", "items.0.frequency.times")
      issue(encounter, [ item ], extra: 1)
      expect_refusal(:unprocessable_entity, "invalid_request", "extra")
      expect_no_prescription
    end

    it "20 itens passam" do
      issue(encounter, Array.new(20) { item })
      expect(response).to have_http_status(:created)
      expect(json_body.dig("prescription", "items").size).to eq(20)
    end
  end

  describe "estado e acesso" do
    it "sem consulta de urgência → 422 consultation_required" do
      sign_in_as(doctor)
      issue(in_care_encounter!(upa))
      expect_refusal(:unprocessable_entity, "consultation_required")
      expect(UrgencyPrescription.count).to eq(0)
    end

    it "encontro fechado → 409 encounter_closed" do
      target = encounter
      finalized_urgency!(target, doctor: doctor)
      Urgency::RecordOutcome.call(encounter: target, attrs: { "kind" => "death" }, by: doctor).tap { |r| raise r.reason.to_s if r.failure? }
      sign_in_as(doctor)
      issue(target)
      expect_refusal(:conflict, "encounter_closed")
    end

    it "enfermagem → 403 cbo_not_allowed; sem vínculo na UPA → 403 missing_link; sem papel → 403 missing_role; nada gravado" do
      target = encounter
      sign_in_as(nurse)
      issue(target)
      expect_refusal(:forbidden, "cbo_not_allowed")
      sign_in_as(upa_doctor!(upa!))
      issue(target)
      expect_refusal(:forbidden, "missing_link")
      sign_in_as(upa_reception!)
      issue(target)
      expect_refusal(:forbidden, "missing_role")
      expect(UrgencyPrescription.count).to eq(0)
    end

    it "encontro inexistente ou id malformado → 404; urgency_care desligado → 403 feature_disabled" do
      sign_in_as(doctor)
      json_post("/urgency/encounters/#{SecureRandom.uuid}/prescriptions", { items: [ item ] })
      expect_refusal(:not_found, "not_found")
      json_post("/urgency/encounters/abc/prescriptions", { items: [ item ] })
      expect_refusal(:not_found, "not_found")
      target = encounter
      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      issue(target)
      expect_refusal(:forbidden, "feature_disabled")
    end
  end

  describe "suspender" do
    let(:prescription) { issue(encounter) && UrgencyPrescription.find(json_body.dig("prescription", "id")) }
    let(:reason) { "Reação alérgica na infusão" }

    before { sign_in_as(doctor) }

    it "motivo curto ou fora do corpo → 422 invalid_request em reason; chave desconhecida → 422" do
      target = prescription
      suspend(target, reason: "curto")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      suspend(target, reason: "x" * 501)
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      suspend(target)
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      suspend(target, reason: reason, other: 1)
      expect_refusal(:unprocessable_entity, "invalid_request", "other")
      expect(target.reload.status).to eq("active")
    end

    it "com motivo → 200 suspended, cifrado, com o evento só de ids; a segunda → 422 prescription_not_active" do
      target = prescription
      suspend(target, reason: reason)
      expect(response).to have_http_status(:ok)
      expect(json_body["prescription"]).to include("id" => target.id, "status" => "suspended", "suspension_reason" => reason)
      expect(target.reload).to have_attributes(status: "suspended", status_changed_by_user_id: doctor.id)
      expect(UrgencyPrescription.connection.select_value("SELECT suspension_reason FROM urgency_prescriptions WHERE id = '#{target.id}'"))
        .not_to include(reason)
      expect(events("urgency.prescription_suspended").sole.payload).to eq("encounter_id" => encounter.id, "prescription_id" => target.id)

      suspend(target, reason: reason)
      expect_refusal(:unprocessable_entity, "prescription_not_active")
      expect(events("urgency.prescription_suspended").count).to eq(1)
    end

    it "versão substituída → 422 prescription_not_active" do
      v1 = prescription
      issue
      suspend(v1, reason: reason)
      expect_refusal(:unprocessable_entity, "prescription_not_active")
    end

    it "depois de suspender, dá para emitir uma nova (v2)" do
      v1 = prescription
      suspend(v1, reason: reason)
      issue
      expect(response).to have_http_status(:created)
      expect(json_body["prescription"]).to include("version" => 2, "supersedes_id" => v1.id)
    end

    it "encontro fechado → 409 encounter_closed" do
      target = prescription
      finalized_urgency!(encounter, doctor: doctor)
      Urgency::RecordOutcome.call(encounter: encounter, attrs: { "kind" => "death" }, by: doctor).tap { |r| raise r.reason.to_s if r.failure? }
      suspend(target, reason: reason)
      expect_refusal(:conflict, "encounter_closed")
    end

    it "enfermagem → 403 cbo_not_allowed; sem vínculo → 403 missing_link; id desconhecido → 404" do
      target = prescription
      sign_in_as(nurse)
      suspend(target, reason: reason)
      expect_refusal(:forbidden, "cbo_not_allowed")
      sign_in_as(upa_doctor!(upa!))
      suspend(target, reason: reason)
      expect_refusal(:forbidden, "missing_link")
      sign_in_as(doctor)
      json_post("/urgency/prescriptions/#{SecureRandom.uuid}/suspend", { reason: reason })
      expect_refusal(:not_found, "not_found")
      expect(target.reload.status).to eq("active")
    end
  end

  describe "sigilo" do
    it "nenhum log da requisição leva o princípio ativo, a dose, as instruções, o motivo nem a busca" do
      sign_in_as(doctor)
      target = encounter
      log = capture_log do
        issue(target, [ item(losartana, dose: "37.5", instructions: "Instrução reservada XYZ") ])
        suspend(UrgencyPrescription.find(json_body.dig("prescription", "id")), reason: "Motivo reservado ABC123")
        json_post("/urgency/medication_search", { query: "losartana" })
      end
      expect(log).to include("/urgency/encounters/#{target.id}/prescriptions", "/urgency/medication_search") # controle
      [ losartana.active_ingredient, "37.5", "Instrução reservada", "Motivo reservado" ].each do |secret|
        expect(log).not_to include(secret)
      end
      # O termo da busca: nem na linha da requisição nem nos Parameters (o SQL
      # do LIKE só aparece em nível debug; produção loga em info).
      requests = log.lines.grep(/Started|Parameters/).join
      expect(requests).to include("/urgency/medication_search")
      expect(requests.downcase).not_to include("losartana")
    end

    it "eventos da prescrição levam só ids" do
      sign_in_as(doctor)
      v1 = issue && UrgencyPrescription.find(json_body.dig("prescription", "id"))
      suspend(v1, reason: "Motivo reservado ABC123")
      payloads = DomainEvent.where(name: %w[urgency.prescription_issued urgency.prescription_suspended]).map(&:payload)
      expect(payloads.size).to eq(2)
      payloads.each { |p| expect(p.keys).to contain_exactly("encounter_id", "prescription_id") }
    end
  end

  describe "busca de medicamento (POST /urgency/medication_search)" do
    def search(query = "diazepam", **extra) = json_post("/urgency/medication_search", { query: query }.merge(extra))

    it "o médico da UPA acha o diazepam com controlled_list B1, mesmo com clinical_documents desligado" do
      expect(Platform::Features.usable?(city, "clinical_documents")).to be(false)
      sign_in_as(doctor)
      search
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].first).to eq(
        "catalog_item_id" => diazepam.id, "catmat_code" => 267_197, "name" => diazepam.active_ingredient,
        "strength" => diazepam.strength, "dosage_form" => diazepam.dosage_form, "unit" => diazepam.unit, "controlled_list" => "B1"
      )
      search("losartana")
      expect(json_body["items"].map { |i| i["catmat_code"] }).to eq([ 268_856 ])
      expect(json_body["items"].first["controlled_list"]).to be_nil
    end

    it "não devolve item escondido" do
      hidden = catalog_item(271_089)
      hidden.update!(hidden: true)
      sign_in_as(doctor)
      search("amoxicilina")
      expect(json_body["items"].map { |i| i["catalog_item_id"] }).not_to include(hidden.id)
    end

    it "enfermagem → 403 cbo_not_allowed; sem vínculo com UPA → 403 missing_link; recepção → 403 missing_role" do
      sign_in_as(nurse)
      search
      expect_refusal(:forbidden, "cbo_not_allowed")
      sign_in_as(doctor!(create_unit))
      search
      expect_refusal(:forbidden, "missing_link")
      sign_in_as(upa_reception!)
      search
      expect_refusal(:forbidden, "missing_role")
    end

    it "chave desconhecida, query curta, longa ou não-texto, e query na URL → 422 invalid_request" do
      sign_in_as(doctor)
      search("diazepam", extra: 1)
      expect_refusal(:unprocessable_entity, "invalid_request", "extra")
      [ "d", " d ", "x" * 61, 5, nil ].each do |query|
        search(query)
        expect_refusal(:unprocessable_entity, "invalid_request", "query")
      end
      json_post("/urgency/medication_search?query=diazepam", { query: "diazepam" })
      expect_refusal(:unprocessable_entity, "invalid_request", "query")
    end

    it "urgency_care desligado → 403 feature_disabled" do
      sign_in_as(doctor)
      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      search
      expect_refusal(:forbidden, "feature_disabled")
    end
  end
end
