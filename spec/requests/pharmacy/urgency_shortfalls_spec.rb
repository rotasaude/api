require "rails_helper"

# Módulo 32b, Task 11 (ADR 0050; contrato §7 e §12 Q7; plano, Desvio 12; Review
# Focus 5): a fila de faltas da UPA na farmácia e a conciliação. Parâmetro
# `location_id` (o nome do 27a); a falta `no_location` é lida e conciliada pelo
# almoxarife do central. Exige `pharmacy`, NÃO `urgency_stock_deduction`. A lista
# não traz nome, CPF, CNS, dose, via nem instruções; não grava trilha; a
# conciliação não mexe no estoque.
RSpec.describe "Farmácia — faltas de estoque da UPA", type: :request do
  let!(:city) { urgency_city! }
  let!(:catalog) { import_test_catalog! }
  let(:losartana) { catalog_item(268_856) }
  let!(:central) { central_location! }
  let(:upa) { upa! }
  let(:other_upa) { upa! }
  let(:orphan_upa) { upa! }
  let!(:location) { unit_location!(upa) }
  let!(:other_location) { unit_location!(other_upa) }
  let(:pharmacist) { pharmacy_staff!(location, "pharmacist") }
  let(:keeper) { pharmacy_staff!(location, "stock_keeper") }
  let(:assistant) { pharmacy_staff!(location, "pharmacy_assistant") }
  let(:other_pharmacist) { pharmacy_staff!(other_location, "pharmacist") }
  let(:central_keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:patient_name) { "Zenóbia Fulgêncio Albuquerque" }
  let(:note) { "Reposição conferida com a enfermagem da UPA" }

  before do
    ciap2_release!; cid10_release!; sigtap_release!
    pharmacy_city!
    Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  after { Current.reset }

  # A falta pela via real: a checagem da enfermagem sem saldo (insufficient_balance
  # no local da UPA) ou sem local (no_location).
  def shortfall!(unit, patient: nil)
    doctor = observation_doctor!(unit)
    encounter = in_care_encounter!(unit, patient: patient)
    urgency_consultation!(encounter, doctor: doctor)
    item = { catalog_item_id: losartana.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }
    result = Urgency::IssuePrescription.call(encounter: encounter, items: [ item.deep_stringify_keys ], by: doctor,
                                             catalog: { losartana.id => losartana })
    row = result.payload.fetch(:prescription).items.first
    sign_in_as(observation_nurse!(unit))
    json_post("/urgency/administrations", { prescription_item_id: row.id, scheduled_at: row.first_dose_at.iso8601, status: "administered" })
    raise "falta não gravada: #{response.status} #{response.body}" unless response.status == 201

    UrgencyStockShortfall.find_by!(urgency_administration_id: json_body.dig("administration", "id"))
  end

  def list(params = {}, as:)
    sign_in_as(as)
    get "/pharmacy/urgency_shortfalls", params: params
  end

  def reconcile(shortfall, body = { note: note }, as:)
    sign_in_as(as)
    json_post("/pharmacy/urgency_shortfalls/#{shortfall.id}/reconcile", body)
  end

  def ids = json_body["items"].map { |row| row["shortfall_id"] }

  describe "GET /pharmacy/urgency_shortfalls" do
    it "a farmacêutica do local lê as abertas, sem nome do paciente nem dado clínico" do
      patient = urgency_patient!(urgency_seq!)
      patient.update!(full_name: patient_name)
      shortfall = shortfall!(upa, patient: patient)
      list({ location_id: location.id }, as: pharmacist)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(patient_name, patient.cpf.to_s)
      expect(response.body).not_to match(/"(dose|dose_unit|route|instructions|cpf|cns|full_name)"/)
      expect(json_body["next_before"]).to be_nil
      row = json_body["items"].sole
      expect(row).to include("shortfall_id" => shortfall.id, "stock_location_id" => location.id, "quantity" => "1.00",
                             "cause" => "insufficient_balance", "reconciled_at" => nil, "reconciled_by" => nil)
      expect(row["catalog_item"]).to include("catalog_item_id" => losartana.id, "catmat_code" => losartana.catmat_code)
      expect(row["administration"].keys).to eq(%w[administered_at ticket])
      expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty
      expect(row["created_at"]).to be_a(String)
    end

    it "só as do local pedido; a auxiliar → 403; outra farmácia → 403" do
      shortfall!(upa)
      theirs = shortfall!(other_upa)
      list({ location_id: location.id }, as: pharmacist)
      expect(ids).not_to include(theirs.id)
      list({ location_id: location.id }, as: assistant)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      list({ location_id: location.id }, as: other_pharmacist)
      expect(response).to have_http_status(:forbidden)
      list({ location_id: location.id }, as: keeper)
      expect(response).to have_http_status(:ok)
    end

    it "o almoxarife do central, com location_id, lê as de qualquer local; sem location_id vê também as no_location de todas as UPAs" do
      mine = shortfall!(upa)
      theirs = shortfall!(other_upa)
      nowhere = shortfall!(orphan_upa)
      expect(nowhere.cause).to eq("no_location")
      list({ location_id: other_location.id }, as: central_keeper)
      expect(ids).to eq([ theirs.id ])
      list({}, as: central_keeper)
      expect(response).to have_http_status(:ok)
      expect(ids).to contain_exactly(mine.id, theirs.id, nowhere.id)
      expect(json_body["items"].find { |row| row["shortfall_id"] == nowhere.id }).to include("stock_location_id" => nil, "cause" => "no_location")
    end

    it "sem location_id só o almoxarife do central; os demais → 403" do
      shortfall!(orphan_upa)
      [ pharmacist, keeper, assistant ].each do |user|
        list({}, as: user)
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "mais novas primeiro, paginadas pelo cursor do 27a; state=reconciled lista as conciliadas" do
      first = shortfall!(upa)
      second = shortfall!(upa)
      third = shortfall!(upa)
      list({ location_id: location.id, limit: 2 }, as: pharmacist)
      expect(ids).to eq([ third.id, second.id ])
      cursor = json_body["next_before"]
      expect(cursor).to be_present
      list({ location_id: location.id, limit: 2, before: cursor }, as: pharmacist)
      expect(ids).to eq([ first.id ])
      expect(json_body["next_before"]).to be_nil

      reconcile(second, as: pharmacist)
      list({ location_id: location.id }, as: pharmacist)
      expect(ids).to eq([ third.id, first.id ])
      list({ location_id: location.id, state: "reconciled" }, as: pharmacist)
      expect(ids).to eq([ second.id ])
      expect(json_body["items"].sole).to include("reconciled_by" => { "name" => pharmacist.professional.professional_name })
      expect(json_body["items"].sole["reconciled_at"]).to be_present
      expect(response.body).not_to include(note)
    end

    it "recusas: state inválido, limite, cursor, chave desconhecida na query (422); local inexistente (422); de vacina (404)" do
      list({ location_id: location.id, state: "x" }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "state" ])
      list({ location_id: location.id, limit: 0 }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "limit" ])
      list({ location_id: location.id, before: "zzz" }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "before" ])
      list({ location_id: location.id, cpf: "123" }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cpf" ])
      list({ location_id: SecureRandom.uuid }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "location_id" ])
      cold = StockLocation.create!(kind: "cold_chain_central", name: "Rede de frio", updated_by_user: pharmacy_admin!)
      list({ location_id: cold.id }, as: pharmacist)
      expect(response).to have_http_status(:not_found)
    end

    it "com pharmacy desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      list({ location_id: location.id }, as: pharmacist)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end

    it "Review Focus 5: com urgency_stock_deduction desligado depois, a lista segue" do
      shortfall = shortfall!(upa)
      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      list({ location_id: location.id }, as: pharmacist)
      expect([ response.status, ids ]).to eq([ 200, [ shortfall.id ] ])
    end
  end

  describe "POST /pharmacy/urgency_shortfalls/:id/reconcile" do
    it "nota curta → 422 note; com nota → 200, sem movimento, evento só com o id; de novo → 409 already_reconciled" do
      shortfall = shortfall!(upa)
      reconcile(shortfall, { note: "curta" }, as: pharmacist)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "note" ])
      reconcile(shortfall, { note: nil }, as: pharmacist)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "note" ])
      expect(shortfall.reload.reconciled_at).to be_nil

      expect { reconcile(shortfall, as: pharmacist) }.not_to change(StockMovement, :count)
      expect(response).to have_http_status(:ok)
      expect(json_body["shortfall"]).to include("shortfall_id" => shortfall.id, "reconciled_by" => { "name" => pharmacist.professional.professional_name })
      expect(json_body["shortfall"]["reconciled_at"]).to be_present
      expect(response.body).not_to include(note)
      expect(shortfall.reload).to have_attributes(reconciled_by_user_id: pharmacist.id, reconciliation_note: note)
      event = DomainEvent.where(name: "pharmacy.urgency_shortfall_reconciled").sole
      expect(event.payload).to eq("shortfall_id" => shortfall.id)

      reconcile(shortfall, as: pharmacist)
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_reconciled" ])
      expect(DomainEvent.where(name: "pharmacy.urgency_shortfall_reconciled").count).to eq(1)
    end

    it "a auxiliar e a farmácia de outro local → 403; id desconhecido → 404" do
      shortfall = shortfall!(upa)
      reconcile(shortfall, as: assistant)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      reconcile(shortfall, as: other_pharmacist)
      expect(response).to have_http_status(:forbidden)
      expect(shortfall.reload.reconciled_at).to be_nil
      sign_in_as(pharmacist)
      json_post("/pharmacy/urgency_shortfalls/#{SecureRandom.uuid}/reconcile", { note: note })
      expect(response).to have_http_status(:not_found)
    end

    it "a no_location só o almoxarife do central concilia; a farmacêutica da UPA → 403" do
      shortfall = shortfall!(orphan_upa)
      reconcile(shortfall, as: pharmacist)
      expect(response).to have_http_status(:forbidden)
      reconcile(shortfall, as: central_keeper)
      expect(response).to have_http_status(:ok)
      expect(shortfall.reload.reconciled_by_user_id).to eq(central_keeper.id)
    end

    it "o almoxarife do central concilia a de um local (a mesma regra de leitura)" do
      shortfall = shortfall!(upa)
      reconcile(shortfall, as: central_keeper)
      expect(response).to have_http_status(:ok)
    end

    it "Review Focus 5: com urgency_stock_deduction desligado depois, a conciliação segue; pharmacy desligado → 403" do
      shortfall = shortfall!(upa)
      other = shortfall!(upa)
      Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      reconcile(shortfall, as: pharmacist)
      expect(response).to have_http_status(:ok)
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      reconcile(other, as: pharmacist)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end
  end

  describe "GET /pharmacy/alerts" do
    it "traz urgency_shortfalls, só as abertas do local" do
      shortfall!(upa)
      done = shortfall!(upa)
      shortfall!(other_upa)
      reconcile(done, as: pharmacist)
      sign_in_as(pharmacist)
      get "/pharmacy/alerts", params: { location_id: location.id }
      expect(json_body).to include("urgency_shortfalls" => 1)
      expect(json_body.keys).to eq(%w[expiring expired below_minimum in_transit pending_adjustments urgency_shortfalls])
    end
  end
end
