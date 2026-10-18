require "rails_helper"

# Fix round 1 da Task 5: limites do plano, fronteiras do C-E9, matriz de papéis
# e regras de lote/referência. Toda recusa confere status, código e que nada foi gravado.
RSpec.describe "CIQ — cadastro: limites, papéis e regras", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { qc_city! }

  let(:provider) { lab_provider! }
  let(:instrument) { qc_instrument!(provider) }
  let(:exam) { qc_exam!(provider: provider, instrument: instrument) }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:material_body) do
    { provider_id: provider.id, name: "Controle", manufacturer: "Bio-Rad", levels: [ "Nível 1", "Nível 2" ],
      analytes: [ { lab_exam_id: exam.id, analyte_key: "glicose" } ], active: true }
  end

  def post_material(body = material_body) = json_post("/lab/qc/materials", body)
  def post_lot(material_id, codes = { "Nível 1" => "ABC111", "Nível 2" => "ABC222" }, number: "L-1", expires: (Time.zone.today + 300).iso8601)
    json_post "/lab/qc/lots", material_id: material_id, lot_number: number, expires_on: expires, level_barcodes: codes
  end

  def refused(status, error)
    expect([ response.status, json_body["error"] ]).to eq([ Rack::Utils::SYMBOL_TO_STATUS_CODE[status], error ])
  end

  def make_material! = qc_material!(provider, exams: [ exam ])

  describe "limites do material" do
    before { stepped_up!(lead) }

    it "recusa 7 níveis, nível de 41 caracteres ou em branco, nome de 81, 61 analitos; nada é gravado" do
      expect do
        post_material(material_body.merge(levels: (1..7).map { |i| "N#{i}" }))
        refused(:unprocessable_content, "invalid_levels")
        post_material(material_body.merge(levels: [ "x" * 41 ]))
        refused(:unprocessable_content, "invalid_levels")
        post_material(material_body.merge(levels: [ "  " ]))
        refused(:unprocessable_content, "invalid_levels")
        post_material(material_body.merge(name: "n" * 81))
        refused(:unprocessable_content, "invalid_name")
        post_material(material_body.merge(name: " "))
        refused(:unprocessable_content, "invalid_name")
        post_material(material_body.merge(analytes: Array.new(61) { { lab_exam_id: exam.id, analyte_key: "glicose" } }))
        refused(:unprocessable_content, "invalid_analytes")
      end.not_to change(LabQcMaterial, :count)
    end

    it "aceita 6 níveis, nível de 40 e nome de 80" do
      post_material(material_body.merge(levels: (1..5).map { |i| "N#{i}" } + [ "x" * 40 ], name: "n" * 80))
      expect(response).to have_http_status(:created)
    end

    it "lote: número de 41 caracteres e códigos de 2 e 31 caracteres; 10 dígitos é o espaço das amostras" do
      material = make_material!
      expect do
        post_lot(material.id, number: "l" * 41)
        refused(:unprocessable_content, "invalid_lot_number")
        post_lot(material.id, { "Nível 1" => "AB", "Nível 2" => "ABC222" })
        refused(:unprocessable_content, "invalid_barcode")
        post_lot(material.id, { "Nível 1" => "A" * 31, "Nível 2" => "ABC222" })
        refused(:unprocessable_content, "invalid_barcode")
        post_lot(material.id, { "Nível 1" => "1234567890", "Nível 2" => "ABC222" })
        refused(:unprocessable_content, "barcode_taken")
        post_lot(material.id, { "Nível 1" => "SAME01", "Nível 2" => "SAME01" })
        refused(:unprocessable_content, "barcode_taken")
        post_lot(material.id, { "Nível 1" => "áéí123", "Nível 2" => "ABC222" })
        refused(:unprocessable_content, "invalid_barcode")
      end.not_to change { [ LabQcLot.count, LabQcLotBarcode.count ] }
      post_lot(material.id, { "Nível 1" => "A" * 30, "Nível 2" => "a_b.c-3" })
      expect(response).to have_http_status(:created)
      post_lot(material.id, { "Nível 1" => "123456789", "Nível 2" => "12345678901" }, number: "L-2")
      expect(response).to have_http_status(:created) # 9 e 11 dígitos não são do espaço das amostras
    end
  end

  describe "fronteiras decimais da referência (C-E9)" do
    let(:lot) { qc_lot!(make_material!) }
    let(:body) { { lot_id: lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: instrument.id, mean: "90.5", sd: "4.5" } }

    before { stepped_up!(lead) }

    it "recusa 10 inteiros, 5 casas, sd zero ou negativo, formato e não-string; nada é gravado" do
      expect do
        [ { mean: "1234567890" }, { mean: "1.12345" }, { sd: "0" }, { sd: "0.0000" }, { sd: "-1" }, { mean: "1e3" }, { mean: " 1" },
          { mean: "1,5" }, { mean: "" }, { mean: nil }, { mean: 90.5 }, { sd: 4 }, { mean: [ "1" ] }, { sd: "4." }, { sd: ".5" }].each do |change|
          json_post "/lab/qc/targets", body.merge(change)
          refused(:unprocessable_content, "invalid_value")
        end
      end.not_to change(LabQcTarget, :count)
    end

    it "aceita a fronteira 999999999.9999 e média negativa" do
      json_post "/lab/qc/targets", body.merge(mean: "999999999.9999", sd: "999999999.9999")
      expect(response).to have_http_status(:created)
      expect(json_body).to include("mean" => "999999999.9999", "sd" => "999999999.9999")
      json_post "/lab/qc/targets", body.merge(level: "Nível 2", mean: "-1.5", sd: "0.0001")
      expect(json_body).to include("mean" => "-1.5", "sd" => "0.0001")
    end
  end

  describe "matriz de papéis" do
    let(:material) { make_material! }
    let(:lot) { qc_lot!(material) }
    let(:other_lead) { lab_releaser!(lab_provider!, lead: true) }
    let(:target_body) { { lot_id: lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: instrument.id, mean: "90", sd: "4" } }

    def writes
      [ [ :post, "/lab/qc/materials", material_body ],
        [ :patch, "/lab/qc/materials/#{material.id}", material_body.except(:provider_id).merge(name: "Outro") ],
        [ :post, "/lab/qc/lots", { material_id: material.id, lot_number: "N-1", expires_on: (Time.zone.today + 30).iso8601,
                                   level_barcodes: { "Nível 1" => "NEW001", "Nível 2" => "NEW002" } } ],
        [ :post, "/lab/qc/lots/#{lot.id}/close", {} ],
        [ :post, "/lab/qc/targets", target_body ] ]
    end

    def send_write(verb, path, body) = verb == :post ? json_post(path, body) : json_patch(path, body)

    it "liberador comum, técnica e RT de outro laboratório: 403 em toda escrita, sem gravar" do
      lot
      [ lab_releaser!(provider), lab_staff!, other_lead ].each do |user|
        stepped_up!(user)
        expect do
          writes.each do |verb, path, body|
            send_write(verb, path, body)
            refused(:forbidden, "missing_role")
          end
        end.not_to change { [ LabQcMaterial.count, LabQcLot.count, LabQcTarget.count, lot.reload.status, material.reload.name ] }
      end
    end

    it "sem step-up: 401 mfa_required em lotes, referências, PATCH e encerramento" do
      lot
      sign_in_as(lead)
      expect do
        writes.each do |verb, path, body|
          send_write(verb, path, body)
          refused(:unauthorized, "mfa_required")
        end
      end.not_to change { [ LabQcMaterial.count, LabQcLot.count, LabQcTarget.count, lot.reload.status ] }
    end

    it "leitura: técnica 200, RT de outro laboratório e sem papel 403, admin 200" do
      lot
      reads = [ [ "/lab/qc/materials", { provider_id: provider.id } ], [ "/lab/qc/lots", { provider_id: provider.id } ],
                [ "/lab/qc/targets", { lot_id: lot.id } ] ]
      [ lab_staff!, lab_admin!, lead ].each do |user|
        stepped_up!(user)
        reads.each { |path, params| get path, params: params; expect(response).to have_http_status(:ok) }
      end
      [ other_lead, staff_with("sem-papel-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer") ].each do |user|
        stepped_up!(user)
        reads.each { |path, params| get path, params: params; refused(:forbidden, "missing_role") }
      end
    end

    it "UUID inválido ou desconhecido: 404" do
      stepped_up!(lead)
      unknown = SecureRandom.uuid
      get "/lab/qc/materials", params: { provider_id: "x" }
      refused(:not_found, "not_found")
      get "/lab/qc/lots", params: { provider_id: unknown }
      refused(:not_found, "not_found")
      get "/lab/qc/targets", params: { lot_id: unknown }
      refused(:not_found, "not_found")
      get "/lab/qc/targets", params: { lot_id: "x" }
      refused(:not_found, "not_found")
      json_patch "/lab/qc/materials/#{unknown}", material_body.except(:provider_id)
      refused(:not_found, "not_found")
      json_patch "/lab/qc/materials/x", material_body.except(:provider_id)
      refused(:not_found, "not_found")
      json_post "/lab/qc/lots/#{unknown}/close", {}
      refused(:not_found, "not_found")
      json_post "/lab/qc/lots", material_id: unknown, lot_number: "A", expires_on: (Time.zone.today + 3).iso8601, level_barcodes: {}
      refused(:not_found, "not_found")
      json_post "/lab/qc/targets", target_body.merge(lot_id: unknown)
      refused(:not_found, "not_found")
      json_post "/lab/qc/materials", material_body.merge(provider_id: unknown)
      refused(:unprocessable_content, "invalid_provider")
    end
  end

  describe "regras de lote e referência" do
    before { stepped_up!(lead) }

    it "referência de lote vencido: expired_lot, sem gravar" do
      material = make_material!
      lot = qc_lot!(material, expires_on: Time.zone.today + 2)
      body = { lot_id: lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: instrument.id, mean: "90", sd: "4" }
      travel_to(Time.zone.now + 5.days) do
        stepped_up!(lead)
        expect { json_post "/lab/qc/targets", body }.not_to change(LabQcTarget, :count)
        refused(:unprocessable_content, "expired_lot")
      end
    end

    it "aparelho inativo ou de outro laboratório: invalid_instrument; motivo de 1001 caracteres recusado" do
      lot = qc_lot!(make_material!)
      body = { lot_id: lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: instrument.id, mean: "90", sd: "4" }
      json_post "/lab/qc/targets", body
      expect(response).to have_http_status(:created)
      instrument.update!(active: false)
      expect { json_post "/lab/qc/targets", body.merge(reason: "motivo") }.not_to change(LabQcTarget, :count)
      refused(:unprocessable_content, "invalid_instrument")
      instrument.update!(active: true)
      expect { json_post "/lab/qc/targets", body.merge(mean: "91", reason: "r" * 1001) }.not_to change(LabQcTarget, :count)
      refused(:unprocessable_content, "invalid_reason") # C-E11
      json_post "/lab/qc/targets", body.merge(mean: "91", reason: "r" * 1000)
      expect(response).to have_http_status(:created)
    end

    it "listagem de lotes filtra por status e por material; ordena em uso antes de encerrado" do
      material = make_material!
      other = qc_material!(provider, exams: [ exam ], name: "Outro")
      a = travel_to(3.days.ago) { qc_lot!(material, lot_number: "A") }
      b = travel_to(2.days.ago) { qc_lot!(material, lot_number: "B") }
      c = qc_lot!(other, lot_number: "C")
      json_post "/lab/qc/lots/#{a.id}/close", {}
      get "/lab/qc/lots", params: { provider_id: provider.id, status: "closed" }
      expect(json_body["lots"].map { |l| l["lot_number"] }).to eq([ "A" ])
      expect(json_body["lots"].first["closed_on"]).to eq(Time.zone.today.iso8601)
      get "/lab/qc/lots", params: { provider_id: provider.id, status: "in_use", material_id: other.id }
      expect(json_body["lots"].map { |l| l["id"] }).to eq([ c.id ])
      get "/lab/qc/lots", params: { provider_id: provider.id, material_id: material.id }
      expect(json_body["lots"].map { |l| l["id"] }).to match_array([ a.id, b.id ])
      get "/lab/qc/lots", params: { provider_id: provider.id, status: "bogus" }
      expect(json_body["lots"].map { |l| l["lot_number"] }).to eq(%w[C B A]) # em uso (mais novo primeiro), depois encerrado
    end

    it "material com lote: tirar um de dois analitos é recusado, acrescentar é aceito" do
      lipids = qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010295", name: "Lipidograma", analytes: LabHelpers::LIPIDS,
                        instrument_test_code: "LIP")
      material = qc_material!(provider, exams: [ exam, lipids ]) # glicose, ct, hdl, tg
      qc_lot!(material)
      body = { name: material.name, manufacturer: "Bio-Rad", levels: material.levels, active: true }
      before = material.analytes
      expect(before.size).to be > 1
      expect do
        json_patch "/lab/qc/materials/#{material.id}", body.merge(analytes: before.drop(1))
        refused(:unprocessable_content, "invalid_analytes")
      end.not_to change { material.reload.analytes }
      expect(material.analytes).to eq(before)
      json_patch "/lab/qc/materials/#{material.id}", body.merge(analytes: before.map(&:symbolize_keys))
      expect(response).to have_http_status(:ok)
    end

    it "material com lote: acrescentar analito é aceito" do
      material = make_material!
      qc_lot!(material)
      lipids = qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010295", name: "Lipidograma", analytes: LabHelpers::LIPIDS,
                        instrument_test_code: "LIP")
      body = material_body.except(:provider_id)
      json_patch "/lab/qc/materials/#{material.id}", body.merge(analytes: body[:analytes] + [ { lab_exam_id: lipids.id, analyte_key: "ct" } ])
      expect(response).to have_http_status(:ok)
      expect(json_body["analytes"].size).to eq(2)
    end
  end

  describe "C-E12 e C-E13" do
    before { stepped_up!(lead) }

    let(:glucose_two) do
      qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010999", name: "Glicose 2", instrument_test_code: "GL2")
    end

    it "mesma chave de analito em dois exames: duplicate_analyte_key ao criar e ao atualizar, sem gravar" do
      two = material_body[:analytes] + [ { lab_exam_id: glucose_two.id, analyte_key: "glicose" } ]
      expect { post_material(material_body.merge(analytes: two)) }.not_to change(LabQcMaterial, :count)
      refused(:unprocessable_content, "duplicate_analyte_key")
      material = make_material!
      expect { json_patch "/lab/qc/materials/#{material.id}", material_body.except(:provider_id).merge(analytes: two) }.not_to change { material.reload.analytes }
      refused(:unprocessable_content, "duplicate_analyte_key")
    end

    it "código de barras sem diferenciar caixa: outro lote e o mesmo payload" do
      material = make_material!
      post_lot(material.id, { "Nível 1" => "CQB2611N1", "Nível 2" => "CQB2611N2" }, number: "L-1")
      expect(response).to have_http_status(:created)
      expect { post_lot(material.id, { "Nível 1" => "cqb2611n1", "Nível 2" => "OTHER02" }, number: "L-2") }.not_to change(LabQcLotBarcode, :count)
      refused(:unprocessable_content, "barcode_taken")
      expect { post_lot(material.id, { "Nível 1" => "SameCase1", "Nível 2" => "samecase1" }, number: "L-3") }.not_to change(LabQcLot, :count)
      refused(:unprocessable_content, "barcode_taken")
      expect(LabQcLotBarcode.find_ci("cqb2611n1").barcode).to eq("CQB2611N1")
      expect { LabQcLotBarcode.create!(lab_qc_lot: LabQcLot.first, level: "Nível 9", barcode: "cqb2611n2", created_at: Time.current) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  it "values é filtrado do log de parâmetros (D5)" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter("values" => [ { "value" => "98.5" } ], "level_barcodes" => { "a" => "b" }, "justification" => "x"))
      .to eq("values" => "[FILTERED]", "level_barcodes" => "[FILTERED]", "justification" => "[FILTERED]")
  end
end
