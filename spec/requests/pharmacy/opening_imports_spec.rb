require "rails_helper"

# Módulo 27b, Task 14 (contrato §5; Q11, Q19, Q20; R15, R18, R23, R27): o saldo
# inicial pela planilha, REST na cidade. Quem: `municipal_admin` ou o
# `stock_keeper` do central; step-up no apply e no revert; `expected_version`
# em apply, revert e discard. Só o estoque do domínio, nunca o `bnafar`. O
# arquivo chega em base64 num corpo JSON e nunca volta numa resposta.
RSpec.describe "Farmácia — importação do saldo inicial", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location!.tap { |location| location.update!(cnes: "2384299") } }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:header_line) { OpeningImports::Reader::HEADER.join(";") }
  let(:csv) do
    [ header_line,
      [ "2384299", "medicamento", losartana.catmat_code, "", "IMP-1", (Time.zone.today + 200).iso8601, "40", "1,25", bnafar_cnpj,
        "1234567890123", "AFB" ].join(";"),
      [ "9999999", "medicamento", losartana.catmat_code, "", "IMP-2", (Time.zone.today + 200).iso8601, "1", "", "", "", "" ].join(";") ]
      .join("\r\n") + "\r\n"
  end

  def upload(bytes = csv) = json_post("/pharmacy/opening_imports", file_base64: Base64.strict_encode64(bytes))
  def act(import_id, action, version) = json_post("/pharmacy/opening_imports/#{import_id}/#{action}", expected_version: version)

  it "almoxarife do central envia, confere e aplica com step-up (bnafar desligado)" do
    expect(::Bnafar::Gate.usable?(city)).to be(false)
    stepped_up!(keeper)

    upload
    expect(response).to have_http_status(:created)
    body = json_body
    expect(body).to include("status" => "validated", "version" => 2, "rows_total" => 2, "rows_valid" => 1,
                            "uploaded_by" => { "name" => "—" }, "applied_at" => nil, "reverted_at" => nil)
    expect(body["report"]).to include("rows_valid" => 1, "rows_error" => 1, "errors_by_code" => { "cnes_unknown" => 1 },
                                      "rows_missing_send_fields" => 0)
    expect(body["report"]["totals_by_location"])
      .to eq([ { "stock_location_id" => central.id, "location_name" => central.name, "rows" => 1, "quantity" => "40.00", "value_cents" => 5000 } ])
    expect(body["rows"].map { |row| row.slice("line", "status", "error_codes", "lote") })
      .to eq([ { "line" => 2, "status" => "valid", "error_codes" => [], "lote" => "IMP-1" },
               { "line" => 3, "status" => "error", "error_codes" => [ "cnes_unknown" ], "lote" => "IMP-2" } ])
    expect(StockMovement.count).to eq(0)

    get "/pharmacy/opening_imports/#{body['id']}"
    expect(response).to have_http_status(:ok)
    expect(json_body.except("rows", "next_before")).to eq(body.except("rows", "next_before"))

    act(body["id"], "apply", 2)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "applied", "version" => 3, "rows_valid" => 1)
    lot = StockLot.find_by!(lot_number: "IMP-1")
    expect(balance_of(central, lot)).to eq(40)
    expect(StockEntry.find_by!(kind: "opening").recorded_by_user_id).to eq(keeper.id)
  end

  # Q41: os campos de envio seguem o interruptor ligado, não a credencial.
  it "bnafar e medicamentos ligados com a credencial recusada → a linha sem os campos de envio é recusada" do
    bnafar_on!(city, since: 3.days.ago)
    IntegrationCredential.where(kind: "bnafar").update_all(last_check_status: "unauthorized")
    expect(::Bnafar::Gate.usable?(city)).to be(false)
    bare = [ header_line, [ "2384299", "medicamento", losartana.catmat_code, "", "IMP-3", (Time.zone.today + 200).iso8601, "5", "", "", "", "" ].join(";") ]
             .join("\r\n") + "\r\n"
    stepped_up!(keeper)

    upload(bare)
    expect(response).to have_http_status(:created)
    expect(json_body["rows"].sole).to include("status" => "error")
    expect(json_body["report"]).to include("rows_valid" => 0)
  end

  it "rows paginam por before/limit e filtram por status" do
    stepped_up!(keeper)
    upload
    id = json_body["id"]
    get "/pharmacy/opening_imports/#{id}", params: { limit: 1 }
    expect(json_body["rows"].map { |row| row["line"] }).to eq([ 2 ])
    get "/pharmacy/opening_imports/#{id}", params: { limit: 1, before: json_body["next_before"] }
    expect([ json_body["rows"].map { |row| row["line"] }, json_body["next_before"] ]).to eq([ [ 3 ], nil ])
    get "/pharmacy/opening_imports/#{id}", params: { status: "error" }
    expect(json_body["rows"].map { |row| row["line"] }).to eq([ 3 ])
  end

  it "lista as importações da cidade, a mais nova primeiro (Q20, R23)" do
    stepped_up!(keeper)
    upload
    first = json_body["id"]
    upload
    second = json_body["id"]

    get "/pharmacy/opening_imports", params: { limit: 1 }
    expect(response).to have_http_status(:ok)
    item = json_body["items"].sole
    expect(item.keys).to match_array(%w[id status version rows_total rows_valid created_at applied_at reverted_at uploaded_by])
    expect(item["id"]).to eq(second)
    get "/pharmacy/opening_imports", params: { limit: 1, before: json_body["next_before"] }
    expect([ json_body["items"].map { |row| row["id"] }, json_body["next_before"] ]).to eq([ [ first ], nil ])
  end

  it "apply sem step-up → 401 mfa_required" do
    sign_in_as(step_up_enrolled!(keeper))
    upload
    act(json_body["id"], "apply", 2)
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    expect(StockEntry.count).to eq(0)
  end

  it "farmacêutico de UBS → 403 missing_role; municipal_admin passa" do
    farmacia = unit_location!
    sign_in_as(pharmacy_staff!(farmacia, "pharmacist"))
    upload
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    get "/pharmacy/opening_imports"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(pharmacy_admin!)
    upload
    expect(response).to have_http_status(:created)
  end

  it "sem estoque de domínio utilizável → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(keeper)
    upload
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  it "template.csv é o cabeçalho exato" do
    sign_in_as(keeper)
    get "/pharmacy/opening_imports/template.csv"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to eq("#{header_line}\r\n")
  end

  it "6 MB → 413 file_too_large; latin-1 e base64 inválido → 422 invalid_file" do
    sign_in_as(keeper)
    upload("#{header_line}\n".ljust(6 * 1024 * 1024, "x"))
    expect([ response.status, json_body ]).to eq([ 413, { "error" => "file_too_large", "path" => "file_base64" } ])

    upload(File.binread(Rails.root.join("spec/fixtures/opening_imports/latin1.csv")))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_file", "path" => "file_base64" } ])
    json_post "/pharmacy/opening_imports", file_base64: "não é base64"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_file" ])
    expect(OpeningImport.count).to eq(0)
  end

  it "o relatório não traz o conteúdo do arquivo" do
    stepped_up!(keeper)
    encoded = Base64.strict_encode64(csv)
    json_post "/pharmacy/opening_imports", file_base64: encoded
    created = response.body
    get "/pharmacy/opening_imports/#{json_body['id']}"
    [ created, response.body ].each do |text|
      expect(text).not_to include(encoded)
      expect(text).not_to include(header_line)
      expect(text).not_to include("file_data")
      expect(text).not_to include("file_sha256")
    end
  end

  it "versão velha → 409 opening_import_changed (apply e discard); sem versão → 422" do
    stepped_up!(keeper)
    upload
    id = json_body["id"]
    act(id, "apply", 1)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "opening_import_changed" ])
    act(id, "discard", 1)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "opening_import_changed" ])
    json_post "/pharmacy/opening_imports/#{id}/discard", {}
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "expected_version_required", "expected_version" ])

    act(id, "discard", 2)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "discarded", "version" => 3)
    expect(OpeningImport.find(id).file_data).to be_nil
  end

  it "revert com step-up; bloqueado → 409 revert_blocked com os locais (R15)" do
    stepped_up!(keeper)
    upload
    id = json_body["id"]
    act(id, "apply", 2)
    bnafar_loss!(central, StockLot.find_by!(lot_number: "IMP-1"), 1)

    act(id, "revert", 3)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "revert_blocked", "path" => "id", "locations" => [ central.id ])
  end

  it "revert sem bloqueio zera o saldo; id desconhecido → 404" do
    stepped_up!(keeper)
    upload
    id = json_body["id"]
    act(id, "apply", 2)
    act(id, "revert", 3)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "reverted", "version" => 4)
    expect(balance_of(central, StockLot.find_by!(lot_number: "IMP-1"))).to eq(0)

    get "/pharmacy/opening_imports/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
  end
end
