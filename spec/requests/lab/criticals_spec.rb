require "rails_helper"

# Spec §5.7 e contrato §5 (B27, B30, B51, B52; E4): o aviso do crítico é
# registrado (quem, papel, canal, quando); liberado sem aviso entra na fila e
# fica até ter aviso; contador sem trilha.
RSpec.describe "Laboratório — valores críticos", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:releaser) { lab_releaser!(provider, lead: true) }
  let(:exam) { lab_exam!(provider: provider) }
  let(:req) { received_requisition!(provider: provider, exams: [ exam ]) }
  let(:item) { type!(req.items.first, { glicose: "450" }) }
  let(:critical) { item.results.last }

  # Laudo liberado cobrindo o item (Task 17 ainda não existe: gravado direto).
  def release!(item, at: Time.current, replaces: nil, sign: true)
    report = LabReport.create!(lab_requisition: item.lab_requisition, exam_provider: provider, status: "pending_signature",
                               version: (item.lab_requisition.reports.maximum(:version) || 0) + 1, partial: false,
                               signature_kind: "icp", released_by_user: releaser, content: "{}", content_sha256: "a" * 64,
                               verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.short_code,
                               replaces_report: replaces, rectification_reason: replaces && "erro de digitação")
    LabReportItem.create!(lab_report: report, lab_requisition_item: item)
    return report unless sign

    sign!(report, item, replaces: replaces, at: at)
  end

  def sign!(report, item, replaces:, at: Time.current)
    replaces&.update!(status: "rectified")
    file = pdf_file!(user: releaser).tap { |f| f.update!(consumed_at: Time.current) }
    report.update!(status: "released", released_at: at, pdf_file_id: file.id, pdf_sha256: "b" * 64)
    item.update!(status: "released")
    report
  end

  def notice(result, **over)
    { result_id: result.id, notified_person: "Dra. Helena", notified_role: "Médica solicitante", channel: "telefone",
      notified_at: Time.current.iso8601 }.merge(over)
  end

  def count = (get("/lab/criticals/unnotified/count") && json_body["count"])

  it "liberado sem aviso aparece na fila e no contador; o aviso tira" do
    release!(item)
    sign_in_as(releaser)
    expect { get "/lab/criticals/unnotified/count" }.not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    expect(json_body).to eq("count" => 1)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole).to include("result_id" => critical.id, "requisition_number" => req.number,
                                                   "analyte_name" => "Glicose", "flag" => "critical_high")
    expect(json_body["criticals"].sole.keys).not_to include("value")
    expect(json_body["next_after"]).to be_nil
    json_post "/lab/criticals", notice(critical)
    expect(response).to have_http_status(:created)
    expect(count).to eq(0)
    notice = LabCriticalNotice.sole
    expect(notice.notified_person).to eq("Dra. Helena")
    expect(notice.recorded_by_user_id).to eq(releaser.id)
    expect(DomainEvent.where(name: "lab_critical.notified").sole.payload.keys).to contain_exactly("lab_critical_notice_id", "lab_result_id")
  end

  it "a lista grava trilha por requisição; o contador devolve só { count }" do
    release!(item)
    sign_in_as(releaser)
    expect { get "/lab/criticals/unnotified" }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "lab_report", "lab_requisition_id" => req.id)
    get "/lab/criticals/unnotified/count"
    expect(json_body.keys).to eq([ "count" ])
  end

  it "recusa resultado não crítico, canal fora da lista e quem não é do laboratório" do
    sign_in_as(releaser)
    normal = type!(req.items.first, { glicose: "90" }).results.last
    json_post "/lab/criticals", notice(normal, notified_person: "X", notified_role: "Y")
    expect(json_body["error"]).to eq("not_critical")
    crit = critical
    json_post "/lab/criticals", notice(crit, channel: "whatsapp")
    expect(json_body["error"]).to eq("invalid_notice")
    sign_in_as(lab_releaser!(lab_provider!))
    json_post "/lab/criticals", notice(crit)
    expect(json_body["error"]).to eq("missing_role")
    json_post "/lab/criticals", notice(crit, result_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
  end

  it "valida tamanhos, futuro e data anterior ao recebimento da amostra" do
    crit = critical
    sign_in_as(releaser)
    [ { notified_person: "a" * 121 }, { notified_role: "b" * 61 }, { notified_person: " " }, { notified_role: "" },
      { notified_at: 1.hour.from_now.iso8601 }, { notified_at: 1.hour.ago.iso8601 }, { notified_at: "ontem" } ].each do |bad|
      json_post "/lab/criticals", notice(crit, **bad)
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_notice" ]), bad.inspect
    end
    json_post "/lab/criticals", notice(crit, notified_person: "a" * 120, notified_role: "b" * 60)
    expect(response).to have_http_status(:created)
    expect(LabCriticalNotice.count).to eq(1)
  end

  it "aviso dado antes da digitação é aceito (a partir do recebimento da amostra)" do
    crit = critical
    received = crit.lab_requisition_item.lab_sample.received_at
    sign_in_as(releaser)
    json_post "/lab/criticals", notice(crit, notified_at: received.iso8601)
    expect(response).to have_http_status(:created)
  end

  it "aviso na cópia escolhida é aceito mesmo anterior à escolha" do
    first = type!(req.items.first, { glicose: "450" }).results.last
    type!(req.items.first, { glicose: "90" })
    copy = Lab::ChooseResult.call(result: first, by: releaser).payload[:result]
    sign_in_as(releaser)
    json_post "/lab/criticals", notice(copy, notified_at: first.entered_at.iso8601)
    expect(response).to have_http_status(:created)
  end

  it "um aviso por resultado: o segundo é 409 (índice único como rede)" do
    crit = critical
    sign_in_as(releaser)
    json_post "/lab/criticals", notice(crit)
    expect(response).to have_http_status(:created)
    json_post "/lab/criticals", notice(crit, notified_person: "Outro")
    expect([ response.status, json_body["error"] ]).to eq([ 409, "conflict" ])
    expect(LabCriticalNotice.count).to eq(1)
    expect do
      LabCriticalNotice.create!(lab_result: crit, notified_person: "Z", notified_role: "R", channel: "sistema", notified_at: Time.current,
                                recorded_by_user: releaser, created_at: Time.current)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "só a linha que vale no laudo conta: repetição normal depois da liberação não esconde o crítico não avisado" do
    crit = critical
    release!(item)
    type!(req.items.first, { glicose: "90" })
    sign_in_as(releaser)
    expect(count).to eq(1)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(crit.id)
  end

  it "repetição normal antes da liberação tira o crítico (a que vale no laudo é a normal)" do
    type!(req.items.first, { glicose: "450" })
    release!(type!(req.items.first, { glicose: "90" }))
    sign_in_as(releaser)
    expect(count).to eq(0)
  end

  it "retificação: linha crítica nova só entra quando o laudo retificado é liberado, e pede aviso novo (B51)" do
    first = release!(item)
    sign_in_as(releaser)
    json_post "/lab/criticals", notice(critical)
    expect(count).to eq(0)
    new_row = type!(req.items.first, { glicose: "480" }).results.last # retificação ainda não liberada
    expect(new_row.critical?).to be(true)
    expect(count).to eq(0)
    release!(req.items.first.reload, replaces: first)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(new_row.id)
    json_post "/lab/criticals", notice(new_row)
    expect(response).to have_http_status(:created)
    expect(count).to eq(0)
  end

  it "usa a linha congelada no laudo, não a digitada entre a criação e a assinatura (N1)" do
    crit = critical
    report = release!(item, sign: false)
    type!(req.items.first, { glicose: "90" }) # depois do congelamento, antes da assinatura
    sign!(report, req.items.first.reload, replaces: nil)
    sign_in_as(releaser)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(crit.id)
  end

  it "o 409 dentro de transação externa não aborta a de fora (N3)" do
    crit = critical
    LabCriticalNotice.create!(lab_result: crit, notified_person: "A", notified_role: "R", channel: "sistema", notified_at: Time.current,
                              recorded_by_user: releaser, created_at: Time.current)
    ApplicationRecord.transaction do
      allow(LabCriticalNotice).to receive(:exists?).and_return(false) # força o índice único a decidir
      result = Lab::RecordCriticalNotice.call(result_id: crit.id, notified_person: "B", notified_role: "R", channel: "sistema",
                                              notified_at: Time.current.iso8601, by: releaser)
      expect(result.reason).to eq(:conflict)
      expect(LabCriticalNotice.count).to eq(1) # a transação de fora segue usável
    end
  end

  it "retificar para valor normal não tira o crítico liberado: segue na fila e no contador até ter aviso (B53)" do
    crit = critical
    first = release!(item)
    type!(req.items.first, { glicose: "90" })
    release!(req.items.first.reload, replaces: first)
    sign_in_as(releaser)
    expect(count).to eq(1)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(crit.id) # uma vez, mesmo coberta por vários laudos
    json_post "/lab/criticals", notice(crit)
    expect(response).to have_http_status(:created)
    expect(count).to eq(0)
  end

  it "aviso na linha de origem vale para a cópia escolhida, igual ao /lab/entry (L9), em profundidade 1 e 2" do
    a = type!(req.items.first, { glicose: "450" }).results.last
    type!(req.items.first, { glicose: "90" })
    copy1 = Lab::ChooseResult.call(result: a, by: releaser).payload[:result]
    type!(req.items.first, { glicose: "91" })
    copy2 = Lab::ChooseResult.call(result: copy1, by: releaser).payload[:result]
    expect(copy2.chosen_from_id).to eq(copy1.id)
    release!(req.items.first.reload)
    sign_in_as(releaser)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(copy2.id)
    json_post "/lab/criticals", notice(a)
    expect(response).to have_http_status(:created)
    expect(count).to eq(0)
    rows = req.items.first.reload.results.to_a
    expect(Lab::EntryJson.notified_ids(rows)).to include(copy1.id, copy2.id)
  end

  it "sem janela de idade: crítico liberado há mais de 30 dias segue na fila e no contador" do
    old = travel_to(40.days.ago) do
      release!(item)
      critical
    end
    sign_in_as(releaser)
    expect(count).to eq(1)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(old.id)
  end

  it "lista paginada da mais antiga para a mais nova, com next_after e limit" do
    ids = []
    3.times do |i|
      travel_to((10 - i).days.ago) do
        r = received_requisition!(provider: provider, exams: [ exam ])
        it = type!(r.items.first, { glicose: "450" })
        release!(it)
        ids << it.results.last.id
      end
    end
    sign_in_as(releaser)
    get "/lab/criticals/unnotified", params: { limit: 2 }
    expect(json_body["criticals"].map { |c| c["result_id"] }).to eq(ids.first(2))
    expect(json_body["next_after"]).to be_present
    get "/lab/criticals/unnotified", params: { limit: 2, after: json_body["next_after"] }
    expect(json_body["criticals"].map { |c| c["result_id"] }).to eq(ids.last(1))
    expect(json_body["next_after"]).to be_nil
    get "/lab/criticals/unnotified", params: { after: "lixo" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "item sem laudo liberado não entra; escopo: outro laboratório não vê; lab_staff vê; sem papel é 403" do
    critical
    sign_in_as(releaser)
    expect(count).to eq(0)
    release!(item)
    sign_in_as(lab_releaser!(lab_provider!))
    expect(count).to eq(0)
    sign_in_as(lab_staff!)
    expect(count).to eq(1)
    sign_in_as(lab_admin!)
    get "/lab/criticals/unnotified/count"
    expect(response).to have_http_status(:forbidden)
  end

  it "o número de consultas não cresce com a quantidade de críticos" do
    release!(item)
    sign_in_as(releaser)
    count_queries = lambda do
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| n += 1 unless p[:name] == "SCHEMA" || p[:sql] =~ /SAVEPOINT/ }
      get "/lab/criticals/unnotified"
      ActiveSupport::Notifications.unsubscribe(sub)
      n
    end
    one = count_queries.call
    2.times do
      r = received_requisition!(provider: provider, exams: [ exam ])
      release!(type!(r.items.first, { glicose: "450" }))
    end
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].size).to eq(3)
    expect(count_queries.call - one).to be <= 4 # trilha: 1 evento por requisição nova; consultas fixas
  end
end
