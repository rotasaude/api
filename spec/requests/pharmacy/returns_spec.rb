require "rails_helper"

# Módulo 27a, Task 11 (ADR 0045; Desvio 12; contrato H9/H12; ruling do
# controlador): POST /pharmacy/returns `{ location_id, dispensation_item_id,
# quantity, reason }` → 201 com o <dispensation> inteiro atualizado (itens com
# `returned_total`). Sem step-up. Farmacêutico ou auxiliar do local da
# dispensação; item de outro local → 404. Volta ao mesmo lote como `return`,
# com o motivo só no corpo (extrato); evento dispensation.returned só com ids.
RSpec.describe "Farmácia — devolução", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:consultation) { pharmacy_consultation! }
  let(:patient) { consultation.patient }
  let(:document) { pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana, continuous: true } ]) }
  let!(:lot) { stocked_lot!(farmacia, item: losartana, quantity: "100", lot_number: "LOS-DEV-1") }
  let(:reason) { "Paciente trocou de medicamento e devolveu a caixa lacrada" }
  let!(:dispensed) do
    prescription = Pharmacy::Prescription.find(kind: "digital", id: document.id, settings: Pharmacy::Settings.current)
    result = Pharmacy::Dispense.call(location: farmacia, prescription: prescription, retention: nil, by: pharmacist, role: "pharmacist",
                                     items: [ { "prescription_item_id" => document.prescription_items.first.id, "lot_id" => lot.id, "quantity" => "30" } ],
                                     catalog: Pharmacy::Json.catalog_for([ losartana.id ]), settings: Pharmacy::Settings.current)
    raise result.inspect if result.failure?

    result.payload.fetch(:dispensation).items.sole
  end

  def post_json(path, body, query: "") = post("#{path}#{query}", params: body.to_json, headers: json_headers)
  def give_back(quantity = "5", location: farmacia, item_id: dispensed.id, why: reason, query: "")
    post_json("/pharmacy/returns", { location_id: location.id, dispensation_item_id: item_id, quantity: quantity, reason: why }, query: query)
  end
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }

  it "devolver 5 de 30: 201 com o <dispensation> atualizado, saldo +5 e o extrato com o return e o motivo" do
    sign_in_as(assistant)
    give_back("5")
    expect(response).to have_http_status(:created)
    expect(json_body["id"]).to eq(dispensed.dispensation_id)
    expect(json_body["items"].sole).to include("id" => dispensed.id, "quantity" => "30.00", "returned_total" => "5.00", "lot_id" => lot.id)
    expect(json_body["by"]).to eq("name" => pharmacist.professional.professional_name, "role" => "pharmacist")
    expect(json_body.keys).to eq(%w[id location prescription patient by at items retention])
    expect(balance_of(farmacia, lot)).to eq(75)
    movement = StockMovement.find_by!(kind: "return")
    expect(movement).to have_attributes(quantity: BigDecimal("5"), stock_lot_id: lot.id, stock_location_id: farmacia.id, dispensation_item_id: dispensed.id,
                                        recorded_by_user_id: assistant.id, reason: reason)
    expect(DomainEvent.where(name: "dispensation.returned").sole.payload).to eq("dispensation_id" => dispensed.dispensation_id, "user_id" => assistant.id)

    get "/pharmacy/lots/#{lot.id}/movements?location_id=#{farmacia.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["balance"]).to eq("75.00")
    expect(json_body["movements"].first).to include("kind" => "return", "quantity" => "5.00", "reason" => reason,
                                                    "document" => { "type" => "dispensation", "id" => dispensed.dispensation_id, "number" => nil })
  end

  it "o total dispensado da receita fica líquido; devolver tudo libera nova retirada do contínuo" do
    sign_in_as(pharmacist)
    give_back("30")
    expect(response).to have_http_status(:created)
    post_json("/pharmacy/prescriptions/lookup", { location_id: farmacia.id, short_code: document.short_code })
    expect(json_body["prescriptions"].sole["items"].sole).to include("dispensed_total" => "0.00", "last_dispensed_on" => nil, "next_allowed_on" => nil)
  end

  it "devolver mais que o restante → return_exceeds; até o restante passa; nada além" do
    sign_in_as(pharmacist)
    give_back("20")
    give_back("10.01")
    expect([ response.status, json_body ]).to eq([ 422, refusal("return_exceeds", "quantity") ])
    give_back("10")
    expect(response).to have_http_status(:created)
    expect(json_body["items"].sole["returned_total"]).to eq("30.00")
    give_back("0.01")
    expect([ response.status, json_body ]).to eq([ 422, refusal("return_exceeds", "quantity") ])
    expect(balance_of(farmacia, lot)).to eq(100)
  end

  it "motivo curto → invalid_reason; com quantidade inválida, as duas juntas; motivo longo demais também" do
    sign_in_as(pharmacist)
    give_back("5", why: "curto")
    expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_reason", "reason") ])
    give_back("1,5", why: nil)
    expect(json_body).to eq("error" => "invalid_quantity", "path" => "quantity",
                            "problems" => [ { "path" => "quantity", "error" => "invalid_quantity" }, { "path" => "reason", "error" => "invalid_reason" } ])
    give_back("5", why: "a" * 501)
    expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_reason", "reason") ])
    expect(StockMovement.where(kind: "return").count).to eq(0)
  end

  it "lote vencido → lot_expired" do
    sign_in_as(pharmacist)
    travel_to(lot.expires_on.in_time_zone + 1.day) do
      sign_in_as(pharmacist)
      give_back("5")
      expect([ response.status, json_body ]).to eq([ 422, refusal("lot_expired", "dispensation_item_id") ])
    end
  end

  it "auxiliar de outra UBS → 404 (pelo próprio local) e 403 (pelo local alheio); item inexistente → 404; id malformado → 422" do
    other = unit_location!
    stranger = pharmacy_staff!(other, "pharmacy_assistant")
    sign_in_as(stranger)
    give_back("5", location: other)
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    give_back("5", location: farmacia)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(assistant)
    give_back("5", item_id: SecureRandom.uuid)
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    give_back("5", item_id: "123")
    expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "dispensation_item_id") ])
    expect(StockMovement.where(kind: "return").count).to eq(0)
  end

  it "almoxarife do local → 403; chave na query → 422; o motivo não vai ao log nem ao evento" do
    keeper = pharmacy_staff!(farmacia, "stock_keeper")
    sign_in_as(keeper)
    give_back("5")
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(assistant)
    give_back("5", query: "?reason=x")
    expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "reason") ])
    log = capture_log { give_back("5") }
    expect(response).to have_http_status(:created)
    expect(log).not_to include("trocou de medicamento")
    expect(DomainEvent.where(name: "dispensation.returned").pluck(:payload).to_json).not_to include("trocou")
  end

  # Ruling da revisão final: devolver item CONTROLADO é do farmacêutico, com o
  # mesmo critério da dispensação (retenção com número, ou o catálogo/retrato
  # que a dispensação usou). 403 de papel sozinho, antes das recusas do corpo.
  describe "item controlado: só o farmacêutico devolve" do
    def dispense_controlled!(content:, retention:)
      document = pharmacy_prescription!(consultation: consultation, items: [ { catalog: fluoxetina } ], content: content)
      flx = stocked_lot!(farmacia, item: fluoxetina, quantity: "50", lot_number: "FLX-RET-#{SecureRandom.hex(2).upcase}")
      prescription = Pharmacy::Prescription.find(kind: "digital", id: document.id, settings: Pharmacy::Settings.current)
      result = Pharmacy::Dispense.call(location: farmacia, prescription: prescription, retention: retention, by: pharmacist, role: "pharmacist",
                                       items: [ { "prescription_item_id" => document.prescription_items.first.id, "lot_id" => flx.id, "quantity" => "10" } ],
                                       catalog: Pharmacy::Json.catalog_for([ fluoxetina.id ]), settings: Pharmacy::Settings.current)
      raise result.inspect if result.failure?

      result.payload.fetch(:dispensation).items.sole
    end

    it "retenção com número (controle especial): auxiliar → 403 controlled_requires_pharmacist sozinho; farmacêutico → 201" do
      item = dispense_controlled!(content: { "category" => "special_control", "sncr" => { "kind" => "rce", "number" => "2610.1-41.0000077", "simulated" => true } },
                                  retention: { "notification_number" => "2610.1-41.0000077" })
      expect(item.dispensation.notification_number).to eq("2610.1-41.0000077")
      sign_in_as(assistant)
      give_back("1,5", item_id: item.id, why: "curto")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])
      give_back("2", item_id: item.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])
      expect(StockMovement.where(kind: "return").count).to eq(0)

      sign_in_as(pharmacist)
      give_back("2", item_id: item.id)
      expect(response).to have_http_status(:created)
      expect(json_body["items"].sole["returned_total"]).to eq("2.00")
    end

    it "sem número na retenção, pelo catálogo que a dispensação usou: auxiliar → 403; farmacêutico → 201" do
      item = dispense_controlled!(content: {}, retention: {})
      expect(item.dispensation).to have_attributes(retained: true, notification_number: nil)
      sign_in_as(assistant)
      give_back("2", item_id: item.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "controlled_requires_pharmacist" } ])

      sign_in_as(pharmacist)
      give_back("2", item_id: item.id)
      expect(response).to have_http_status(:created)
    end
  end

  # Ruling da revisão final: o motivo da devolução no extrato só para quem
  # dispensa no local (farmacêutico ou auxiliar); os demais leem `reason: null`.
  it "extrato: o almoxarife do local vê o return com reason null; o farmacêutico do local vê o motivo" do
    sign_in_as(assistant)
    give_back("5")
    expect(response).to have_http_status(:created)

    sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
    get "/pharmacy/lots/#{lot.id}/movements?location_id=#{farmacia.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["movements"].first).to include("kind" => "return", "quantity" => "5.00", "reason" => nil)

    sign_in_as(pharmacist)
    get "/pharmacy/lots/#{lot.id}/movements?location_id=#{farmacia.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["movements"].first).to include("kind" => "return", "reason" => reason)
  end

  # Ruling da revisão final: a resposta traz o <dispensation> com o nome do
  # paciente, então cada devolução gravada deixa a trilha da pessoa.
  it "uma trilha clinical_record.viewed do paciente por devolução; recusa não grava trilha" do
    sign_in_as(assistant)
    give_back("5")
    give_back("5")
    give_back("99")
    expect(response).to have_http_status(:unprocessable_entity)
    trails = DomainEvent.where(name: "clinical_record.viewed").pluck(:payload)
    expect(trails.size).to eq(2)
    expect(trails).to all(include("patient_id" => patient.id, "user_id" => assistant.id, "access" => "pharmacy",
                                  "person_ref" => "patient:#{patient.id}"))
  end
end
