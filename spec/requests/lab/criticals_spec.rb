require "rails_helper"

# Spec §5.7 e contrato §5 (B27, B30; E4): o aviso do crítico é registrado
# (quem, papel, canal, quando); liberado sem aviso entra na fila; contador sem trilha.
RSpec.describe "Laboratório — valores críticos", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:releaser) { lab_releaser!(provider, lead: true) }
  let(:exam) { lab_exam!(provider: provider) }
  let(:req) { received_requisition!(provider: provider, exams: [ exam ]) }
  let(:item) { type!(req.items.first, { glicose: "450" }) }
  let(:critical) { item.results.last }

  def notice(result, **over)
    { result_id: result.id, notified_person: "Dra. Helena", notified_role: "Médica solicitante", channel: "telefone",
      notified_at: Time.current.iso8601 }.merge(over)
  end

  it "liberado sem aviso aparece na fila e no contador; o aviso tira" do
    item.update!(status: "released")
    sign_in_as(releaser)
    expect { get "/lab/criticals/unnotified/count" }.not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    expect(json_body).to eq("count" => 1)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole).to include("result_id" => critical.id, "requisition_number" => req.number,
                                                   "analyte_name" => "Glicose", "flag" => "critical_high")
    expect(json_body["criticals"].sole.keys).not_to include("value")
    json_post "/lab/criticals", notice(critical)
    expect(response).to have_http_status(:created)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
    notice = LabCriticalNotice.sole
    expect(notice.notified_person).to eq("Dra. Helena")
    expect(notice.recorded_by_user_id).to eq(releaser.id)
    expect(DomainEvent.where(name: "lab_critical.notified").sole.payload.keys).to contain_exactly("lab_critical_notice_id", "lab_result_id")
  end

  it "a lista grava trilha por requisição; o contador devolve só { count }" do
    item.update!(status: "released")
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

  it "valida tamanhos, futuro e data anterior ao resultado" do
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

  it "um aviso por resultado: o segundo é 409" do
    crit = critical
    sign_in_as(releaser)
    json_post "/lab/criticals", notice(crit)
    expect(response).to have_http_status(:created)
    json_post "/lab/criticals", notice(crit, notified_person: "Outro")
    expect([ response.status, json_body["error"] ]).to eq([ 409, "conflict" ])
    expect(LabCriticalNotice.count).to eq(1)
  end

  it "só a linha que vale conta (B30): repetição normal depois tira o crítico da fila" do
    type!(req.items.first, { glicose: "450" })
    item = type!(req.items.first, { glicose: "90" })
    item.update!(status: "released")
    sign_in_as(releaser)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
  end

  it "aviso na linha de origem vale para a cópia escolhida, igual ao /lab/entry (L9)" do
    first = type!(req.items.first, { glicose: "450" }).results.last
    type!(req.items.first, { glicose: "90" })
    copy = Lab::ChooseResult.call(result: first, by: releaser).payload[:result]
    expect(copy.critical?).to be(true)
    req.items.first.update!(status: "released")
    sign_in_as(releaser)
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].sole["result_id"]).to eq(copy.id)
    json_post "/lab/criticals", notice(first)
    expect(response).to have_http_status(:created)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
    rows = req.items.first.reload.results.to_a
    expect(Lab::EntryJson.notified_ids(rows)).to include(copy.id)
  end

  it "só liberados nos últimos 30 dias" do
    item.update!(status: "released")
    sign_in_as(releaser)
    item.update_columns(updated_at: 31.days.ago)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
    item.update_columns(updated_at: 29.days.ago)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 1)
  end

  it "item não liberado não entra; escopo: liberador de outro laboratório não vê; lab_staff vê; sem papel é 403" do
    critical
    sign_in_as(releaser)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
    item.update!(status: "released")
    sign_in_as(lab_releaser!(lab_provider!))
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 0)
    sign_in_as(lab_staff!)
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 1)
    sign_in_as(lab_admin!)
    get "/lab/criticals/unnotified/count"
    expect(response).to have_http_status(:forbidden)
  end

  it "o número de consultas não cresce com a quantidade de críticos" do
    item.update!(status: "released")
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
      type!(r.items.first, { glicose: "450" }).update!(status: "released")
    end
    get "/lab/criticals/unnotified"
    expect(json_body["criticals"].size).to eq(3)
    expect(count_queries.call - one).to be <= 4 # trilha: 1 evento por requisição nova; consultas fixas
  end
end
