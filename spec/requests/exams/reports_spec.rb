require "rails_helper"
require "csv"

# Spec §6 "Relatório de conferência" (F-21.12): por prestador e mês —
# autorizadas, coletadas, com resultado no prazo e em atraso, pendentes. O
# CSV detalhado leva só short_code, SIGTAP e datas.
RSpec.describe "Exames — relatório de conferência", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  # let!: o item precisa exigir autorização ANTES de o pedido abrir; senão o
  # passo `authorized` falha em silêncio e o relatório sai vazio.
  let!(:unit) { create_unit("UBS Relatório") }
  let!(:doctor) { doctor!(unit) }
  let!(:item) { exam_catalog_item!(requires_authorization: true, result_days: 5) }
  let!(:provider) do
    exam_provider!(name: "Lab Mês").tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) }
  end
  let(:anchor) { Date.current.prev_month.beginning_of_month }
  let(:month) { anchor.strftime("%Y-%m") }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }

  def transit(order, kind, **opts)
    result = Exams::Transition.call(order: order, kind: kind, actor_user: doctor, **opts)
    raise "transição #{kind} recusada: #{result.reason}" if result.failure?
  end

  def flow(day:, result_after:)
    at = zone.local(anchor.year, anchor.month, day, 9)
    order = travel_to(at) do
      opened = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
      expect(opened.status).to eq("awaiting_authorization")
      transit(opened, "authorized", changes: { exam_provider_id: provider.id })
      transit(opened, "scheduled", changes: { scheduled_at: at + 1.day, scheduled_place: "L" })
      transit(opened, "collected")
      opened
    end
    travel_to(at + result_after) { transit(order, "resulted", event_payload: { source: "unit", critical: false }) }
    order
  end

  it "conta por prestador no mês, com prazo pelo evento; CSV sem dado de paciente" do
    on_time = flow(day: 2, result_after: 3.days)
    late = flow(day: 3, result_after: 9.days)
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    get "/exams/admin/report", params: { month: month }
    expect(json_body["rows"]).to eq([ { "provider" => { "id" => provider.id, "name" => "Lab Mês" }, "authorized" => 2, "collected" => 2,
                                        "resulted_on_time" => 1, "resulted_late" => 1, "pending" => 0 } ])
    get "/exams/admin/report.csv", params: { month: month, detail: "true", provider_id: provider.id }
    expect(response.media_type).to eq("text/csv")
    csv = CSV.parse(response.body, headers: true)
    expect(csv.headers).to eq(%w[short_code sigtap_code authorized_on scheduled_on collected_on resulted_on on_time])
    expect(csv.map { |r| [ r["short_code"], r["on_time"] ] }).to contain_exactly([ on_time.short_code, "true" ], [ late.short_code, "false" ])
    expect(response.body).not_to include(on_time.patient.cpf, on_time.patient.display_name.to_s)
    get "/exams/admin/report", params: { month: "2026-13" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_month" ])
    sign_in_as(doctor)
    get "/exams/admin/report", params: { month: month }
    expect(response).to have_http_status(:forbidden)
  end

  it "serve o resumo em CSV (não JSON) e neutraliza fórmulas em células de texto" do
    flow(day: 2, result_after: 1.day)
    provider.update!(name: "=HYPERLINK(\"http://x\")")
    sign_in_as(staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    get "/exams/admin/report.csv", params: { month: month }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    csv = CSV.parse(response.body, headers: true)
    expect(csv.headers).to eq(%w[provider authorized collected resulted_on_time resulted_late pending])
    expect(csv.first["provider"]).to eq("'=HYPERLINK(\"http://x\")")
  end
end
