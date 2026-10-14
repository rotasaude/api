require "rails_helper"
require "csv"

# Spec §6 "Relatório de conferência" (F-21.12): por prestador e mês —
# autorizadas, coletadas, com resultado no prazo e em atraso, pendentes. O
# CSV detalhado leva só short_code, SIGTAP e datas.
RSpec.describe "Exames — relatório de conferência", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:city_zone) { "America/Sao_Paulo" }
  # A cidade nasce com o fuso do exemplo (o fuso é imutável depois: trigger).
  def use_test_city_host!(**) = super(time_zone: city_zone)

  before { exam_city! }
  # O arranjo roda no fuso da cidade; a requisição acha o dele (CityConnection.with).
  around { |example| Time.use_zone(city_zone) { example.run } }

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
  let(:zone) { ActiveSupport::TimeZone[city_zone] }

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

  def regulator! = sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))

  def open_and_authorize(at)
    travel_to(at) do
      order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
      transit(order, "authorized", changes: { exam_provider_id: provider.id })
      order
    end
  end

  context "cidade em outro fuso (America/Manaus, UTC-4)" do
    let(:city_zone) { "America/Manaus" }

    it "põe cada evento no mês do relógio da cidade, no resumo e no detalhe" do
      last_day = anchor.end_of_month.to_date
      first_next = last_day + 1
      # 23h30 de Manaus do último dia já é dia 1 em UTC e em São Paulo (e 00h30 de
      # Manaus do dia 1 é 04h30 UTC): só o fuso da cidade separa os dois meses.
      late = open_and_authorize(zone.local(last_day.year, last_day.month, last_day.day, 23, 30))
      early = open_and_authorize(zone.local(first_next.year, first_next.month, first_next.day, 0, 30))
      regulator!
      get "/exams/admin/report", params: { month: month }
      expect(json_body["rows"].map { |r| r["authorized"] }).to eq([ 1 ])
      get "/exams/admin/report.csv", params: { month: month, detail: "true" }
      rows = CSV.parse(response.body, headers: true)
      expect(rows.map { |r| [ r["short_code"], r["authorized_on"] ] }).to eq([ [ late.short_code, last_day.iso8601 ] ])
      get "/exams/admin/report", params: { month: first_next.strftime("%Y-%m") }
      expect(json_body["rows"].map { |r| r["authorized"] }).to eq([ 1 ])
      get "/exams/admin/report.csv", params: { month: first_next.strftime("%Y-%m"), detail: "true" }
      rows = CSV.parse(response.body, headers: true)
      expect(rows.map { |r| [ r["short_code"], r["authorized_on"] ] }).to eq([ [ early.short_code, first_next.iso8601 ] ])
    end
  end

  it "conta pedidos distintos: reagendar duas vezes e evento repetido contam uma vez; resumo e detalhe concordam" do
    at = zone.local(anchor.year, anchor.month, 4, 9)
    order = open_and_authorize(at)
    travel_to(at) do
      transit(order, "scheduled", changes: { scheduled_at: at + 1.day, scheduled_place: "L" })
      transit(order, "scheduled", changes: { scheduled_at: at + 2.days, scheduled_place: "L" })
      transit(order, "scheduled", changes: { scheduled_at: at + 3.days, scheduled_place: "L" })
      transit(order, "collected")
      ExamOrderEvent.create!(exam_order: order, kind: "collected", actor_user: doctor, occurred_at: at + 1.hour)
    end
    regulator!
    get "/exams/admin/report", params: { month: month }
    row = json_body["rows"].first
    expect([ row["authorized"], row["collected"] ]).to eq([ 1, 1 ])
    get "/exams/admin/report.csv", params: { month: month, detail: "true" }
    expect(CSV.parse(response.body, headers: true).length).to eq(1)
  end

  it "pending é o retrato de agora (não do mês) e respeita o filtro de prestador; detalhe ordenado por short_code" do
    other = exam_provider!(name: "Outro Lab")
    mine = open_and_authorize(zone.local(anchor.year, anchor.month, 5, 9))
    travel_to(zone.local(anchor.year, anchor.month, 5, 10)) do
      transit(mine, "scheduled", changes: { scheduled_at: Time.current + 1.day, scheduled_place: "L" })
    end
    stranger = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    transit(stranger, "authorized", changes: { exam_provider_id: other.id })
    transit(stranger, "scheduled", changes: { scheduled_at: Time.current + 1.day, scheduled_place: "L" })
    regulator!
    get "/exams/admin/report", params: { month: month, provider_id: provider.id }
    expect(json_body["rows"].map { |r| [ r["provider"]["name"], r["pending"] ] }).to eq([ [ "Lab Mês", 1 ] ])
    get "/exams/admin/report", params: { month: month }
    expect(json_body["rows"].map { |r| [ r["provider"]["name"], r["pending"] ] }).to eq([ [ "Lab Mês", 1 ], [ "Outro Lab", 1 ] ])
    shorts = Array.new(3) { |i| open_and_authorize(zone.local(anchor.year, anchor.month, 6 + i, 9)).short_code }
    get "/exams/admin/report.csv", params: { month: month, detail: "true" }
    codes = CSV.parse(response.body, headers: true).map { |r| r["short_code"] }
    expect(codes).to eq(codes.sort)
    expect(codes).to include(*shorts)
  end

  it "provider_id malformado: 422 invalid_filter" do
    regulator!
    get "/exams/admin/report", params: { month: month, provider_id: "nao-e-uuid" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_filter" ])
    get "/exams/admin/report.csv", params: { month: month, provider_id: "nao-e-uuid" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rotas CSV: quem não é regulador recebe 403 missing_role" do
    sign_in_as(doctor)
    get "/exams/admin/report.csv", params: { month: month }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    get "/exams/admin/report.csv", params: { month: month, detail: "true" }
    expect(response).to have_http_status(:forbidden)
  end

  it "exam_tracking desligado: 403 feature_disabled no JSON e no CSV (Exams::BaseController#require_exam_tracking!)" do
    regulator!
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    [ "/exams/admin/report", "/exams/admin/report.csv" ].each do |path|
      get path, params: { month: month }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "exam_tracking" } ])
    end
  end
end
