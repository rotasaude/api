require "rails_helper"

# Contrato §5 com B6, B8, B9 e B11: competências por estabelecimento com
# produção (faturista e admin leem), pendências com trilha, fechar e reabrir
# (só faturista, step-up), versões em envelope (faturista e admin) e o
# arquivo só para o faturista, com trilha e nome sem dado pessoal.
RSpec.describe "Faturamento — competências e arquivos", type: :request do
  before do
    billing_city!
    billing_settings!
  end

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:clerk) { billing_clerk! }
  let(:competence) { Time.zone.today.strftime("%Y%m") }
  let!(:procedure) { recorded_procedure!(unit: unit, professional: doctor) }
  let(:period) { procedure.billing_period }

  it "lista as competências com id, versão 0 antes do fechamento e resumo; faturista e admin; outros 403" do
    recorded_procedure!(unit: unit, professional: doctor, cid10: nil)
    sign_in_as(lab_admin!)
    get "/billing/periods", params: { competence: competence }
    expect(json_body["periods"].sole).to eq(
      "id" => period.id, "establishment" => { "type" => "health_unit", "id" => unit.id, "cnes" => unit.cnes, "name" => unit.name },
      "competence" => competence, "status" => "open", "version" => 0, "closed_at" => nil, "closed_by" => nil, "reopened_reason" => nil,
      "summary" => { "bpa_i_lines" => 1, "bpa_c_lines" => 0, "not_billable" => { "cid_required" => 1 }, "pending" => 1 }
    )
    expect(DomainEvents.respond_to?(:publish)).to be(true)
    expect(DomainEvent.where(name: "billing_period.pending_viewed")).to be_empty # a lista não grava trilha
    get "/billing/periods", params: { competence: "2026-10" }
    expect(json_body).to eq("error" => "invalid_filter")
    sign_in_as(doctor)
    get "/billing/periods"
    expect(response).to have_http_status(:forbidden)
  end

  # §13 E18: o filtro "abertas" lista todas as competências abertas, com ou sem competence.
  it "?status=open lista as abertas de todas as competências; status inválido 422" do
    previous = (Time.zone.today << 1).strftime("%Y%m")
    older = BillingPeriod.create!(health_unit: upa!, competence: previous)
    closed = BillingPeriod.create!(health_unit: upa!, competence: previous, status: "closed", version: 1, closed_at: Time.current,
                                   closed_by_user: doctor)
    sign_in_as(clerk)
    get "/billing/periods", params: { status: "open" }
    expect(json_body["periods"].map { |p| p["id"] }).to contain_exactly(period.id, older.id)
    get "/billing/periods", params: { status: "open", competence: previous }
    expect(json_body["periods"].map { |p| p["id"] }).to eq([ older.id ])
    get "/billing/periods", params: { competence: previous }
    expect(json_body["periods"].map { |p| p["id"] }).to contain_exactly(older.id, closed.id)
    get "/billing/periods", params: { status: "abertas" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_filter")
  end

  it "pendências: faturista e admin; trilha só com ids" do
    recorded_procedure!(unit: unit, professional: doctor, cid10: nil)
    sign_in_as(lab_admin!)
    get "/billing/periods/#{period.id}/pending"
    expect(json_body["items"].sole).to include("reasons" => %w[cid_required], "fix" => "procedure", "sigtap_code" => "0301060029", "late" => false)
    expect(DomainEvent.where(name: "billing_period.pending_viewed").last.payload.keys).to match_array(%w[billing_period_id user_id])
    get "/billing/periods/#{SecureRandom.uuid}/pending"
    expect(response).to have_http_status(:not_found)
  end

  it "fechar e reabrir: só faturista, com step-up; transição errada 409" do
    sign_in_as(lab_admin!)
    json_post "/billing/periods/#{period.id}/close"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(clerk)
    json_post "/billing/periods/#{period.id}/close"
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    stepped_up!(clerk)
    json_post "/billing/periods/#{period.id}/close"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "closed", "version" => 1, "closed_by" => clerk.email_address)
    json_post "/billing/periods/#{period.id}/close"
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "invalid_transition", "status" => "closed")
    json_post "/billing/periods/#{period.id}/reopen", reason: "curto"
    expect(json_body).to eq("error" => "reason_required")
    json_post "/billing/periods/#{period.id}/reopen", reason: "CNS do médico corrigido no CNES"
    expect(json_body).to include("status" => "open", "version" => 1, "reopened_reason" => "CNS do médico corrigido no CNES")
    json_post "/billing/periods/#{period.id}/reopen", reason: "CNS do médico corrigido no CNES"
    expect(response).to have_http_status(:conflict)
  end

  it "versões em envelope (faturista e admin); arquivo só do faturista, com trilha e nome sem dado pessoal" do
    export = Billing::Close.call(period: period, by: clerk).payload[:export]
    sign_in_as(lab_admin!)
    get "/billing/periods/#{period.id}/exports"
    expect(json_body).to eq("exports" => [ { "id" => export.id, "version" => 1, "sha256" => export.sha256, "lines_bpa_i" => 1, "lines_bpa_c" => 0,
                                             "generated_at" => export.generated_at.iso8601, "generated_by" => clerk.email_address } ])
    get "/billing/exports/#{export.id}/file"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(clerk)
    get "/billing/exports/#{export.id}/file"
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(export.bytes)
    expect(response.media_type).to eq("text/plain")
    expect(response.headers["Content-Disposition"]).to include("attachment", "bpa-#{unit.cnes}-#{competence}-v1.txt")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(DomainEvent.where(name: "billing_export.downloaded").last.payload).to eq("billing_export_id" => export.id, "user_id" => clerk.id)
    get "/billing/exports/#{SecureRandom.uuid}/file"
    expect(response).to have_http_status(:not_found)
  end

  # Revisão final, M3: o arquivo só sai se o conteúdo decifrado bate com o sha256 gravado.
  it "arquivo divergente do sha256: 409 integrity_mismatch, sem conteúdo, sem trilha de download e fora do log" do
    export = Billing::Close.call(period: period, by: clerk).payload[:export]
    tampered = "01#BPA#ADULTERADO-#{SecureRandom.hex(4)}\r\n"
    allow(BillingExport).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)&.tap { |loaded| allow(loaded).to receive(:file).and_return(tampered) }
    end
    sign_in_as(clerk)
    log = capture_log { get "/billing/exports/#{export.id}/file" }
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "integrity_mismatch")
    expect(response.body).not_to include("#BPA#")
    expect(response.headers["Content-Disposition"]).to be_nil
    expect(DomainEvent.where(name: "billing_export.downloaded")).to be_empty
    expect(log).not_to include("ADULTERADO", "#BPA#")
  end

  it "desligado: 403 em toda rota de competência" do
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(clerk)
    get "/billing/periods"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "procedure_billing")
  end
end
