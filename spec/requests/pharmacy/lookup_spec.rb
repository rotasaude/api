require "rails_helper"

# Módulo 27a, Task 9 (ADR 0045; contrato §7, H3, H6, H12; Review Focus 1): a
# receita para a farmácia (busca por código e por paciente), a busca de pessoa e
# os duplicados. Leitura NOMINAL com trilha `clinical_record.viewed` (access
# "pharmacy"), uma por pessoa mostrada, só ids; CPF, CNS, nome e medicamento só no
# corpo. Todo 422 traz `problems`; local sem papel → 403 sozinho.
RSpec.describe "Farmácia — receita, busca de pessoa e duplicados", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:today) { Time.use_zone(city.time_zone) { Time.zone.today } }
  let(:paracetamol) { catalog_item(267_778) }
  let(:consultation) { pharmacy_consultation! }
  let(:patient) { consultation.patient }

  def post_json(path, body) = post(path, params: body.to_json, headers: json_headers)
  def lookup(body = {}, location: farmacia, **fields) = post_json("/pharmacy/prescriptions/lookup", { location_id: location.id }.merge(body).merge(fields))
  def by_code(document, **over) = lookup({ short_code: document.short_code }.merge(over))
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload).select { |payload| payload["access"] == "pharmacy" }
  def disable_pharmacy! = Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)

  # 23:30 no fuso da cidade, `days` dias antes de hoje (já é o dia seguinte em UTC).
  def late_evening(days_ago) = Time.use_zone(city.time_zone) { (today - days_ago).in_time_zone.change(hour: 23, min: 30) }

  def external!(for_patient = patient, issued_on: today, items: [ { catalog: losartana } ], notification_number: nil)
    record = ExternalPrescription.create!(patient: for_patient, stock_location: farmacia, prescriber_name: "Dra. Beltrana Souza", council: "CRM",
                                          council_state: "PR", council_number: "54321", issued_on: issued_on, notification_number: notification_number,
                                          recorded_by_user: pharmacist)
    items.each_with_index do |row, index|
      ExternalPrescriptionItem.create!(external_prescription: record, position: index + 1, catalog_item_id: row[:catalog].id,
                                       catmat_code: row[:catalog].catmat_code, quantity: row.fetch(:quantity, 30), quantity_unit: "comprimido",
                                       dosage_instructions: "1 comprimido ao dia", continuous: row.fetch(:continuous, false),
                                       controlled_list: row[:catalog].controlled_list)
    end
    record
  end

  def dispense!(document, prescription_item, quantity:, at: Time.current, completes: false)
    lot = StockLot.find_by(catalog_item_id: prescription_item.medication_catalog_item_id) ||
          stocked_lot!(farmacia, item: MedicationCatalogItem.find(prescription_item.medication_catalog_item_id))
    dispensation = Dispensation.create!(stock_location: farmacia, patient: document.patient, clinical_document: document, dispensed_by_user: pharmacist,
                                        dispensed_by_role: "pharmacist", dispensed_at: at)
    DispensationItem.create!(dispensation: dispensation, prescription_item: prescription_item, stock_lot: lot,
                             catalog_item_id: prescription_item.medication_catalog_item_id, quantity: quantity, completes_item: completes)
  end

  before { sign_in_as(pharmacist) }

  describe "POST /pharmacy/prescriptions/lookup — por código" do
    it "acha pelo código em minúsculas, com hífen ou espaço; a forma completa da <prescription_view>" do
      document = pharmacy_prescription!(consultation: consultation)
      item = document.prescription_items.first
      lookup(short_code: document.short_code.downcase)
      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body.keys).to eq([ "prescriptions" ])
      view = body["prescriptions"].sole
      author = document.author_user
      expect(view.except("items", "prescriber")).to eq(
        "kind" => "digital", "id" => document.id, "short_code" => ClinicalDocuments::Codes.display(document.short_code),
        "issued_on" => document.issued_at.in_time_zone(city.time_zone).to_date.iso8601, "valid_until" => (today + 30).iso8601, "expired" => false,
        "cancelled" => false,
        "patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => nil }
      )
      expect(view["prescriber"]).to eq("name" => author.professional.professional_name, "council" => ClinicalDocuments::Json.council(author.professional))
      expect(view["items"].sole).to eq(
        "id" => item.id, "catalog_item_id" => losartana.id,
        "item" => { "catalog_item_id" => losartana.id, "catmat_code" => losartana.catmat_code, "name" => losartana.label, "unit" => losartana.unit,
                    "dispensing_unit" => Pharmacy::DispensingUnit.for(losartana), "controlled" => false, "controlled_list" => nil },
        "free_text" => nil, "printed_description" => losartana.label, "quantity" => "30.00", "quantity_unit" => "comprimido",
        "dosage_instructions" => "1 comprimido a cada 12 horas", "continuous" => false, "controlled" => false, "retention_required" => false,
        "valid_until" => (today + 30).iso8601, "expired" => false, "dispensed_total" => "0.00", "last_dispensed_on" => nil, "next_allowed_on" => nil,
        "completed" => false
      )

      display = ClinicalDocuments::Codes.display(document.short_code)
      [ display, display.downcase, display.tr("-", " ") ].each do |typed|
        lookup(short_code: typed)
        expect([ typed, response.status, json_body.dig("prescriptions", 0, "id") ]).to eq([ typed, 200, document.id ])
      end
    end

    it "receita do 19c emitida em PAPEL também é dispensável" do
      document = pharmacy_prescription!(consultation: consultation, issue_mode: "paper")
      by_code(document)
      expect(response).to have_http_status(:ok)
      expect(json_body["prescriptions"].sole).to include("kind" => "digital", "id" => document.id, "cancelled" => false, "expired" => false)
    end

    it "receita cancelada vem com cancelled: true" do
      document = pharmacy_prescription!(consultation: consultation, cancelled: true)
      by_code(document)
      expect(response).to have_http_status(:ok)
      expect(json_body["prescriptions"].sole).to include("id" => document.id, "cancelled" => true)
    end

    it "atestado, registro de notificação (controlled_notification_record) e código desconhecido → 404 prescription_not_found" do
      sick_note = pharmacy_prescription!(consultation: consultation, kind: "sick_note", content: { "type" => "leave", "days" => 1 })
      notification = pharmacy_prescription!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper", items: [])
      unknown = ClinicalDocuments::Codes.short_code
      [ sick_note.short_code, notification.short_code, unknown ].each do |code|
        lookup(short_code: code)
        expect([ code, response.status, json_body ]).to eq([ code, 404, { "error" => "prescription_not_found" } ])
      end
      expect(trail).to be_empty
    end

    it "código fora do formato do 19c → 422 invalid_request com path short_code e problems" do
      [ "ABC", "0O1IL0O1IL", 123, "", [ "x" ] ].each do |code|
        lookup(short_code: code)
        expect([ code, response.status, json_body ]).to eq([ code, 422, refusal("invalid_request", "short_code") ])
      end
    end
  end

  describe "validade e retirada POR ITEM" do
    it "valid_until e expired por item; no topo o maior prazo, e expirada só quando TODOS vencem" do
      both = [ { catalog: losartana }, { catalog: amoxicilina, continuous: true } ]
      # 40 dias atrás: o comum (30 dias) venceu; o contínuo (180) não.
      document = pharmacy_prescription!(consultation: consultation, items: both, issued_at: late_evening(40))
      issued_on = late_evening(40).in_time_zone(city.time_zone).to_date
      by_code(document)
      view = json_body["prescriptions"].sole
      expect(view["issued_on"]).to eq(issued_on.iso8601)
      expect(view["items"].map { |row| row.values_at("valid_until", "expired") }).to eq([ [ (issued_on + 30).iso8601, true ], [ (issued_on + 180).iso8601, false ] ])
      expect(view.values_at("valid_until", "expired")).to eq([ (issued_on + 180).iso8601, false ])

      # 200 dias atrás: os dois venceram.
      old = pharmacy_prescription!(consultation: consultation, items: both, issued_at: late_evening(200))
      by_code(old)
      expect(json_body["prescriptions"].sole["items"].pluck("expired")).to eq([ true, true ])
      expect(json_body["prescriptions"].sole["expired"]).to be(true)
    end

    it "o dia da validade ainda vale; o dia seguinte vence (23:30 local é o dia seguinte em UTC)" do
      on_edge = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(30))
      past = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(31))
      expect(on_edge.issued_at.utc.to_date).to eq(today - 29) # em UTC já é outro dia; a conta é do dia da cidade
      by_code(on_edge)
      expect(json_body["prescriptions"].sole.values_at("valid_until", "expired")).to eq([ today.iso8601, false ])
      by_code(past)
      expect(json_body["prescriptions"].sole.values_at("valid_until", "expired")).to eq([ (today - 1).iso8601, true ])
    end

    it "valid_until explícito do conteúdo do 19c vale para todos os itens; a mudança do prazo da cidade vale na hora" do
      document = pharmacy_prescription!(consultation: consultation, content: { "valid_until" => (today + 7).iso8601 },
                                        items: [ { catalog: losartana }, { catalog: amoxicilina, continuous: true } ])
      by_code(document)
      expect(json_body["prescriptions"].sole["items"].pluck("valid_until")).to eq([ (today + 7).iso8601 ] * 2)

      sem_prazo = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(0))
      PharmacySetting.find(1).update!(common_validity_days: 60)
      by_code(sem_prazo)
      expect(json_body["prescriptions"].sole["valid_until"]).to eq((today + 60).iso8601)
    end

    it "total dispensado, última retirada no dia da cidade e next_allowed_on só do item contínuo, contados por item" do
      document = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana, continuous: true },
                                                                           { catalog: amoxicilina, continuous: true },
                                                                           { catalog: paracetamol } ])
      continuous, other_continuous, plain = document.prescription_items.to_a
      # 01:30 UTC de 21/10 = 22:30 de 20/10 em São Paulo.
      first_at = Time.utc(today.year, today.month, today.day, 1, 30) - 10.days
      dispense!(document, continuous, quantity: "10", at: first_at - 20.days)
      dispense!(document, continuous, quantity: "20.50", at: first_at)
      dispense!(document, plain, quantity: "5", at: first_at)
      dispense!(document, plain, quantity: "5", at: first_at + 1.day, completes: true)
      by_code(document)
      rows = json_body["prescriptions"].sole["items"].index_by { |row| row["id"] }
      last_day = first_at.in_time_zone(city.time_zone).to_date
      expect(last_day).to eq(first_at.utc.to_date - 1)
      expect(rows.fetch(continuous.id).values_at("dispensed_total", "last_dispensed_on", "next_allowed_on", "completed"))
        .to eq([ "30.50", last_day.iso8601, (last_day + 25).iso8601, false ])
      expect(rows.fetch(other_continuous.id).values_at("dispensed_total", "last_dispensed_on", "next_allowed_on", "completed"))
        .to eq([ "0.00", nil, nil, false ])
      expect(rows.fetch(plain.id).values_at("dispensed_total", "next_allowed_on", "completed")).to eq([ "10.00", nil, true ])
    end

    it "externa controlada vale 30 dias fixos mesmo contínua; a comum contínua, 180" do
      controlled = external!(items: [ { catalog: diazepam, continuous: true }, { catalog: losartana, continuous: true } ], notification_number: "PR-2026-000123")
      lookup(patient_id: patient.id)
      view = json_body["prescriptions"].sole
      expect(view["kind"]).to eq("external")
      expect(view["items"].map { |row| row.values_at("controlled", "valid_until") }).to eq([ [ true, (today + 30).iso8601 ], [ false, (today + 180).iso8601 ] ])
      expect(view["valid_until"]).to eq((today + 180).iso8601)
      expect(controlled.items.size).to eq(2)
    end
  end

  describe "retention_required (H6, H12)" do
    def retention(document) = (by_code(document) && json_body["prescriptions"].sole["items"].pluck("retention_required"))

    it "antimicrobiano do catálogo da plataforma, controlado e controle especial exigem; o comum não" do
      amoxicilina.update!(antimicrobial: true)
      expect(retention(pharmacy_prescription!(consultation: consultation, items: [ { catalog: amoxicilina } ]))).to eq([ true ])
      expect(retention(pharmacy_prescription!(consultation: consultation, items: [ { catalog: diazepam } ]))).to eq([ true ])
      special = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana }, { catalog: paracetamol } ],
                                       content: { "category" => "special_control" })
      expect(retention(special)).to eq([ true, true ])
      expect(retention(pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana }, { catalog: paracetamol } ]))).to eq([ false, false ])
      # por item: só o antimicrobiano do documento comum
      mixed = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana }, { catalog: amoxicilina } ])
      expect(retention(mixed)).to eq([ false, true ])
    end

    it "lê o catálogo atual: tirar a marca do antimicrobiano tira a exigência; a controlada da externa vale pelo retrato" do
      document = pharmacy_prescription!(consultation: consultation, items: [ { catalog: amoxicilina } ])
      amoxicilina.update!(antimicrobial: true)
      expect(retention(document)).to eq([ true ])
      amoxicilina.update!(antimicrobial: false)
      expect(retention(document)).to eq([ false ])

      amoxicilina.update!(antimicrobial: true)
      external!(items: [ { catalog: amoxicilina }, { catalog: diazepam }, { catalog: losartana } ], notification_number: "PR-1")
      lookup(patient_id: patient.id)
      externals = json_body["prescriptions"].select { |row| row["kind"] == "external" }.sole
      expect(externals["items"].pluck("retention_required")).to eq([ true, true, false ])
    end
  end

  describe "POST /pharmacy/prescriptions/lookup — por paciente" do
    it "lista a digital e a externa, mais novas primeiro; canceladas e vencidas marcadas; o registro de notificação não é receita" do
      older = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(60))
      newer = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(5))
      cancelled = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(3), cancelled: true)
      pharmacy_prescription!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper", items: [], issued_at: late_evening(2))
      pharmacy_prescription!(consultation: consultation, kind: "sick_note", content: { "type" => "leave", "days" => 1 }, items: [])
      external = external!(issued_on: today - 1)
      lookup(patient_id: patient.id)
      expect(response).to have_http_status(:ok)
      rows = json_body["prescriptions"]
      expect(rows.map { |row| [ row["kind"], row["id"] ] }).to eq([ [ "external", external.id ], [ "digital", cancelled.id ], [ "digital", newer.id ], [ "digital", older.id ] ])
      expect(rows.pluck("cancelled")).to eq([ false, true, false, false ])
      expect(rows.pluck("expired")).to eq([ false, false, false, true ]) # 60 dias atrás, prazo de 30
      expect(rows.map { |row| row["patient"]["id"] }.uniq).to eq([ patient.id ])
    end

    it "só os últimos 365 dias (digital e externa) e até LOOKUP_MAX, as mais novas" do
      pharmacy_prescription!(consultation: consultation, issued_at: late_evening(366))
      inside = pharmacy_prescription!(consultation: consultation, issued_at: late_evening(364))
      external!(issued_on: today - 366)
      lookup(patient_id: patient.id)
      expect(json_body["prescriptions"].pluck("id")).to eq([ inside.id ])

      stub_const("Pharmacy::Catalog::LOOKUP_MAX", 2)
      newest = [ 1, 2, 3 ].map { |days| pharmacy_prescription!(consultation: consultation, issued_at: late_evening(days)) }
      lookup(patient_id: patient.id)
      expect(json_body["prescriptions"].pluck("id")).to eq([ newest[0].id, newest[1].id ])
    end

    it "paciente sem receita → lista vazia e nenhuma trilha; paciente inexistente → 422 patient_id" do
      lookup(patient_id: patient.id)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("prescriptions" => [])
      expect(trail).to be_empty
      [ SecureRandom.uuid, "x", 5 ].each do |value|
        lookup(patient_id: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      end
    end

    it "short_code e patient_id juntos, ou nenhum dos dois → 422 invalid_request" do
      document = pharmacy_prescription!(consultation: consultation)
      lookup(short_code: document.short_code, patient_id: patient.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      lookup({})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "short_code") ])
    end
  end

  describe "quem pode e o que fica fora do corpo e do log" do
    let!(:document) { pharmacy_prescription!(consultation: consultation) }

    it "short_code, patient_id e qualquer chave na query → 422 invalid_request com o path; nada lido da URL; sem trilha" do
      post "/pharmacy/prescriptions/lookup?short_code=#{document.short_code}", params: { location_id: farmacia.id }.to_json, headers: json_headers
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "short_code") ])
      post "/pharmacy/prescriptions/lookup?patient_id=#{patient.id}", params: { location_id: farmacia.id, short_code: document.short_code }.to_json,
                                                                       headers: json_headers
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      expect(trail).to be_empty
    end

    it "auxiliar também busca; almoxarife, local central, sem papel, papel revogado e local inativo → 403 sozinho" do
      sign_in_as(assistant)
      by_code(document)
      expect(response).to have_http_status(:ok)

      sign_in_as(keeper)
      by_code(document)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(pharmacy_staff!(central, "pharmacist"))
      by_code(document, location_id: central.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(doctor!(unit))
      by_code(document)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      revoked = pharmacy_staff!(farmacia, "pharmacist")
      Membership.where(user: revoked, role: "pharmacist").update_all(revoked_at: Time.current)
      sign_in_as(revoked)
      by_code(document)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(pharmacist)
      farmacia.update!(active: false)
      by_code(document)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(trail.size).to eq(1) # só a busca da auxiliar, a única que passou
    end

    it "sem sessão → 401; location_id ausente ou inexistente → 422 location_id; interruptor desligado → 403 feature_disabled" do
      cookies.delete("session_id")
      by_code(document)
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(pharmacist)
      post_json("/pharmacy/prescriptions/lookup", { short_code: document.short_code })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      post_json("/pharmacy/prescriptions/lookup", { location_id: SecureRandom.uuid, short_code: document.short_code })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      disable_pharmacy!
      by_code(document)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end

    it "uma trilha clinical_record.viewed (access pharmacy) por leitura, só com ids; e nada na lista de três receitas a mais" do
      pharmacy_prescription!(consultation: consultation)
      pharmacy_prescription!(consultation: consultation)
      by_code(document)
      expect(trail).to eq([ { "patient_id" => patient.id, "user_id" => pharmacist.id, "access" => "pharmacy", "reason_code" => nil,
                              "person_ref" => "patient:#{patient.id}" } ])
      lookup(patient_id: patient.id)
      expect(json_body["prescriptions"].size).to eq(3)
      expect(trail.size).to eq(2) # uma por leitura, não por receita
    end

    it "o corpo nunca traz CPF, CNS nem patient_identification; paciente sem CPF sai com has_cpf e cns_masked" do
      identification = { "patient_identification" => { "address" => "Rua das Flores, 100", "weight_kg" => "70" } }
      with_identification = pharmacy_prescription!(consultation: consultation, content: identification)
      by_code(with_identification)
      expect(response.body).not_to include("patient_identification", "Rua das Flores", patient.cpf)
      expect(json_body["prescriptions"].sole["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => nil)

      typed = registry_no_cpf_patient!(cns: valid_cns(1))
      external!(typed)
      lookup(patient_id: typed.id)
      expect(response.body).not_to include(typed.cns, patient.cpf)
      expect(json_body["prescriptions"].sole["patient"]).to eq("id" => typed.id, "display_name" => typed.display_name, "has_cpf" => false,
                                                              "cns_masked" => typed.cns_masked)
      expect(typed.cns_masked).to end_with(typed.cns[-4..])
    end

    it "o log da requisição e a trilha não levam código, nome, CPF nem medicamento" do
      log = capture_log { by_code(document) }
      payloads = DomainEvent.where(name: "clinical_record.viewed").pluck(:payload).to_json
      [ document.short_code, ClinicalDocuments::Codes.display(document.short_code), patient.display_name, patient.cpf, losartana.active_ingredient ].each do |secret|
        expect(log).not_to include(secret)
        expect(payloads).not_to include(secret)
      end
    end

    it "30 por minuto por usuário: a 31ª busca → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { lookup(short_code: ClinicalDocuments::Codes.short_code) }
      expect(response).to have_http_status(:not_found)
      lookup(short_code: ClinicalDocuments::Codes.short_code)
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end
  end

  describe "Pharmacy::Prescription" do
    it "inspect, to_s, pretty_print e as_json só levam kind e id" do
      document = pharmacy_prescription!(consultation: consultation)
      prescription = Pharmacy::Prescription.find(kind: "digital", id: document.id, settings: Pharmacy::Settings.current)
      item = prescription.items.first
      texts = [ prescription.inspect, prescription.to_s, PP.pp(prescription, +""), prescription.as_json.to_json, item.inspect, item.to_s,
                PP.pp(item, +""), item.as_json.to_json ].join(" ")
      [ patient.display_name, patient.cpf, losartana.active_ingredient, "comprimido", "12 horas" ].each { |secret| expect(texts).not_to include(secret) }
      expect(texts).to include(document.id, item.id)
      expect(Pharmacy::Prescription.find(kind: "digital", id: SecureRandom.uuid, settings: Pharmacy::Settings.current)).to be_nil
      expect(Pharmacy::Prescription.find(kind: "digital", id: "x", settings: Pharmacy::Settings.current)).to be_nil
    end
  end

  describe "POST /pharmacy/person_lookup" do
    def person_lookup(body = {}, query: "", **fields) = post("/pharmacy/person_lookup#{query}", params: body.merge(fields).to_json, headers: json_headers)
    def person_shape(person) = { "patient_id" => person.id, "display_name" => person.display_name, "has_cpf" => person.cpf.present?, "cns_masked" => person.cns_masked }

    it "paciente pelo CPF: id, nome, has_cpf e cns_masked; trilha por pessoa" do
      existing = registry_patient!
      person_lookup(cpf: existing.cpf)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(person_shape(existing))
      expect(trail).to eq([ { "patient_id" => existing.id, "user_id" => pharmacist.id, "access" => "pharmacy", "reason_code" => nil,
                              "person_ref" => "patient:#{existing.id}" } ])
      person_lookup(cpf: existing.cpf.sub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\\1.\\2.\\3-\\4'))
      expect(json_body).to eq(person_shape(existing))
    end

    it "par validado sem paciente: cria o paciente aqui (patient.created) e devolve o id" do
      citizen = verified_citizen!(14)
      expect(Patient.where(cpf: citizen.cpf)).to be_empty
      expect { person_lookup(cpf: citizen.cpf) }.to change(Patient, :count).by(1)
      created = Patient.find_by!(cpf: citizen.cpf)
      expect(json_body).to eq(person_shape(created))
      expect(citizen.reload.patient_id).to eq(created.id)
      expect(DomainEvent.where(name: "patient.created").last.payload).to include("patient_id" => created.id, "citizen_id" => citizen.id)
      expect(trail.pluck("patient_id")).to eq([ created.id ])
      expect { person_lookup(cpf: citizen.cpf) }.not_to change(Patient, :count)
      expect(json_body["patient_id"]).to eq(created.id)
    end

    it "paciente sem CPF pelo CNS: has_cpf false e cns_masked; o CNS inteiro nunca volta" do
      typed = registry_no_cpf_patient!(cns: valid_cns(2))
      person_lookup(cns: typed.cns)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(person_shape(typed))
      expect(json_body).to include("has_cpf" => false)
      expect(json_body["cns_masked"]).to eq("*** **** **** #{typed.cns[-4..]}")
      expect(response.body).not_to include(typed.cns)
      person_lookup(cns: typed.cns.scan(/\d{1,5}/).join(" "))
      expect(json_body["patient_id"]).to eq(typed.id)
    end

    it "par só declarado → 409 citizen_not_verified; ninguém → 404 person_not_found; nenhuma trilha nem paciente criado" do
      declared = screening_citizen!(15)
      expect { person_lookup(cpf: declared.cpf) }.not_to change(Patient, :count)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
      person_lookup(cpf: valid_cpf(9_999))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      person_lookup(cns: valid_cns(3))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      expect(trail).to be_empty
    end

    it "CPF ou CNS inválido → 422 com problems; os dois ou nenhum → 422 invalid_request" do
      [ "123", 12_345, "529.982.247-26" ].each do |cpf|
        person_lookup(cpf: cpf)
        expect([ cpf, response.status, json_body ]).to eq([ cpf, 422, refusal("invalid_cpf", "cpf") ])
      end
      [ "123", 700_000_000_000_000, "700000000000000" ].each do |cns|
        person_lookup(cns: cns)
        expect([ cns, response.status, json_body ]).to eq([ cns, 422, refusal("invalid_cns", "cns") ])
      end
      person_lookup(cpf: valid_cpf(1), cns: valid_cns(1))
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cns") ])
      person_lookup({})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      expect(trail).to be_empty
    end

    it "CPF ou CNS na query → 422 invalid_request, nada lido da URL; sem papel de dispensação → 403" do
      existing = registry_patient!
      person_lookup({}, query: "?cpf=#{existing.cpf}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      person_lookup({ cpf: existing.cpf }, query: "?x=1")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "x") ])
      expect(trail).to be_empty

      [ keeper, doctor!(unit), pharmacy_staff!(central, "pharmacist") ].each do |user|
        sign_in_as(user)
        person_lookup(cpf: existing.cpf)
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
      sign_in_as(assistant)
      person_lookup(cpf: existing.cpf)
      expect(response).to have_http_status(:ok)
    end

    it "30 por minuto por usuário: a 31ª → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { person_lookup(cpf: valid_cpf(9_998)) }
      expect(response).to have_http_status(:not_found)
      person_lookup(cpf: valid_cpf(9_998))
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end
  end

  describe "POST /pharmacy/patients/duplicates" do
    def duplicates(body = {}, query: "", **fields) = post("/pharmacy/patients/duplicates#{query}", params: body.merge(fields).to_json, headers: json_headers)

    let!(:twin) do
      Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male", mother_name: "Rita Souza Lima")
    end

    it "candidatos pelo nome e nascimento e pela mãe; a forma do módulo 25; trilha por candidato" do
      other_mother = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male",
                                     mother_name: "Ana Maria Lima")
      no_cpf = registry_no_cpf_patient!(cns: valid_cns(4)).tap { |typed| typed.update!(full_name: "José Souza Lima", birth_date: "1960-02-01") }
      duplicates(full_name: "Jose Souza-Lima", birth_date: "1960-02-01")
      expect(response).to have_http_status(:ok)
      expect(json_body["candidates"]).to contain_exactly(
        { "patient_id" => twin.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true },
        { "patient_id" => other_mother.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => true },
        { "patient_id" => no_cpf.id, "display_name" => "José Souza Lima", "birth_date" => "1960-02-01", "has_cpf" => false }
      )
      expect(trail.pluck("patient_id")).to match_array([ twin.id, other_mother.id, no_cpf.id ])
      expect(trail.map { |payload| payload.values_at("access", "user_id", "reason_code") }.uniq).to eq([ [ "pharmacy", pharmacist.id, nil ] ])
      expect(response.body).not_to include(twin.cpf, "Rita")

      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: "rita souza lima")
      expect(json_body["candidates"].pluck("patient_id")).to match_array([ twin.id, no_cpf.id ])
    end

    it "sem candidato → lista vazia e nenhuma trilha; no máximo 10 candidatos" do
      duplicates(full_name: "Fulano Inexistente", birth_date: "1990-01-01")
      expect(json_body).to eq("candidates" => [])
      expect(trail).to be_empty
      11.times { Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "1960-02-01", sex: "male") }
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01")
      expect(json_body["candidates"].size).to eq(10)
      expect(trail.size).to eq(10)
    end

    it "dado na query, nome ou data inválidos → 422 invalid_request com path e problems; sem papel de dispensação → 403" do
      duplicates({}, query: "?full_name=Jos%C3%A9+Souza+Lima&birth_date=1960-02-01")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "full_name") ])
      duplicates(birth_date: "1960-02-01")
      expect(json_body).to eq(refusal("invalid_request", "full_name"))
      duplicates(full_name: "José Souza Lima", birth_date: "01/02/1960")
      expect(json_body).to eq(refusal("invalid_request", "birth_date"))
      duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01", mother_name: 5)
      expect(json_body).to eq(refusal("invalid_request", "mother_name"))
      expect(trail).to be_empty

      [ keeper, doctor!(unit) ].each do |user|
        sign_in_as(user)
        duplicates(full_name: "José Souza Lima", birth_date: "1960-02-01")
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      end
    end

    it "30 por minuto por usuário: a 31ª → 429" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      30.times { duplicates(full_name: "Fulano Inexistente", birth_date: "1990-01-01") }
      expect(response).to have_http_status(:ok)
      duplicates(full_name: "Fulano Inexistente", birth_date: "1990-01-01")
      expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    end
  end
end
