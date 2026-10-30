require "rails_helper"

# Módulo 27a, Task 10 (ADR 0045; contrato §7, H3, H6, H12): a receita externa
# digitada na farmácia. Paciente existente ou digitado (`new_patient`, a forma do
# 24a, com `duplicates_reviewed`), prescritor, data e itens do catálogo. Todo 422
# junta TODAS as recusas em `problems`; o 403 de papel vem sozinho. A resposta é a
# <prescription_view>, com trilha clinical_record.viewed por pessoa e o evento
# external_prescription.recorded (só ids). Dado pessoal só no corpo JSON.
RSpec.describe "Farmácia — receita externa", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:today) { Time.use_zone(city.time_zone) { Time.zone.today } }
  let!(:person) { registry_patient! }
  let(:notif) { "PR-2026-000123" }
  let(:amoxicilina_teste) { controlled_item!(code: 9_900_010, ingredient: "AMOXICILINA TESTE", antimicrobial: true, strength: "500 mg") }

  def post_json(path, body, query: "") = post("#{path}#{query}", params: body.to_json, headers: json_headers)
  def prescriber(**over) = { name: "Dra. Beltrana Souza", council: "CRM", council_state: "PR", council_number: "54321" }.merge(over)
  def line(item = losartana, **over)
    { catalog_item_id: item.id, quantity: "30", quantity_unit: "comprimido", dosage_instructions: "1 comprimido ao dia", continuous: false }.merge(over)
  end
  def record(body = nil, location: farmacia, query: "", **fields)
    base = { location_id: location.id, patient_id: person.id, prescriber: prescriber, issued_on: today.iso8601, items: [ line ] }
    post_json("/pharmacy/external_prescriptions", base.merge(body || {}).merge(fields), query: query)
  end
  def new_patient(**over)
    { full_name: "Carlos Eduardo Pereira", birth_date: "1985-03-12", sex: "male", no_cpf_reason: "3" }.merge(over)
  end
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload).select { |payload| payload["access"] == "pharmacy" }
  def events = DomainEvent.where(name: "external_prescription.recorded")
  def written = [ ExternalPrescription.count, ExternalPrescriptionItem.count, Patient.count, events.count, trail.size ]
  def problems = json_body["problems"]

  describe "o caminho feliz e a forma da <prescription_view>" do
    before { sign_in_as(pharmacist) }

    it "farmacêutica registra DIAZEPAM B1 com o número da notificação: 201, controlado, 30 dias fixos, retenção exigida" do
      record(items: [ line(diazepam, quantity: "10", continuous: true) ], notification_number: notif, issued_on: (today - 2).iso8601)
      expect(response).to have_http_status(:created)
      view = json_body
      saved = ExternalPrescription.sole
      expect(view.except("items", "prescriber", "patient")).to eq(
        "kind" => "external", "id" => saved.id, "short_code" => nil, "issued_on" => (today - 2).iso8601, "valid_until" => (today + 28).iso8601,
        "expired" => false, "cancelled" => false
      )
      expect(view["prescriber"]).to eq("name" => "Dra. Beltrana Souza", "council" => "CRM-PR 54321")
      expect(view["patient"]).to eq("id" => person.id, "display_name" => person.display_name, "has_cpf" => true, "cns_masked" => nil)
      item = view["items"].sole
      expect(item).to eq(
        "id" => saved.items.sole.id, "catalog_item_id" => diazepam.id,
        "item" => { "catalog_item_id" => diazepam.id, "catmat_code" => diazepam.catmat_code, "name" => diazepam.label, "unit" => diazepam.unit,
                    "dispensing_unit" => Pharmacy::DispensingUnit.for(diazepam), "controlled" => true, "controlled_list" => "B1" },
        "free_text" => nil, "printed_description" => diazepam.label, "quantity" => "10.00", "quantity_unit" => "comprimido",
        "dosage_instructions" => "1 comprimido ao dia", "continuous" => true, "controlled" => true, "retention_required" => true,
        "valid_until" => (today + 28).iso8601, "expired" => false, "dispensed_total" => "0.00", "last_dispensed_on" => nil, "next_allowed_on" => nil,
        "completed" => false
      )
      expect(saved.attributes.slice("patient_id", "stock_location_id", "recorded_by_user_id", "prescriber_name", "council", "council_state", "council_number"))
        .to eq("patient_id" => person.id, "stock_location_id" => farmacia.id, "recorded_by_user_id" => pharmacist.id,
               "prescriber_name" => "Dra. Beltrana Souza", "council" => "CRM", "council_state" => "PR", "council_number" => "54321")
      expect(saved.notification_number).to eq(notif)
      row = saved.items.sole
      expect(row).to have_attributes(catalog_item_id: diazepam.id, catmat_code: diazepam.catmat_code, position: 1, quantity: BigDecimal("10"),
                                     quantity_unit: "comprimido", dosage_instructions: "1 comprimido ao dia", continuous: true, controlled_list: "B1")
    end

    it "controlado B1 emitido há 31 dias já nasce vencido, mesmo contínuo (30 dias fixos); há 30 dias ainda vale" do
      record(items: [ line(diazepam, continuous: true) ], notification_number: notif, issued_on: (today - 31).iso8601)
      expect([ response.status, json_body ]).to eq([ 422, refusal("prescription_expired", "issued_on") ])
      record(items: [ line(diazepam, continuous: true) ], notification_number: notif, issued_on: (today - 30).iso8601)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("valid_until" => today.iso8601, "expired" => false)
    end

    it "controlado de lista C1 (sem notificação) também vale 30 dias e exige retenção" do
      record(items: [ line(fluoxetina) ])
      expect(response).to have_http_status(:created)
      expect(json_body["items"].sole).to include("controlled" => true, "retention_required" => true, "valid_until" => (today + 30).iso8601)
      expect(ExternalPrescription.sole.notification_number).to be_nil
    end

    it "retention_required vem do catálogo (antimicrobiano ou controlado); quem digita não marca nada" do
      record(items: [ line(amoxicilina_teste).merge(retention_required: false, antimicrobial: false, controlled: false), line(losartana) ])
      expect(response).to have_http_status(:created)
      amox, losa = json_body["items"]
      expect(amox).to include("retention_required" => true, "controlled" => false)
      expect(losa).to include("retention_required" => false, "controlled" => false)
      expect(ExternalPrescriptionItem.find(amox["id"]).controlled_list).to be_nil
    end

    it "quantidade até 99999.99 vale; um centavo a mais não" do
      record(items: [ line(losartana, quantity: "99999.99") ])
      expect(response).to have_http_status(:created)
      expect(json_body["items"].sole["quantity"]).to eq("99999.99")
      record(items: [ line(losartana, quantity: "100000") ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "items[0].quantity") ])
    end

    it "uso contínuo comum vale 180 dias (parâmetro da cidade) e o comum 30" do
      record(items: [ line(losartana, continuous: true), line(losartana) ])
      expect(response).to have_http_status(:created)
      continuous, common = json_body["items"]
      expect(continuous).to include("continuous" => true, "valid_until" => (today + 180).iso8601)
      expect(common).to include("continuous" => false, "valid_until" => (today + 30).iso8601)
      expect(json_body["valid_until"]).to eq((today + 180).iso8601)
    end

    it "grava a trilha clinical_record.viewed (access pharmacy) da pessoa e o evento com só os ids" do
      record
      saved = ExternalPrescription.sole
      expect(trail).to eq([ { "patient_id" => person.id, "user_id" => pharmacist.id, "access" => "pharmacy", "reason_code" => nil,
                              "person_ref" => "patient:#{person.id}" } ])
      expect(events.sole.payload).to eq("external_prescription_id" => saved.id, "user_id" => pharmacist.id)
    end

    it "a requisição e o evento não levam número da notificação, prescritor, posologia nem o paciente" do
      log = capture_log do
        record({ items: [ line(diazepam, dosage_instructions: "Tomar um comprimido à noite antes de dormir") ], notification_number: notif })
      end
      secrets = [ notif, "Beltrana", "54321", person.display_name, person.cpf, "antes de dormir" ]
      parameters = log.lines.grep(/Parameters|Started POST/).join
      secrets.each { |secret| expect(parameters).not_to include(secret) }
      payloads = DomainEvent.where(name: %w[external_prescription.recorded clinical_record.viewed]).pluck(:payload).to_json
      secrets.each { |secret| expect(payloads).not_to include(secret) }
      expect(parameters).to include("FILTERED")
    end
  end

  describe "papéis" do
    it "auxiliar registrando DIAZEPAM → 403 controlled_requires_pharmacist, sozinho, e nada gravado" do
      sign_in_as(assistant)
      before = written
      record(items: [ line(diazepam) ], notification_number: notif)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])
      expect(written).to eq(before)
    end

    it "o 403 vem sozinho mesmo com outras recusas (prescritor, data, outro item inválido) e sem o número da notificação" do
      sign_in_as(assistant)
      record(items: [ line(losartana, quantity: "1,5"), line(fluoxetina) ], prescriber: prescriber(council: "CRF"), issued_on: (today + 1).iso8601)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])
    end

    it "auxiliar com LOSARTANA contínua para paciente sem CPF criado por new_patient (no_cpf_reason) → 201, has_cpf false" do
      sign_in_as(assistant)
      expect { record({ patient_id: nil, new_patient: new_patient, items: [ line(losartana, continuous: true) ] }) }.to change(Patient, :count).by(1)
      expect(response).to have_http_status(:created)
      created = Patient.where.not(id: person.id).sole
      expect(created.full_name).to eq("Carlos Eduardo Pereira")
      expect(json_body["patient"]).to eq("id" => created.id, "display_name" => created.display_name, "has_cpf" => false, "cns_masked" => nil)
      expect(created.no_cpf_reason).to eq("3")
      expect(ExternalPrescription.sole.patient_id).to eq(created.id)
      expect(json_body["items"].sole).to include("continuous" => true, "controlled" => false)
      expect(DomainEvent.where(name: "patient.created").last.payload).to include("patient_id" => created.id, "user_id" => assistant.id)
      expect(trail.pluck("patient_id")).to eq([ created.id ])
    end

    it "auxiliar registra antimicrobiano (não controlado), sem notificação" do
      sign_in_as(assistant)
      record(items: [ line(amoxicilina_teste) ])
      expect(response).to have_http_status(:created)
      expect(json_body["items"].sole).to include("retention_required" => true, "controlled" => false)
    end

    it "almoxarife do central, auxiliar de outro local, local central e local inexistente → 403/422 sozinhos" do
      sign_in_as(keeper)
      record
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      record({}, location: central)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      other = unit_location!
      sign_in_as(assistant)
      record({}, location: other)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      sign_in_as(pharmacist)
      post_json("/pharmacy/external_prescriptions", { location_id: SecureRandom.uuid, patient_id: person.id })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
      expect(written.first(4)).to eq([ 0, 0, Patient.count, 0 ])
    end

    it "farmacêutico com a Membership revogada, local inativo e sem sessão" do
      sign_in_as(pharmacist)
      farmacia.update!(active: false)
      record
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      farmacia.update!(active: true)
      Membership.where(user: pharmacist, role: "pharmacist").update_all(revoked_at: Time.current)
      record
      expect(response).to have_http_status(:forbidden)
      reset!
      use_test_city_host!
      record
      expect(response).to have_http_status(:unauthorized)
    end

    it "interruptor desligado → 403 feature_disabled" do
      sign_in_as(pharmacist)
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      record
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end

    it "qualquer chave na query → 422 invalid_request com o path (só o nome da chave)" do
      sign_in_as(pharmacist)
      record({}, query: "?notification_number=#{notif}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "notification_number") ])
      expect(ExternalPrescription.count).to eq(0)
    end
  end

  describe "paciente" do
    before { sign_in_as(pharmacist) }

    it "os dois ou nenhum → 422 invalid_request path patient_id; id desconhecido ou fora do formato também" do
      [ { patient_id: person.id, new_patient: new_patient }, { patient_id: nil }, { patient_id: SecureRandom.uuid }, { patient_id: "x" },
        { patient_id: 7 } ].each do |over|
        record(over)
        expect([ over, response.status, json_body ]).to eq([ over, 422, refusal("invalid_request", "patient_id") ])
      end
      expect(written.first(4)).to eq([ 0, 0, Patient.count, 0 ])
    end

    # Herdado da revisão da Task 10: o paciente existe na validação e some antes
    # da gravação (patient_for) → a mesma recusa da validação, com problems.
    it "paciente sumido entre a validação e a gravação → 422 invalid_request patient_id com problems; nada gravado" do
      allow(Patient).to receive(:find_by).and_call_original
      allow(Patient).to receive(:find_by).with(id: person.id).and_return(nil)
      record
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      expect(written.first(2)).to eq([ 0, 0 ])
    end

    it "new_patient que não é objeto → 422 path new_patient" do
      record(patient_id: nil, new_patient: "Carlos")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "new_patient") ])
    end

    it "new_patient com nome inválido → 422 path new_patient.full_name (nada é criado)" do
      expect { record(patient_id: nil, new_patient: new_patient(full_name: "X")) }.not_to change(Patient, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_patient", "path" => "new_patient.full_name",
                              "problems" => [ { "path" => "new_patient.full_name", "error" => "invalid_patient" } ])
    end

    it "new_patient: CPF e CNS inválidos, sem CPF nem justificativa → o path da recusa com o prefixo new_patient." do
      { { cpf: "123.456.789-00", no_cpf_reason: nil } => [ "invalid_cpf", "new_patient.cpf" ],
        { cns: "123" } => [ "invalid_cns", "new_patient.cns" ],
        { no_cpf_reason: nil } => [ "cpf_or_reason_required", "new_patient.no_cpf_reason" ] }.each do |over, (error, path)|
        record(patient_id: nil, new_patient: new_patient(**over))
        expect([ over, response.status, json_body ]).to eq([ over, 422, refusal(error, path) ])
      end
      expect(Patient.where.not(id: person.id)).to be_empty
    end

    it "new_patient com CPF válido cria o paciente com CPF" do
      cpf = valid_cpf(412)
      record(patient_id: nil, new_patient: new_patient(cpf: cpf, no_cpf_reason: nil))
      expect(response).to have_http_status(:created)
      expect(json_body["patient"]).to include("has_cpf" => true)
      expect(Patient.find_by!(cpf: cpf).full_name).to eq("Carlos Eduardo Pereira")
    end

    it "CNS de outro paciente → 409 cns_taken e nada gravado; CPF de outro → 409 cpf_taken" do
      taken = registry_no_cpf_patient!(cns: valid_cns(900))
      before = written
      record(patient_id: nil, new_patient: new_patient(cns: taken.cns))
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cns_taken", "path" => "new_patient.cns" } ])
      record(patient_id: nil, new_patient: new_patient(cpf: person.cpf, no_cpf_reason: nil, full_name: "Maria Outra Pessoa"))
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cpf_taken", "path" => "new_patient.cpf" } ])
      expect(written).to eq(before)
    end

    it "suspeita de duplicado (mesmo nome e nascimento) → 409 duplicate_suspected, sem nome e nada gravado" do
      existing = registry_no_cpf_patient!
      expect(existing.full_name).to eq("Lia Santos")
      before = written
      record(patient_id: nil, new_patient: new_patient(full_name: "Lia Santos", birth_date: "2026-08-01"))
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "duplicate_suspected" } ])
      expect(response.body).not_to include("Lia", existing.id)
      expect(written).to eq(before)
    end

    it "com duplicates_reviewed: true cria o paciente mesmo assim; o campo só aceita booleano" do
      registry_no_cpf_patient!
      attrs = new_patient(full_name: "Lia Santos", birth_date: "2026-08-01")
      expect { record(patient_id: nil, new_patient: attrs, duplicates_reviewed: true) }.to change(Patient, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(Patient.all.select { |patient| patient.full_name == "Lia Santos" }.size).to eq(2)

      [ "true", 1, nil ].each do |value|
        record(patient_id: nil, new_patient: attrs, duplicates_reviewed: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("invalid_request", "duplicates_reviewed") ])
      end
    end

    it "com patient_id o paciente existente é usado e nenhum outro é criado" do
      expect { record }.not_to change(Patient, :count)
      expect(ExternalPrescription.sole.patient_id).to eq(person.id)
    end
  end

  describe "prescritor" do
    before { sign_in_as(pharmacist) }

    it "council CRF → 422 path prescriber.council; só CRM, CRO e COREN valem" do
      record(prescriber: prescriber(council: "CRF"))
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "prescriber.council") ])
      %w[CRM CRO COREN].each do |council|
        record(prescriber: prescriber(council: council))
        expect([ council, response.status ]).to eq([ council, 201 ])
      end
    end

    it "cada campo recusado com o seu path (nome 3..120, UF maiúscula de 2 letras, número só com dígitos até 10)" do
      { { name: "Ab" } => "prescriber.name", { name: "A" * 121 } => "prescriber.name", { name: 7 } => "prescriber.name",
        { name: "   " } => "prescriber.name", { council_state: "pr" } => "prescriber.council_state",
        { council_state: "PRR" } => "prescriber.council_state", { council_state: nil } => "prescriber.council_state",
        { council_number: "12a" } => "prescriber.council_number", { council_number: "12345678901" } => "prescriber.council_number",
        { council_number: 54_321 } => "prescriber.council_number", { council: nil } => "prescriber.council" }.each do |over, path|
        record(prescriber: prescriber(**over))
        expect([ over, response.status, json_body ]).to eq([ over, 422, refusal("invalid_request", path) ])
      end
      expect(ExternalPrescription.count).to eq(0)
    end

    it "prescritor ausente ou que não é objeto → 422 path prescriber; nome de 3 e de 120 letras vale" do
      [ nil, "Dra. Beltrana", [] ].each do |value|
        record(prescriber: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("invalid_request", "prescriber") ])
      end
      record(prescriber: prescriber(name: "Ana"))
      expect(response).to have_http_status(:created)
      record(prescriber: prescriber(name: "A" * 120))
      expect(response).to have_http_status(:created)
    end
  end

  describe "data da receita e validade" do
    before { sign_in_as(pharmacist) }

    it "issued_on de amanhã, fora do formato ou inexistente → 422 invalid_request path issued_on; hoje vale" do
      [ (today + 1).iso8601, "29/10/2026", "2026-02-30", 20_261_029, nil, "" ].each do |value|
        record(issued_on: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("invalid_request", "issued_on") ])
      end
      record(issued_on: today.iso8601)
      expect(response).to have_http_status(:created)
    end

    it "vencida só quando TODOS os itens já nascem vencidos: 31 dias, só itens comuns → prescription_expired path issued_on" do
      record(issued_on: (today - 31).iso8601, items: [ line(losartana), line(losartana, quantity: "10") ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("prescription_expired", "issued_on") ])
      expect(written.first(4)).to eq([ 0, 0, Patient.count, 0 ])
    end

    it "um item ainda vigente (contínuo, 180 dias) basta: a receita é gravada e o item comum sai expired: true" do
      record(issued_on: (today - 31).iso8601, items: [ line(losartana), line(losartana, continuous: true) ])
      expect(response).to have_http_status(:created)
      expect(json_body).to include("expired" => false, "valid_until" => (today + 149).iso8601)
      expect(json_body["items"].map { |item| item["expired"] }).to eq([ true, false ])
    end

    it "30 dias atrás um item comum ainda vale (vence só no dia seguinte)" do
      record(issued_on: (today - 30).iso8601)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("valid_until" => today.iso8601, "expired" => false)
    end

    it "com item inválido o limite é o maior prazo possível: 400 dias atrás já vence de qualquer jeito; 100 dias atrás, não" do
      record(issued_on: (today - 400).iso8601, items: [ line(losartana, catalog_item_id: SecureRandom.uuid) ])
      expect(json_body).to include("error" => "prescription_expired", "path" => "issued_on")
      expect(problems).to eq([ { "path" => "issued_on", "error" => "prescription_expired" },
                               { "path" => "items[0].catalog_item_id", "error" => "invalid_item" } ])
      record(issued_on: (today - 100).iso8601, items: [ line(losartana, catalog_item_id: SecureRandom.uuid) ])
      expect(problems).to eq([ { "path" => "items[0].catalog_item_id", "error" => "invalid_item" } ])
    end

    it "o prazo vem dos parâmetros da cidade, lidos na hora" do
      PharmacySetting.current.update!(common_validity_days: 10)
      record(issued_on: (today - 11).iso8601)
      expect([ response.status, json_body ]).to eq([ 422, refusal("prescription_expired", "issued_on") ])
      record(issued_on: (today - 10).iso8601)
      expect(response).to have_http_status(:created)
    end
  end

  describe "itens" do
    before { sign_in_as(pharmacist) }

    it "ausentes, vazios, mais de 20 ou que não são lista → 422 path items; 20 valem" do
      [ nil, [], "x", {}, Array.new(21) { line } ].each do |value|
        record(items: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "items") ])
      end
      record(items: Array.new(20) { line })
      expect(response).to have_http_status(:created)
      expect(json_body["items"].size).to eq(20)
      expect(ExternalPrescriptionItem.order(:position).pluck(:position)).to eq((1..20).to_a)
    end

    it "cada campo com o seu erro e o seu path" do
      cases = [
        [ { catalog_item_id: SecureRandom.uuid }, "invalid_item", "items[0].catalog_item_id" ],
        [ { catalog_item_id: "x" }, "invalid_item", "items[0].catalog_item_id" ],
        [ { catalog_item_id: nil }, "invalid_item", "items[0].catalog_item_id" ],
        [ { quantity: "1,5" }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity: 1.5 }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity: "0" }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity: "-2" }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity: "0.001" }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity: nil }, "invalid_quantity", "items[0].quantity" ],
        [ { quantity_unit: "" }, "invalid_request", "items[0].quantity_unit" ],
        [ { quantity_unit: "u" * 31 }, "invalid_request", "items[0].quantity_unit" ],
        [ { quantity_unit: 3 }, "invalid_request", "items[0].quantity_unit" ],
        [ { dosage_instructions: "ab" }, "invalid_request", "items[0].dosage_instructions" ],
        [ { dosage_instructions: "a" * 501 }, "invalid_request", "items[0].dosage_instructions" ],
        [ { dosage_instructions: nil }, "invalid_request", "items[0].dosage_instructions" ],
        [ { continuous: "sim" }, "invalid_request", "items[0].continuous" ],
        [ { continuous: 1 }, "invalid_request", "items[0].continuous" ]
      ]
      cases.each do |over, error, path|
        record(items: [ line(losartana, **over) ])
        expect([ over, response.status, json_body ]).to eq([ over, 422, refusal(error, path) ])
      end
      record(items: [ "x" ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "items[0]") ])
      expect(ExternalPrescription.count).to eq(0)
    end

    it "limites que valem: posologia de 3 e de 500, unidade de 1 e de 30, sem `continuous` é falso" do
      record(items: [ line(losartana, dosage_instructions: "abc"), line(losartana, dosage_instructions: "a" * 500, quantity_unit: "u" * 30),
                      line(losartana, quantity_unit: "u").except(:continuous) ])
      expect(response).to have_http_status(:created)
      expect(json_body["items"].map { |item| item["continuous"] }).to eq([ false, false, false ])
    end

    it "item do catálogo removido → invalid_item" do
      removed = controlled_item!(code: 9_900_011, ingredient: "ITEM REMOVIDO", strength: "5 mg")
      removed.update!(status: "removed")
      record(items: [ line(removed) ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_item", "items[0].catalog_item_id") ])
    end
  end

  describe "número da notificação" do
    before { sign_in_as(pharmacist) }

    it "item das listas A/B sem o número → 422 notification_required path notification_number, e nada gravado" do
      before = written
      record(items: [ line(diazepam) ])
      expect([ response.status, json_body ]).to eq([ 422, refusal("notification_required", "notification_number") ])
      [ nil, "" ].each do |value|
        record(items: [ line(diazepam) ], notification_number: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("notification_required", "notification_number") ])
      end
      expect(written).to eq(before)
    end

    it "formato inválido (espaço, símbolo, 31 caracteres, número JSON) → invalid_request path notification_number, com ou sem lista A/B" do
      [ "PR 2026", "PR#1", "A" * 31, 123, [ "x" ] ].each do |value|
        record(items: [ line(diazepam) ], notification_number: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("invalid_request", "notification_number") ])
        record(items: [ line(losartana) ], notification_number: value)
        expect([ value, response.status, json_body ]).to eq([ value, 422, refusal("invalid_request", "notification_number") ])
      end
      record(items: [ line(diazepam) ], notification_number: "A" * 30)
      expect(response).to have_http_status(:created)
    end

    it "receita sem lista A/B não exige número; se vier válido, é guardado" do
      record(items: [ line(losartana) ])
      expect(response).to have_http_status(:created)
      expect(ExternalPrescription.order(:created_at).last.notification_number).to be_nil
      record(items: [ line(losartana) ], notification_number: notif)
      expect(response).to have_http_status(:created)
      expect(ExternalPrescription.order(:created_at).last.notification_number).to eq(notif)
    end
  end

  describe "problems: todas as recusas de uma vez" do
    before { sign_in_as(pharmacist) }

    it "dois itens inválidos mais prescritor, data e paciente: a lista na ordem (paciente, prescritor, data, itens), erro e path do 1º no topo" do
      record(patient_id: nil, prescriber: prescriber(council: "CRF", council_number: "x"), issued_on: (today + 1).iso8601,
             items: [ line(losartana, quantity: "1,5", dosage_instructions: "a"), line(losartana, catalog_item_id: SecureRandom.uuid) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "patient_id")
      expect(problems).to eq([
        { "path" => "patient_id", "error" => "invalid_request" },
        { "path" => "prescriber.council", "error" => "invalid_request" },
        { "path" => "prescriber.council_number", "error" => "invalid_request" },
        { "path" => "issued_on", "error" => "invalid_request" },
        { "path" => "items[0].quantity", "error" => "invalid_quantity" },
        { "path" => "items[0].dosage_instructions", "error" => "invalid_request" },
        { "path" => "items[1].catalog_item_id", "error" => "invalid_item" }
      ])
    end

    it "só o prescritor inválido e dois itens inválidos: o 1º é prescriber.* e todos entram" do
      record(prescriber: prescriber(name: "A"), items: [ line(losartana, quantity: "0"), line(losartana, quantity_unit: "") ])
      expect(json_body).to include("error" => "invalid_request", "path" => "prescriber.name")
      expect(problems.pluck("path")).to eq([ "prescriber.name", "items[0].quantity", "items[1].quantity_unit" ])
    end

    it "new_patient inválido entra na lista junto das outras recusas (e nada é criado)" do
      expect do
        record(patient_id: nil, new_patient: new_patient(full_name: "X"), prescriber: prescriber(council: "CRF"),
               items: [ line(losartana, quantity: "0"), line(losartana, quantity: "-1") ])
      end.not_to change(Patient, :count)
      expect(json_body).to include("error" => "invalid_patient", "path" => "new_patient.full_name")
      expect(problems).to eq([
        { "path" => "new_patient.full_name", "error" => "invalid_patient" },
        { "path" => "prescriber.council", "error" => "invalid_request" },
        { "path" => "items[0].quantity", "error" => "invalid_quantity" },
        { "path" => "items[1].quantity", "error" => "invalid_quantity" }
      ])
    end

    it "a falta do número da notificação entra no fim, depois dos itens; e a recusa de campo não vira 409 de duplicado" do
      registry_no_cpf_patient!
      record(patient_id: nil, new_patient: new_patient(full_name: "Lia Santos", birth_date: "2026-08-01"),
             items: [ line(losartana, quantity: "0"), line(diazepam) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(problems).to eq([ { "path" => "items[0].quantity", "error" => "invalid_quantity" },
                               { "path" => "notification_number", "error" => "notification_required" } ])
    end
  end

  describe "atomicidade" do
    before { sign_in_as(pharmacist) }

    it "falha na gravação do evento desfaz receita, itens E o paciente criado" do
      allow(DomainEvents).to receive(:publish).and_wrap_original do |original, name, **payload|
        raise ActiveRecord::StatementInvalid, "boom" if name == "external_prescription.recorded"

        original.call(name, **payload)
      end
      before = written
      expect { record(patient_id: nil, new_patient: new_patient) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(written).to eq(before)
    end
  end

  describe "Pharmacy::Json.prescription_view" do
    it "receita sem itens não derruba: valid_until cai na data da emissão e expired segue o relógio" do
      record = ExternalPrescription.create!(patient: person, stock_location: farmacia, prescriber_name: "Dra. Beltrana Souza", council: "CRM",
                                            council_state: "PR", council_number: "54321", issued_on: today, recorded_by_user: pharmacist)
      prescription = Pharmacy::Prescription.external(record.reload, catalog: {}, settings: Pharmacy::Settings.current)
      summaries = Pharmacy::Dispensed.summaries([ prescription ])
      view = Pharmacy::Json.prescription_view(prescription, patient: person, summary: summaries.fetch(prescription.id),
                                                            settings: Pharmacy::Settings.current, today: today)
      expect(view).to include(items: [], valid_until: today.iso8601, expired: false)
      later = Pharmacy::Json.prescription_view(prescription, patient: person, summary: summaries.fetch(prescription.id),
                                                             settings: Pharmacy::Settings.current, today: today + 1)
      expect(later).to include(valid_until: today.iso8601, expired: true)
    end
  end

  describe "ExternalPrescription" do
    # Herdado da revisão da Task 10: o log INTEIRO (Parameters e o SQL com os
    # binds do INSERT da receita e do paciente), não só a linha de parâmetros.
    it "o log inteiro de uma receita externa com new_patient não leva nome, nascimento, mãe nem os dados do prescritor" do
      sign_in_as(pharmacist)
      typed = new_patient(full_name: "Carlos Eduardo Pereira", birth_date: "1985-03-12", mother_name: "Rosangela Quintanilha Pereira")
      log = capture_log do
        record(patient_id: nil, new_patient: typed, prescriber: prescriber(name: "Dra. Beltrana Souza", council: "CRO", council_state: "SC",
                                                                           council_number: "97531"))
      end
      expect(response).to have_http_status(:created)
      expect(log).to include("INSERT INTO \"external_prescriptions\"", "INSERT INTO \"patients\"")
      [ "Carlos Eduardo", "1985-03-12", "1985", "Quintanilha", "Beltrana", "97531", "CRO", "\"SC\"" ].each do |secret|
        expect(log).not_to include(secret), "o log leva #{secret.inspect}"
      end
      expect(ExternalPrescription.filter_attributes.map(&:to_s)).to include("prescriber_name", "council", "council_state", "council_number")
    end

    it "inspect, to_s, pretty_print e as_json só levam o id" do
      sign_in_as(pharmacist)
      record(items: [ line(diazepam) ], notification_number: notif)
      saved = ExternalPrescription.sole
      texts = [ saved.inspect, saved.to_s, PP.pp(saved, +""), saved.as_json.to_json, saved.items.sole.inspect, PP.pp(saved.items.sole, +"") ].join(" ")
      [ notif, "Beltrana", "54321", person.display_name, "comprimido ao dia" ].each { |secret| expect(texts).not_to include(secret) }
    end
  end
end
