require "rails_helper"
require "pdf/reader"

# Contrato §5 e §9 (F-21.20): liberação parcial e total com assinatura
# avançada (TOTP consumido, hash do PDF); médico só ICP; crítico libera e
# vai à fila; o 21a recebe source lab, sem duplicar; não liberado invisível.
# Ruling D4/E3: os itens são conferidos ANTES de consumir o TOTP (recusa não
# queima o código). B42 item_ids; B54 item congelado em laudo pending_signature;
# D5/E14 sem pedido ICP criado, nada fica esperando.
RSpec.describe "Laboratório — liberação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { lab_city! }

  let(:provider) { lab_provider!(name: "Laboratório Municipal Central") }
  let!(:lead) { lab_releaser!(provider, council: "CRBM", lead: true) }
  let(:glucose) { lab_exam!(provider: provider) }
  let(:creat) do
    lab_exam!(provider: provider, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE",
              analytes: [ LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "loinc" => "2160-0",
                                                          "decimals" => 2, "critical_high" => nil, "entry_min" => nil, "entry_max" => nil) ])
  end
  let(:req) { received_requisition!(provider: provider, exams: [ glucose, creat ]) }
  let(:items) { req.items.to_a }

  def release(item_ids, signature: "advanced", user: lead, totp: totp_for(user))
    json_post "/lab/requisitions/#{req.id}/release", item_ids: item_ids, signature: signature, totp: totp
  end

  it "parcial com avançada: laudo liberado, 21a com resultado lab, crítico na fila; depois o resto" do
    type!(items[0], { glicose: "450" })
    sign_in_as(lead)
    release([ items[0].id ], totp: "000000")
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    release([ items[1].id ])
    expect(json_body["error"]).to eq("invalid_transition")
    # O código do passo não foi queimado pela recusa de cima (D4/E3).
    release([ items[0].id ])
    expect(response).to have_http_status(:created)
    summary = json_body
    expect(summary).to include("version" => 1, "partial" => true, "status" => "released", "signature_kind" => "advanced",
                               "item_ids" => [ items[0].id ])
    expect(summary["pdf_url"]).to start_with("/exams/files/")
    report = LabReport.find(summary["id"])
    expect(report.pdf_sha256).to eq(Digest::SHA256.hexdigest(report.pdf_file.bytes))
    expect(items[0].reload.status).to eq("released")
    order = items[0].exam_order.reload
    expect(order.status).to eq("resulted")
    result = order.result
    expect(result).to have_attributes(source: "lab", critical: true, laboratory_name: "Laboratório Municipal Central")
    expect(result.values_list.sole).to eq("key" => "glicose", "label" => "Glicose", "value" => "450", "unit" => "mg/dL", "loinc" => "2345-7")
    expect(result.pdf_file_id).not_to eq(report.pdf_file_id)
    expect(order).to be_escalated
    expect(items[1].exam_order.reload.result).to be_nil
    expect(req.reload.status).to eq("in_analysis")
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 1)
    # Item já liberado: a recusa vem dos itens, antes do código (que nem é conferido).
    release([ items[0].id ], totp: "999999")
    expect(json_body["error"]).to eq("invalid_transition")
    type!(items[1], { creatinina: "0,9" })
    # Mesmo passo de 30 s já consumido: recusado.
    release([ items[1].id ])
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    expect(items[1].reload.status).to eq("typed")
    travel 31.seconds do
      release([ items[1].id ])
      expect(json_body).to include("version" => 2, "partial" => false)
    end
    expect(req.reload.status).to eq("released")
    expect(ExamResult.where(exam_order_id: items.map(&:exam_order_id)).count).to eq(2)
    expect(DomainEvent.where(name: "lab_report.released").map { |e| e.payload.keys.sort }.uniq)
      .to eq([ %w[lab_report_id lab_requisition_id partial signature_kind] ])
  end

  it "médico só com ICP; ICP sem assinatura digital utilizável 422; sem RT 422; laboratório incompleto 422" do
    type!(items[0], { glicose: "98" })
    doctor = lab_releaser!(provider, council: "CRM", deputy: true)
    sign_in_as(doctor)
    release([ items[0].id ], user: doctor)
    expect(json_body["error"]).to eq("icp_required")
    release([ items[0].id ], user: doctor, signature: "icp")
    expect(json_body["error"]).to eq("signature_unavailable")
    release([ items[0].id ], user: doctor, signature: "qualquer")
    expect(json_body["error"]).to eq("invalid_signature")
    sign_in_as(lead)
    provider.update!(address: nil)
    totp = totp_for(lead)
    release([ items[0].id ], totp: totp)
    expect(json_body["error"]).to eq("laboratory_incomplete")
    provider.update!(address: "Rua do Laboratório, 100 — Centro")
    bio = lab_releaser!(provider, council: "CRF")
    LabReleaser.find_by(user: lead).update!(ended_at: Time.current)
    sign_in_as(bio)
    release([ items[0].id ], user: bio)
    expect(json_body["error"]).to eq("technical_lead_missing")
    sign_in_as(lab_staff!)
    release([ items[0].id ], user: bio)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    expect(LabReport.count).to eq(0)
    # As recusas do laboratório não queimaram o código do RT.
    expect(lead.reload.last_otp_step).to be_nil
  end

  it "liberador sem conselho no perfil: council_missing" do
    type!(items[0], { glicose: "98" })
    lead.professional.update_columns(council: "COREN")
    sign_in_as(lead)
    release([ items[0].id ])
    expect(json_body["error"]).to eq("council_missing")
  end

  it "fila e conferência: itens digitados com linhas; trilha; PDF por URL curta com trilha" do
    type!(items[0], { glicose: "98" })
    sign_in_as(lead)
    expect { get "/lab/releases", params: { provider_id: provider.id } }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    row = json_body["requisitions"].sole
    expect(row).to include("id" => req.id, "number" => req.number)
    typed = row["items"].find { |i| i["id"] == items[0].id }
    expect(typed).to include("status" => "typed", "restriction_note" => nil)
    expect(typed["results"].sole).to include("value" => "98", "flag" => "normal", "effective" => true)
    release([ items[0].id ])
    get "/lab/releases", params: { provider_id: provider.id }
    expect(json_body["requisitions"]).to eq([])
    get "/lab/releases/#{req.id}"
    summary = json_body["reports"].sole
    expect(summary).to include("status" => "released", "item_ids" => [ items[0].id ])
    expect { get "/lab/reports/#{summary['id']}/pdf" }.not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    url = json_body["pdf_url"]
    expect { get url }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last
    expect(trail.payload).to include("access" => "lab_report", "lab_report_id" => summary["id"])
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("LAUDO DE EXAMES LABORATORIAIS")
  end

  it "fila e PDF só para quem é do laboratório" do
    type!(items[0], { glicose: "98" })
    other = lab_provider!
    outsider = lab_releaser!(other, lead: true)
    sign_in_as(outsider)
    get "/lab/releases/#{req.id}"
    expect(response).to have_http_status(:forbidden)
    get "/lab/releases", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    json_post "/lab/requisitions/#{req.id}/release", item_ids: [ items[0].id ], signature: "advanced", totp: totp_for(outsider)
    expect(response).to have_http_status(:forbidden)
    sign_in_as(lead)
    release([ items[0].id ])
    report_id = json_body["id"]
    sign_in_as(outsider)
    get "/lab/reports/#{report_id}/pdf"
    expect(response).to have_http_status(:forbidden)
  end

  it "não liberado é invisível fora do laboratório" do
    type!(items[0], { glicose: "98" })
    order = items[0].exam_order
    sign_in_as(order.requester_user)
    get "/exams/orders/#{order.id}"
    expect(json_body["result"]).to be_nil
    # Nenhum "value" em lugar nenhum da resposta (o texto cru teria "98" ao
    # acaso em UUIDs e códigos).
    values = ->(node) { node.is_a?(Hash) ? node.flat_map { |k, v| (k == "value" ? [ v ] : []) + values.(v) } : Array(node).grep(Enumerable).flat_map { |v| values.(v) } }
    expect(values.(json_body)).not_to include("98")
  end

  describe "ICP (pedido do 19b na mesma transação; D5/E14)" do
    let(:doctor) do
      lab_releaser!(provider, council: "CRM", deputy: true).tap do |user|
        user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
      end
    end

    before do
      Platform::Features.set!(city: city, key: "digital_signature", enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      type!(items[0], { glicose: "98" })
    end

    it "sem LabReport no catálogo do 19b (até a Task 18) o caminho ICP fica fechado: signature_unavailable" do
      linked_certificate!(doctor)
      sign_in_as(doctor)
      release([ items[0].id ], user: doctor, signature: "icp", totp: nil)
      expect(json_body["error"]).to eq("signature_unavailable")
      expect(LabReport.count).to eq(0)
    end

    context "com LabReport no catálogo" do
      before { stub_const("Signatures::DocumentTypes::MODELS", Signatures::DocumentTypes::MODELS.merge("LabReport" => "lab_report")) }

      it "sem certificado ativo: no_active_certificate, nada gravado" do
        sign_in_as(doctor)
        release([ items[0].id ], user: doctor, signature: "icp", totp: nil)
        expect(json_body["error"]).to eq("no_active_certificate")
        expect(LabReport.count).to eq(0)
      end

      it "nasce pending_signature com o pedido; o 21a não recebe nada; o item congela (B54)" do
        linked_certificate!(doctor)
        sign_in_as(doctor)
        release([ items[0].id ], user: doctor, signature: "icp", totp: nil)
        expect(response).to have_http_status(:created)
        expect(json_body).to include("status" => "pending_signature", "signature_kind" => "icp", "pdf_url" => nil, "released_at" => nil,
                                     "item_ids" => [ items[0].id ])
        report = LabReport.find(json_body["id"])
        expect(SignatureRequest.where(document_type: "LabReport", document_id: report.id).count).to eq(1)
        expect(items[0].reload.status).to eq("typed")
        expect(items[0].exam_order.reload.result).to be_nil
        expect(DomainEvent.where(name: "lab_report.released").count).to eq(0)

        # B54: entrada e escolha recusadas enquanto o laudo espera a assinatura.
        sign_in_as(lab_staff!)
        json_post "/lab/results", item_id: items[0].id, values: [ { analyte_key: "glicose", value: "120" } ]
        expect([ response.status, json_body["error"] ]).to eq([ 422, "item_frozen" ])
        sign_in_as(lead)
        json_post "/lab/results/#{items[0].results.last.id}/choose"
        expect([ response.status, json_body["error"] ]).to eq([ 422, "item_frozen" ])
        # Nem outra liberação do mesmo item.
        release([ items[0].id ])
        expect(json_body).to include("error" => "invalid_transition", "status" => "pending_signature")
        # Fora da fila de liberação.
        get "/lab/releases", params: { provider_id: provider.id }
        expect(json_body["requisitions"]).to eq([])
      end

      it "pedido do 19b não criado (:manual/:exists/:unusable) desfaz tudo" do
        linked_certificate!(doctor)
        allow(Signatures::OpenRequest).to receive(:call).and_return(:manual)
        sign_in_as(doctor)
        release([ items[0].id ], user: doctor, signature: "icp", totp: nil)
        expect(json_body["error"]).to eq("no_active_certificate")
        expect(LabReport.count).to eq(0)
        expect(LabReportItem.count).to eq(0)
      end
    end
  end
end
