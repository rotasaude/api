require "rails_helper"

# Módulo 27a, Task 11 (ADR 0045; contrato §7, H2, H6, H8, H9, H12; Review Focus
# 4 e 5): POST /pharmacy/dispensations (201 com o <dispensation>, sem envelope) e
# o histórico GET /pharmacy/dispensations?patient_id= (nominal, com trilha). Todo
# 422 traz `problems`; 403 de papel sozinho; receita inexistente → 404. Nome do
# medicamento, número da notificação e o paciente só no corpo da resposta.
RSpec.describe "Farmácia — dispensação e histórico do paciente", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:today) { Time.use_zone(city.time_zone) { Time.zone.today } }
  let(:consultation) { pharmacy_consultation! }
  let(:patient) { consultation.patient }
  let(:document) { pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana, continuous: true } ]) }
  let(:item) { document.prescription_items.first }
  let!(:lot) { stocked_lot!(farmacia, item: losartana, quantity: "100", lot_number: "LOS-2026-01") }

  def post_json(path, body, query: "") = post("#{path}#{query}", params: body.to_json, headers: json_headers)
  def line(quantity = "30", **over) = { prescription_item_id: item.id, lot_id: lot.id, quantity: quantity }.merge(over)
  def dispense(items = [ line ], location: farmacia, prescription: { kind: "digital", id: document.id }, query: "", **fields)
    post_json("/pharmacy/dispensations", { location_id: location.id, prescription: prescription, items: items }.merge(fields), query: query)
  end
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload).select { |payload| payload["access"] == "pharmacy" }
  def written = [ Dispensation.count, DispensationItem.count, StockMovement.where(kind: "dispensing").count ]
  def history(query) = get("/pharmacy/dispensations?#{query}")

  describe "POST /pharmacy/dispensations" do
    it "farmacêutica: 201 com o <dispensation> inteiro, sem envelope; saldo cai; evento só com ids" do
      sign_in_as(pharmacist)
      dispense
      expect(response).to have_http_status(:created)
      saved = Dispensation.sole
      row = saved.items.sole
      expect(json_body).to eq(
        "id" => saved.id,
        "location" => { "id" => farmacia.id, "name" => farmacia.name, "kind" => "unit", "health_unit" => { "id" => unit.id, "name" => unit.name },
                        "active" => true },
        "prescription" => { "kind" => "digital", "id" => document.id },
        "patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => nil },
        "by" => { "name" => pharmacist.professional.professional_name, "role" => "pharmacist" },
        "at" => saved.dispensed_at.iso8601,
        "items" => [ { "id" => row.id, "prescription_item_id" => item.id, "catalog_item_id" => losartana.id,
                       "item" => { "catalog_item_id" => losartana.id, "catmat_code" => losartana.catmat_code, "name" => losartana.label,
                                   "unit" => losartana.unit, "dispensing_unit" => "comprimido", "controlled" => false, "controlled_list" => nil },
                       "lot_id" => lot.id, "lot" => { "id" => lot.id, "lot_number" => "LOS-2026-01", "expires_on" => lot.expires_on.iso8601 },
                       "quantity" => "30.00", "returned_total" => "0.00", "mapped_from_free_text" => false } ],
        "retention" => nil
      )
      expect(balance_of(farmacia, lot)).to eq(70)
      expect(DomainEvent.where(name: "dispensation.recorded").sole.payload).to eq("dispensation_id" => saved.id, "user_id" => pharmacist.id)
      expect(trail).to eq([])
    end

    it "auxiliar grava pharmacy_assistant; quem tem os dois papéis grava pharmacist" do
      sign_in_as(assistant)
      dispense([ line("10") ])
      expect(response).to have_http_status(:created)
      expect(json_body["by"]).to eq("name" => nil, "role" => "pharmacy_assistant")
      Membership.create!(user: assistant, role: "pharmacist", granted_at: Time.current)
      StockLocationStaff.create!(stock_location: farmacia, user: assistant, role: "pharmacist", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      # A segunda vai noutra receita (o item contínuo da primeira ainda está no intervalo).
      other = pharmacy_prescription!(consultation: pharmacy_consultation!)
      dispense([ { prescription_item_id: other.prescription_items.first.id, lot_id: lot.id, quantity: "10" } ], prescription: { kind: "digital", id: other.id })
      expect(response).to have_http_status(:created)
      expect(json_body["by"]["role"]).to eq("pharmacist")
    end

    it "Review Focus 4: farmacêutica com a Membership revogada e o vínculo ativo → 403 missing_role, sozinho; nada gravado" do
      pharmacist.memberships.find_by(role: "pharmacist").revoke!
      sign_in_as(pharmacist)
      dispense([ line("1,5") ])
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "almoxarife, local central, local de outra unidade e local inexistente" do
      sign_in_as(keeper)
      dispense
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(pharmacist)
      dispense(location: central)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      dispense(location: unit_location!)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      post_json("/pharmacy/dispensations", { location_id: SecureRandom.uuid, prescription: { kind: "digital", id: document.id }, items: [ line ] })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "location_id") ])
    end

    it "Review Focus 5: quantidade como no papel → 422 invalid_quantity no items[0].quantity, nunca arredondada" do
      sign_in_as(pharmacist)
      [ "1,5", 1.5, 2, "0.001", "-2", "100000", "0", "" ].each do |quantity|
        dispense([ line(quantity) ])
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_quantity", "items[0].quantity") ]), "quantidade #{quantity.inspect}"
      end
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "dois itens inválidos vêm juntos em problems" do
      sign_in_as(pharmacist)
      dispense([ line("1.5", lot_id: SecureRandom.uuid), line("2,5") ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_item", "path" => "items[0].lot_id",
                              "problems" => [ { "path" => "items[0].lot_id", "error" => "invalid_item" },
                                              { "path" => "items[1].quantity", "error" => "invalid_quantity" } ])
    end

    it "too_early traz next_allowed_on no topo e no problema" do
      sign_in_as(pharmacist)
      dispense
      dispense([ line("1") ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "too_early", "path" => "items[0]", "next_allowed_on" => (today + 25).iso8601,
                                                           "problems" => [ { "path" => "items[0]", "error" => "too_early",
                                                                             "next_allowed_on" => (today + 25).iso8601 } ] } ])
    end

    it "controlado pela auxiliar → 403 controlled_requires_pharmacist sozinho, sem nome do medicamento" do
      controlled = pharmacy_prescription!(consultation: consultation, items: [ { catalog: fluoxetina } ], content: { "category" => "special_control" })
      fluoxetina_lot = stocked_lot!(farmacia, item: fluoxetina)
      sign_in_as(assistant)
      dispense([ { prescription_item_id: controlled.prescription_items.first.id, lot_id: fluoxetina_lot.id, quantity: "1,5" } ],
               prescription: { kind: "digital", id: controlled.id })
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])
      expect(response.body).not_to include("FLUOXETINA", "fluoxetina")
    end

    it "receita inexistente → 404 prescription_not_found; prescription malformada → 422 com o path" do
      sign_in_as(pharmacist)
      dispense(prescription: { kind: "digital", id: SecureRandom.uuid })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "prescription_not_found" } ])
      dispense(prescription: { kind: "external", id: document.id })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "prescription_not_found" } ])
      dispense(prescription: { kind: "digital", id: "abc" })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "prescription_not_found" } ])
      dispense(prescription: { kind: "paper", id: document.id })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "prescription.kind") ])
      dispense(prescription: document.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "prescription") ])
      # Atestado e registro de notificação não são receita.
      dispense(prescription: { kind: "digital", id: pharmacy_prescription!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper").id })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "prescription_not_found" } ])
    end

    it "receita cancelada → 422 prescription_cancelled; chave na query → 422 com o path" do
      cancelled = pharmacy_prescription!(consultation: consultation, cancelled: true)
      sign_in_as(pharmacist)
      dispense([ { prescription_item_id: cancelled.prescription_items.first.id, lot_id: lot.id, quantity: "1" } ],
               prescription: { kind: "digital", id: cancelled.id })
      expect([ response.status, json_body ]).to eq([ 422, refusal("prescription_cancelled", "prescription") ])
      dispense(query: "?patient_id=#{patient.id}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "a requisição, o log, o evento e o erro não levam medicamento, número da notificação nem o paciente" do
      controlled = pharmacy_prescription!(consultation: consultation, items: [ { catalog: fluoxetina } ], content: {
                                            "category" => "special_control", "sncr" => { "kind" => "rce", "number" => "2610.1-41.0000077", "simulated" => true }
                                          })
      fluoxetina_lot = stocked_lot!(farmacia, item: fluoxetina, lot_number: "FLX-77")
      sign_in_as(pharmacist)
      body = { prescription: { kind: "digital", id: controlled.id }, retention: { notification_number: "2610.1-41.0000077" } }
      log = capture_log do
        dispense([ { prescription_item_id: controlled.prescription_items.first.id, lot_id: fluoxetina_lot.id, quantity: "3" } ], **body)
        expect(response).to have_http_status(:created)
        dispense([ { prescription_item_id: controlled.prescription_items.first.id, lot_id: fluoxetina_lot.id, quantity: "999" } ], **body)
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(json_body).to eq(refusal("insufficient_balance", "items[0].quantity"))
      expect(Dispensation.sole).to have_attributes(retained: true, notification_number: "2610.1-41.0000077")
      secrets = [ "2610.1-41.0000077", "FLUOXETINA", patient.display_name, patient.cpf, "FLX-77" ]
      secrets.each { |secret| expect(log).not_to include(secret) }
      payloads = DomainEvent.where(name: "dispensation.recorded").pluck(:payload).to_json
      secrets.each { |secret| expect(payloads).not_to include(secret) }
    end

    it "interruptor desligado → 403 feature_disabled; sem sessão → 401" do
      dispense
      expect(response).to have_http_status(:unauthorized)
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(pharmacist)
      dispense
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end

  describe "GET /pharmacy/dispensations?patient_id=" do
    before do
      sign_in_as(pharmacist)
      dispense
      expect(response).to have_http_status(:created)
    end

    it "lista as retiradas do paciente (todos os locais), mais novas primeiro, com trilha por pessoa" do
      other_unit = create_unit("UBS Vila Nova")
      other = unit_location!(other_unit)
      colleague = pharmacy_staff!(other, "pharmacy_assistant")
      second = pharmacy_prescription!(consultation: consultation, items: [ { catalog: amoxicilina } ])
      amoxicilina.update!(antimicrobial: false)
      other_lot = stocked_lot!(other, item: amoxicilina)
      sign_in_as(colleague)
      dispense([ { prescription_item_id: second.prescription_items.first.id, lot_id: other_lot.id, quantity: "7" } ], location: other,
               prescription: { kind: "digital", id: second.id })
      expect(response).to have_http_status(:created)

      history("patient_id=#{patient.id}")
      expect(response).to have_http_status(:ok)
      expect(json_body["next_before"]).to be_nil
      rows = json_body["dispensations"]
      expect(rows.map { |row| [ row["location"]["id"], row["items"].sole["quantity"] ] }).to eq([ [ other.id, "7.00" ], [ farmacia.id, "30.00" ] ])
      expect(rows.last["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => nil)
      expect(trail).to eq([ { "patient_id" => patient.id, "user_id" => colleague.id, "access" => "pharmacy", "reason_code" => nil,
                              "person_ref" => "patient:#{patient.id}" } ])
    end

    it "pagina com limit e next_before; paciente sem retirada → lista vazia e sem trilha" do
      second = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana } ])
      dispense([ { prescription_item_id: second.prescription_items.first.id, lot_id: lot.id, quantity: "1" } ], prescription: { kind: "digital", id: second.id })
      history("patient_id=#{patient.id}&limit=1")
      first_page = json_body
      expect(first_page["dispensations"].size).to eq(1)
      expect(first_page["next_before"]).to be_present
      history("patient_id=#{patient.id}&limit=1&before=#{first_page['next_before']}")
      expect(json_body["dispensations"].sole["id"]).not_to eq(first_page["dispensations"].sole["id"])
      expect(json_body["next_before"]).to be_nil
      expect(trail.size).to eq(2)

      history("patient_id=#{registry_patient!.id}")
      expect([ response.status, json_body ]).to eq([ 200, { "dispensations" => [], "next_before" => nil } ])
      expect(trail.size).to eq(2)
    end

    it "recusas: sem patient_id, inexistente, cursor e limit inválidos, chave estranha; almoxarife → 403" do
      history("")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      history("patient_id=#{SecureRandom.uuid}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      history("patient_id=#{patient.id}&before=abc")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cursor", "before") ])
      history("patient_id=#{patient.id}&limit=101")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_limit", "limit") ])
      history("patient_id=#{patient.id}&cpf=123")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      sign_in_as(keeper)
      history("patient_id=#{patient.id}")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(trail).to eq([])
    end
  end
end
