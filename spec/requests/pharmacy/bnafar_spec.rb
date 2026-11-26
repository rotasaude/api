require "rails_helper"

# Módulo 27b, Task 12 (contrato §3, §6; Q16, Q20, Q22, Q25; R13, R16, R18): a
# superfície do envio para o dashboard. Situação, remessas, registros, reenvio e
# correção exigem o `bnafar`; as pendências e os domínios só o estoque do
# domínio. Nunca o payload; nada de pessoa.
RSpec.describe "Farmácia — envio à BNAFAR", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let!(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
  let(:unit) { unit_location!(create_unit("UBS Jardim das Flores")) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:admin) { pharmacy_admin! }
  let(:pharmacist) { pharmacy_staff!(unit, "pharmacist") }
  let(:assistant) { pharmacy_staff!(unit, "pharmacy_assistant") }
  let(:room_lead) { room_member!(vaccine_room!, role: "room_lead", cbo: "223505") }
  let(:today) { Time.zone.today }
  let(:off) { bnafar_on!(city, since: 10.days.ago, domains: []) }
  let(:on) { bnafar_on!(city, since: 10.days.ago) }

  # Delivery#pause!: a credencial recusada tira o `bnafar` de utilizável, mas o
  # interruptor segue LIGADO (Q40, Q41).
  def refuse_credential! = IntegrationCredential.where(kind: "bnafar").update_all(last_check_status: "unauthorized")

  def post_json(path, body = {}) = post(path, params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  describe "GET /pharmacy/bnafar/status" do
    before { on }

    it "admin, almoxarife, farmacêutico e responsável de sala leem; auxiliar → 403 (Q32)" do
      submission = bnafar_submission!(reference_on: today - 1, status: "finished")
      batch = bnafar_batch!(submission)
      bnafar_record!(submission, status: "accepted", batch: batch)
      bnafar_record!(submission, status: "rejected", batch: batch, error_codes: [ "MSG12" ])
      bnafar_record!(submission, batch: batch)

      [ admin, keeper, pharmacist, room_lead ].each do |user|
        sign_in_as(user)
        get "/pharmacy/bnafar/status"
        expect(response).to have_http_status(:ok)
        expect(json_body).to include("environment" => "production")
        expect(json_body["alert"].keys).to match_array(%w[late lost rejected last_finished_on])
        day = json_body["days"].sole
        expect(day["reference_on"]).to eq((today - 1).iso8601)
        expect(day["subjects"].sole).to eq("subject" => "position", "status" => "finished", "accepted" => 1, "rejected" => 1, "pending" => 1, "lost" => 0)
      end

      sign_in_as(assistant)
      get "/pharmacy/bnafar/status"
      expect(response).to have_http_status(:forbidden)
    end

    it "só os últimos 30 dias e só o ambiente em uso" do
      bnafar_submission!(reference_on: today - 31, status: "finished")
      bnafar_submission!(reference_on: today - 30, status: "finished")
      bnafar_submission!(reference_on: today - 2, status: "finished", environment: "homologation")
      sign_in_as(admin)

      get "/pharmacy/bnafar/status"
      expect(json_body["days"].map { |day| day["reference_on"] }).to eq([ (today - 30).iso8601 ])
    end

    it "remessa perdida soma os não aceitos em lost" do
      submission = bnafar_submission!(reference_on: today - 5, status: "lost")
      bnafar_record!(submission, status: "rejected", error_codes: [ "MSG12" ])
      bnafar_record!(submission)
      bnafar_record!(submission, status: "accepted")
      sign_in_as(keeper)

      get "/pharmacy/bnafar/status"
      expect(json_body["days"].sole["subjects"].sole).to include("accepted" => 1, "rejected" => 0, "pending" => 0, "lost" => 2)
      expect(json_body["alert"]).to include("lost" => 2)
    end

    it "?cpf= → 422 path cpf" do
      sign_in_as(admin)
      get "/pharmacy/bnafar/status", params: { cpf: "12345678909" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
    end
  end

  describe "com a credencial recusada (Q40)" do
    before do
      on
      refuse_credential!
    end

    it "status → 200 com late 1 às 15:00 (R25); lista e detalhe das remessas → 200" do
      expect(Bnafar::Gate.usable?(city)).to be(false)
      zone = ActiveSupport::TimeZone[city.time_zone]
      later = (zone.now + 1.day).change(hour: 15, min: 0)
      submission = bnafar_submission!(reference_on: today - 3, status: "finished")

      travel_to(later) do
        sign_in_as(keeper)
        get "/pharmacy/bnafar/status"
        expect(response).to have_http_status(:ok)
        expect(json_body["alert"]).to include("late" => 1)
        get "/pharmacy/bnafar/submissions"
        expect(response).to have_http_status(:ok)
        expect(json_body["items"].map { |row| row["id"] }).to eq([ submission.id ])
        get "/pharmacy/bnafar/submissions/#{submission.id}"
        expect(response).to have_http_status(:ok)
      end
    end

    it "retry e correct → 403 feature_disabled (exigem o bnafar utilizável)" do
      submission = bnafar_submission!(reference_on: today - 1, status: "finished")
      bnafar_record!(submission, status: "rejected", error_codes: [ "MSG12" ])
      stepped_up!(admin)
      post_json "/pharmacy/bnafar/submissions/#{submission.id}/retry"
      expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "bnafar" ])
      post_json "/pharmacy/bnafar/records/#{SecureRandom.uuid}/correct", { expected_version: 1, reason: "Destino corrigido após a conferência" }
      expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "bnafar" ])
    end
  end

  describe "GET /pharmacy/bnafar/submissions" do
    before { on }

    it "registro perdido traz lost: true e lost_reason; todos com location_name e item_label; nunca o payload" do
      submission = bnafar_submission!(reference_on: today - 5, status: "lost")
      batch = bnafar_batch!(submission, status: "failed", protocol: 4242)
      bnafar_record!(submission, status: "rejected", batch: batch, error_codes: %w[MSG09 MSG47])
      bnafar_record!(submission, status: "rejected", batch: batch, error_codes: %w[MSG47])
      bnafar_record!(submission)
      bnafar_record!(submission, status: "accepted", batch: batch)
      sign_in_as(keeper)

      get "/pharmacy/bnafar/submissions/#{submission.id}"
      expect(response).to have_http_status(:ok)
      rows = json_body["records"]
      expect(rows.size).to eq(4)
      expect(rows).to all(include("location_name" => central.name, "item_label" => losartana.label))
      lost = rows.select { |row| row["lost"] }
      expect(lost.size).to eq(3)
      expect(lost.map { |row| row["lost_reason"] }).to contain_exactly("MSG09", "MSG47", "not_sent")
      expect(rows.find { |row| row["status"] == "accepted" }).to include("lost" => false, "lost_reason" => nil)
      expect(rows).to all(satisfy { |row| !row.key?("payload") })
      expect(response.body).not_to include("payload")
    end

    it "detalhe com o protocol de cada lote e sem payload" do
      submission = bnafar_submission!(reference_on: today - 1, status: "finished")
      post_batch = bnafar_batch!(submission, protocol: 111)
      bnafar_batch!(submission, operation: "delete", protocol: 222)
      record = bnafar_record!(submission, status: "accepted", batch: post_batch, sent_at: 2.days.ago)
      sign_in_as(admin)

      get "/pharmacy/bnafar/submissions/#{submission.id}"
      expect(json_body["batches"]).to contain_exactly({ "operation" => "post", "status" => "finished", "protocol" => 111 },
                                                      { "operation" => "delete", "status" => "finished", "protocol" => 222 })
      expect(json_body["records"].sole).to include("id" => record.id, "protocol" => 111, "bnafar_code" => record.bnafar_code, "deleted" => false,
                                                   "stock_location_id" => central.id, "item_key" => record.item_key, "error_codes" => [])
      expect(json_body["records"].sole.keys).to match_array(%w[id subject status lost lost_reason deleted stock_location_id location_name item_key item_label
                                                               error_codes rejected_items bnafar_code protocol retry_until correct_until stock_external_exit_id stock_external_exit_version])
      expect(json_body).to include("id" => submission.id, "reference_on" => (today - 1).iso8601, "subject" => "position", "status" => "finished")
      expect(response.body).not_to include("payload")
    end

    it "retry_until no recusado de ontem; correct_until só na saída externa aceita" do
      submission = bnafar_submission!(reference_on: today - 1, status: "finished")
      bnafar_record!(submission, status: "rejected", error_codes: [ "MSG06" ])
      sign_in_as(admin)

      get "/pharmacy/bnafar/submissions/#{submission.id}"
      expect(Time.iso8601(json_body["records"].sole["retry_until"])).to be_within(1.second).of(Bnafar::Window.retry_until(submission))
      expect(json_body["records"].sole["correct_until"]).to be_nil
    end

    it "lista filtrada, em páginas {items,next_before} (50, máximo 100)" do
      rows = [ 1, 2, 3 ].map { |days| bnafar_submission!(reference_on: today - days, subject: "exit", status: "finished") }
      bnafar_submission!(reference_on: today - 2, subject: "position", status: "failed")
      sign_in_as(admin)

      get "/pharmacy/bnafar/submissions", params: { subject: "exit", status: "finished", limit: 2 }
      expect(json_body["items"].map { |row| row["id"] }).to eq([ rows[0].id, rows[1].id ])
      expect(json_body["next_before"]).to be_present
      get "/pharmacy/bnafar/submissions", params: { subject: "exit", status: "finished", limit: 2, before: json_body["next_before"] }
      expect(json_body["items"].map { |row| row["id"] }).to eq([ rows[2].id ])
      expect(json_body["next_before"]).to be_nil

      get "/pharmacy/bnafar/submissions", params: { from: (today - 2).iso8601, to: (today - 1).iso8601 }
      expect(json_body["items"].size).to eq(3)
      get "/pharmacy/bnafar/submissions", params: { limit: 101 }
      expect(response).to have_http_status(:unprocessable_entity)
      get "/pharmacy/bnafar/submissions", params: { status: "nope" }
      expect(json_body).to include("path" => "status")
      get "/pharmacy/bnafar/submissions", params: { cpf: "1" }
      expect(json_body).to include("path" => "cpf")
    end

    it "remessa desconhecida → 404; auxiliar → 403" do
      sign_in_as(admin)
      get "/pharmacy/bnafar/submissions/#{SecureRandom.uuid}"
      expect(response).to have_http_status(:not_found)
      sign_in_as(pharmacist)
      get "/pharmacy/bnafar/submissions"
      expect(response).to have_http_status(:ok)
      sign_in_as(room_lead)
      get "/pharmacy/bnafar/submissions"
      expect(response).to have_http_status(:ok)
      sign_in_as(assistant)
      get "/pharmacy/bnafar/submissions"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /pharmacy/bnafar/submissions/:id/retry" do
    before { on }

    let(:submission) { bnafar_submission!(reference_on: today - 1, status: "finished") }

    it "reenvio sem step-up → 401 mfa_required" do
      sign_in_as(step_up_enrolled!(admin))
      post_json "/pharmacy/bnafar/submissions/#{submission.id}/retry"
      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to include("error" => "mfa_required")
    end

    it "almoxarife e farmacêutico (não admin) → 403, mesmo com step-up" do
      [ keeper, pharmacist ].each do |user|
        stepped_up!(user)
        post_json "/pharmacy/bnafar/submissions/#{submission.id}/retry"
        expect(response).to have_http_status(:forbidden)
        post_json "/pharmacy/bnafar/records/#{SecureRandom.uuid}/correct", { expected_version: 1, reason: "Destino corrigido após a conferência" }
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "sem recusado → 409 nothing_to_retry; fora de R+1 → 409 retry_window_closed" do
      bnafar_record!(submission, status: "accepted")
      stepped_up!(admin)
      post_json "/pharmacy/bnafar/submissions/#{submission.id}/retry"
      expect(response).to have_http_status(:conflict)
      expect(json_body).to include("error" => "nothing_to_retry")

      old = bnafar_submission!(reference_on: today - 2, status: "finished")
      bnafar_record!(old, status: "rejected", error_codes: [ "MSG12" ])
      post_json "/pharmacy/bnafar/submissions/#{old.id}/retry"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "retry_window_closed" ])
    end

    it "remessa desconhecida → 404" do
      stepped_up!(admin)
      post_json "/pharmacy/bnafar/submissions/#{SecureRandom.uuid}/retry"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /pharmacy/bnafar/records/:id/correct" do
    before { on }

    let(:fix) { { expected_version: 1, destination_kind: "cnes", destination_code: "2384299", reason: "Destino corrigido após a conferência" } }

    it "registro de posição → 409 not_correctable; sem versão → 422 expected_version_required; sem step-up → 401" do
      record = bnafar_record!(bnafar_submission!(reference_on: today - 1, status: "finished"), status: "accepted", sent_at: 1.day.ago)
      sign_in_as(step_up_enrolled!(admin))
      post_json "/pharmacy/bnafar/records/#{record.id}/correct", fix
      expect(response).to have_http_status(:unauthorized)

      stepped_up!(admin)
      post_json "/pharmacy/bnafar/records/#{record.id}/correct", fix
      expect([ response.status, json_body["error"] ]).to eq([ 409, "not_correctable" ])
      post_json "/pharmacy/bnafar/records/#{record.id}/correct", fix.except(:expected_version)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "expected_version_required", "expected_version" ])
      post_json "/pharmacy/bnafar/records/#{SecureRandom.uuid}/correct", fix
      expect(response).to have_http_status(:not_found)
    end

    it "registro de outro ambiente → 404 (Q35)" do
      other = bnafar_record!(bnafar_submission!(reference_on: today - 1, status: "finished", environment: "homologation"), status: "accepted", sent_at: 1.day.ago)
      stepped_up!(admin)
      post_json "/pharmacy/bnafar/records/#{other.id}/correct", fix
      expect(response).to have_http_status(:not_found)
    end

    it "Q44: o registro da saída externa traz o id e a versão atual da saída; posição e saída não externa, nulos" do
      losartana.update_columns(vmp_code: "@brasil1000")
      lot = bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "20"), ampp_code: "@brasil20038375080")
      attrs = { "exit_type" => "S-D", "destination_kind" => "cnpj", "destination_code" => "12ABC34501DE35",
                "reason" => "Doação de excedente à entidade", "items" => [ { "lot_id" => lot.id, "quantity" => 3 } ] }
      external = Pharmacy::RecordExternalExit.call(location: central, attrs: attrs, by: keeper).payload.fetch(:exit)
      external.update!(version: 2)
      exits = bnafar_submission!(reference_on: today - 1, subject: "exit", status: "finished")
      positions = bnafar_submission!(reference_on: today - 1, status: "finished")
      bnafar_record!(exits, status: "accepted", subject: "exit", stock_external_exit_id: external.id, sent_at: 2.days.ago)
      bnafar_record!(exits, status: "accepted", subject: "exit", sent_at: 2.days.ago)
      bnafar_record!(positions, status: "accepted", sent_at: 2.days.ago)
      sign_in_as(admin)

      get "/pharmacy/bnafar/submissions/#{exits.id}"
      rows = json_body["records"]
      expect(rows.map { |row| [ row["stock_external_exit_id"], row["stock_external_exit_version"] ] }).to contain_exactly([ external.id, 2 ], [ nil, nil ])
      get "/pharmacy/bnafar/submissions/#{positions.id}"
      expect(json_body["records"].sole).to include("stock_external_exit_id" => nil, "stock_external_exit_version" => nil)
    end

    it "saída externa aceita → 200 com os registros novos (replaces_record_id), sem payload" do
      losartana.update_columns(vmp_code: "@brasil1000")
      lot = bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "20"), ampp_code: "@brasil20038375080")
      attrs = { "exit_type" => "S-D", "destination_kind" => "cnpj", "destination_code" => "12ABC34501DE35",
                "reason" => "Doação de excedente à entidade", "items" => [ { "lot_id" => lot.id, "quantity" => 3 } ] }
      external = Pharmacy::RecordExternalExit.call(location: central, attrs: attrs, by: keeper).payload.fetch(:exit)
      Bnafar::Build.call(reference_on: today, environment: "production", domains: [ Stock::Domain::MEDICATION ], now: Time.current)
      original = BnafarSubmission.find_by!(reference_on: today, subject: "exit").records.sole
      original.update_columns(status: "accepted", accepted_at: Time.current, bnafar_code: 55, sent_at: 2.days.ago)

      stepped_up!(admin)
      post_json "/pharmacy/bnafar/records/#{original.id}/correct", fix
      expect(response).to have_http_status(:ok)
      row = json_body["records"].sole
      expect(row).to include("status" => "pending", "subject" => "exit", "location_name" => central.name)
      expect(row["correct_until"]).to be_nil # a correção só tem prazo depois de aceita
      expect(BnafarRecord.find(row["id"]).replaces_record_id).to eq(original.id)
      expect(external.reload.version).to eq(2)
      expect(response.body).not_to include("payload")

      post_json "/pharmacy/bnafar/records/#{original.id}/correct", fix.merge(expected_version: 1)
      expect(response).to have_http_status(:conflict)

      get "/pharmacy/bnafar/submissions/#{original.bnafar_submission_id}"
      shown = json_body["records"].find { |entry| entry["id"] == original.id }
      expect(Time.iso8601(shown["correct_until"])).to be_within(1.second).of(original.reload.sent_at + 30.days)
    end
  end

  describe "GET /pharmacy/bnafar/pendencies" do
    let!(:incomplete) { stocked_lot!(central, item: losartana, quantity: "10") }
    let!(:cnes_less) { stocked_lot!(unit, item: losartana, quantity: "5") }

    it "code=lot_incomplete filtra; totals.by_code traz todos os códigos do filtro de local" do
      on
      sign_in_as(keeper)

      get "/pharmacy/bnafar/pendencies", params: { code: "lot_incomplete" }
      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).not_to be_empty
      expect(json_body["items"].map { |row| row["code"] }.uniq).to eq([ "lot_incomplete" ])
      row = json_body["items"].find { |entry| entry["stock_lot_id"] == incomplete.id }
      expect(row).to include("stock_location_id" => central.id, "location_name" => central.name, "item_label" => losartana.label)
      expect(row.keys).to match_array(%w[code stock_location_id location_name item_key item_label stock_lot_id fields lot_id lot_number lot_version vmp_code])
      expect(row).to include("lot_id" => incomplete.id, "lot_number" => incomplete.lot_number, "lot_version" => incomplete.bnafar_version)
      expect(row).to have_key("vmp_code")
      expect(json_body["totals"]["by_code"]).to include("lot_incomplete" => 2, "location_without_cnes" => 1)
      expect(json_body["next_before"]).to be_nil
    end

    it "location_id restringe ao local" do
      on
      sign_in_as(admin)

      get "/pharmacy/bnafar/pendencies", params: { location_id: unit.id }
      expect(json_body["items"].map { |row| row["stock_location_id"] }.uniq).to eq([ unit.id ])
      expect(json_body["totals"]["by_code"]["location_without_cnes"]).to eq(1)
      get "/pharmacy/bnafar/pendencies", params: { location_id: "x" }
      expect(json_body).to include("path" => "location_id")
      get "/pharmacy/bnafar/pendencies", params: { code: "nope" }
      expect(json_body).to include("path" => "code")
    end

    it "?cpf= → 422 path cpf; farmacêutico → 403" do
      on
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies", params: { cpf: "1" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("path" => "cpf")
      sign_in_as(assistant)
      get "/pharmacy/bnafar/pendencies"
      expect(response).to have_http_status(:forbidden)
      [ pharmacist, room_lead ].each do |user|
        sign_in_as(user)
        get "/pharmacy/bnafar/pendencies"
        expect(response).to have_http_status(:ok)
      end
    end

    it "paginada: limit/before, cursor estável, 101 → 422 e totals sem depender da página (Q33)" do
      on
      extra = Array.new(3) { stocked_lot!(central, item: losartana, quantity: "3") }
      sign_in_as(admin)

      get "/pharmacy/bnafar/pendencies"
      all = json_body["items"]
      totals = json_body["totals"]
      expect(all.size).to be > 5
      expect(totals["by_location"]).to include(central.id => be_positive, unit.id => be_positive)
      expect(totals["by_code"].values.sum).to eq(all.size)
      expect(extra.size).to eq(3)

      seen = []
      cursor = nil
      loop do
        get "/pharmacy/bnafar/pendencies", params: { limit: 4, before: cursor }.compact
        expect(response).to have_http_status(:ok)
        expect(json_body["items"].size).to be <= 4
        expect(json_body["totals"]).to eq(totals)
        seen.concat(json_body["items"])
        cursor = json_body["next_before"]
        break unless cursor
      end
      expect(seen).to eq(all)
      expect(seen.uniq.size).to eq(all.size)

      get "/pharmacy/bnafar/pendencies", params: { limit: 101 }
      expect(response).to have_http_status(:unprocessable_entity)
      get "/pharmacy/bnafar/pendencies", params: { before: "xx" }
      expect(json_body).to include("path" => "before")
    end

    it "bnafar desligado → 200 sem domain_off (a conta é feita como se o envio estivesse ligado)" do
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies"
      expect(response).to have_http_status(:ok)
      codes = json_body["items"].map { |row| row["code"] }
      expect(codes).to include("lot_incomplete")
      expect(codes).not_to include("domain_off")
    end

    it "bnafar ligado, domínio de medicamentos desligado → domain_off aparece" do
      off
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies"
      expect(json_body["items"].map { |row| row["code"] }).to include("domain_off")
      expect(json_body["totals"]["by_code"]).to include("domain_off")
    end

    it "vacina com código fora do YAML → 200 com product_without_code; o resto da cidade aparece" do
      vaccination_city!
      on
      cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
      gone = vaccine_lot!(cold, code: "ZZ99", doses: 30)
      sign_in_as(admin)

      get "/pharmacy/bnafar/pendencies"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].select { |row| row["stock_lot_id"] == gone.id }.map { |row| row["code"] }).to include("product_without_code")
      expect(json_body["items"].map { |row| row["stock_lot_id"] }).to include(incomplete.id)
    end

    it "bnafar ligado com a credencial recusada, medicamentos desligado → domain_off segue a regra (Q22)" do
      off
      refuse_credential!
      expect(Bnafar::Gate.usable?(city)).to be(false)
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |row| row["code"] }).to include("domain_off")
    end

    it "bnafar ligado com a credencial recusada e medicamentos ligado → sem domain_off (Q22)" do
      on
      refuse_credential!
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies"
      expect(json_body["items"].map { |row| row["code"] }).to include("lot_incomplete")
      expect(json_body["items"].map { |row| row["code"] }).not_to include("domain_off")
    end

    it "sem estoque ligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(admin)
      get "/pharmacy/bnafar/pendencies"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /pharmacy/bnafar/domains" do
    it "programas DM14, os quatro tipos da saída externa e os tipos de local; qualquer papel do estoque" do
      sign_in_as(pharmacist)
      get "/pharmacy/bnafar/domains"
      expect(response).to have_http_status(:ok)
      expect(json_body["programs"].first.keys).to match_array(%w[code label product_type])
      expect(json_body["programs"].size).to eq(Bnafar::Domains.programs.size)
      expect(json_body["exit_types"].map { |row| row["code"] }).to eq(Bnafar::Catalog::EXTERNAL_EXIT_TYPES)
      expect(json_body["exit_types"]).to all(include("label" => be_present))
      expect(json_body["location_types"]).to include({ "kind" => "central", "code" => "A" }, { "kind" => "unit", "code" => "F" })
    end

    it "bnafar desligado → enabled_domains: [] e 200; rotas de envio → 403" do
      sign_in_as(admin)
      get "/pharmacy/bnafar/domains"
      expect(response).to have_http_status(:ok)
      expect(json_body["enabled_domains"]).to eq([])

      [ "/pharmacy/bnafar/status", "/pharmacy/bnafar/submissions", "/pharmacy/bnafar/submissions/#{SecureRandom.uuid}" ].each do |path|
        get path
        expect([ response.status, json_body["feature"] ]).to eq([ 403, "bnafar" ])
      end
      stepped_up!(admin)
      post_json "/pharmacy/bnafar/submissions/#{SecureRandom.uuid}/retry"
      expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "bnafar" ])
      post_json "/pharmacy/bnafar/records/#{SecureRandom.uuid}/correct"
      expect(response).to have_http_status(:forbidden)
    end

    it "required_for? da entrada casa com enabled_domains" do
      on
      sign_in_as(admin)
      get "/pharmacy/bnafar/domains"
      expect(json_body["enabled_domains"]).to eq(Bnafar::Gate.domains_enabled(city))
      expect(json_body["enabled_domains"]).to eq([ Stock::Domain::MEDICATION ])
      [ central, unit ].each do |location|
        expect(Bnafar::Gate.required_for?(city, location)).to eq(json_body["enabled_domains"].include?(Stock::Domain.for(location)))
      end
    end

    it "credencial recusada: enabled_domains segue o interruptor ligado e required_for? casa com ele (Q41)" do
      on
      refuse_credential!
      expect(Bnafar::Gate.domains(city)).to eq([])
      sign_in_as(admin)
      get "/pharmacy/bnafar/domains"
      expect(json_body["enabled_domains"]).to eq([ Stock::Domain::MEDICATION ])
      [ central, unit ].each do |location|
        expect(Bnafar::Gate.required_for?(city, location)).to be(true)
      end
    end

    it "sem estoque ligado → 403" do
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(admin)
      get "/pharmacy/bnafar/domains"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
