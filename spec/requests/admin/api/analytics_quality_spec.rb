require "rails_helper"

# Contratos §1.2 (qualidade): faixas fixas, taxas somadas no período e só
# então suprimidas, por unidade, e a lista de todas as unidades.
RSpec.describe "GET /admin/api/analytics/quality", type: :request do
  let(:monday) { (Time.zone.today - 21).beginning_of_week }
  let(:range) { { from: monday.iso8601, to: (monday + 13).iso8601 } }
  let(:hidden) { { "suppressed" => true } }
  let(:unit) { create_unit("UBS Centro") }
  let(:upa) { create_unit("UPA Norte", kind: "upa") }

  def data = JSON.parse(response.body)["data"]
  def unit_fact!(metric, day, value, dim, at: unit) = fact!(metric: metric, day: day, value: value, dim: dim, health_unit_id: at.id)

  before do
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "analyst"))
  end

  it "espera: sempre as cinco faixas, e a taxa de até 30 min por período e no total" do
    unit_fact!("attendance.wait", monday, 10, "0-15")
    unit_fact!("attendance.wait", monday, 10, "30-60")
    unit_fact!("attendance.wait", monday + 7, 3, "15-30")
    unit_fact!("attendance.wait", monday + 7, 20, "120+")

    get "/admin/api/analytics/quality", params: range

    expect(data["wait"]["buckets"]).to eq([
      { "bucket" => "0-15", "series" => [ 10, 0 ], "total" => 10 },
      { "bucket" => "15-30", "series" => [ 0, hidden ], "total" => hidden },
      { "bucket" => "30-60", "series" => [ 10, 0 ], "total" => 10 },
      { "bucket" => "60-120", "series" => [ 0, 0 ], "total" => 0 },
      { "bucket" => "120+", "series" => [ 0, 20 ], "total" => 20 }
    ])
    expect(data["wait"]["within_30_pct"]).to eq([ 50.0, hidden ]) # 2ª semana: numerador 3
    expect(data["wait"]["within_30_pct_total"]).to eq(hidden)     # 13 ÷ 43, mas a faixa 15-30 é oculta
  end

  it "faltas: no_show ÷ (checked_in + no_show); saiu sem atendimento: left ÷ desfechos" do
    unit_fact!("appointment.ended", monday, 30, "checked_in")
    unit_fact!("appointment.ended", monday, 10, "no_show")
    unit_fact!("appointment.ended", monday, 7, "expired")
    unit_fact!("appointment.ended", monday + 7, 2, "no_show")
    unit_fact!("attendance.closed", monday, 40, "discharged")
    unit_fact!("attendance.closed", monday, 10, "left")
    unit_fact!("attendance.closed", monday + 7, 5, "referred")

    get "/admin/api/analytics/quality", params: range

    expect(data["appointments"]).to eq([
      { "status" => "checked_in", "series" => [ 30, 0 ], "total" => 30 },
      { "status" => "no_show", "series" => [ 10, hidden ], "total" => hidden },
      { "status" => "expired", "series" => [ 7, 0 ], "total" => 7 },
      { "status" => "cancelled_by_citizen", "series" => [ 0, 0 ], "total" => 0 }
    ])
    expect(data["no_show_pct"]).to eq([ 25.0, hidden ])
    expect(data["no_show_pct_total"]).to eq(hidden) # 12 ÷ 42, mas no_show da 2ª semana é oculto
    expect(data["attendance_outcomes"].map { |r| r["outcome"] }).to eq(%w[discharged referred return left])
    expect(data["left_pct"]).to eq([ 20.0, 0.0 ])
    expect(data["left_pct_total"]).to eq(18.2) # 10 ÷ 55
  end

  it "total do grupo: a taxa do período e do total com todas as partes visíveis" do
    unit_fact!("attendance.wait", monday, 10, "0-15")
    unit_fact!("attendance.wait", monday + 7, 5, "15-30")
    unit_fact!("attendance.wait", monday + 7, 25, "120+")

    get "/admin/api/analytics/quality", params: range

    expect(data["wait"]["within_30_pct"]).to eq([ 100.0, 16.7 ])
    expect(data["wait"]["within_30_pct_total"]).to eq(37.5) # 15 ÷ 40
  end

  it "total do grupo por unidade: taxa oculta quando uma faixa ou desfecho que a compõe é oculto" do
    unit_fact!("attendance.wait", monday, 20, "0-15")
    unit_fact!("attendance.wait", monday, 3, "30-60")
    unit_fact!("attendance.wait", monday, 10, "120+")
    unit_fact!("attendance.closed", monday, 40, "discharged")
    unit_fact!("attendance.closed", monday, 10, "left")
    unit_fact!("attendance.closed", monday, 2, "referred")
    unit_fact!("appointment.ended", monday, 30, "checked_in")
    unit_fact!("appointment.ended", monday, 10, "no_show")
    unit_fact!("appointment.ended", monday, 2, "expired") # fora da taxa de faltas

    get "/admin/api/analytics/quality", params: range

    # attendances (52) é o total dos desfechos da unidade, e referred (2) é
    # oculto: com o recorte da unidade, 52 − 40 − 10 devolveria o 2.
    expect(data["by_unit"]).to eq([
      { "health_unit_id" => unit.id, "name" => "UBS Centro", "attendances" => hidden,
        "wait_within_30_pct" => hidden, "no_show_pct" => 25.0, "left_pct" => hidden }
    ])
    expect(data["left_pct"]).to eq([ hidden, nil ])

    get "/admin/api/analytics/quality", params: range.merge(health_unit_id: unit.id)
    expect(data["attendance_outcomes"].map { |row| row["total"] }).to eq([ 40, hidden, 0, 10 ])
    expect(data["by_unit"].first["attendances"]).to eq(hidden)
  end

  it "sem denominador a taxa é nula" do
    get "/admin/api/analytics/quality", params: range

    expect(data["wait"]).to include("within_30_pct" => [ nil, nil ], "within_30_pct_total" => nil)
    expect(data).to include("no_show_pct_total" => nil, "left_pct_total" => nil)
  end

  it "por unidade: atendimentos encerrados e as três taxas; recorte de unidade; units com todas" do
    unit_fact!("attendance.closed", monday, 40, "discharged")
    unit_fact!("attendance.closed", monday, 10, "left")
    unit_fact!("attendance.wait", monday, 30, "0-15")
    unit_fact!("attendance.wait", monday, 20, "60-120")
    unit_fact!("attendance.closed", monday, 3, "discharged", at: upa)

    get "/admin/api/analytics/quality", params: range

    expect(data["by_unit"]).to eq([
      { "health_unit_id" => unit.id, "name" => "UBS Centro", "attendances" => 50,
        "wait_within_30_pct" => 60.0, "no_show_pct" => nil, "left_pct" => 20.0 },
      { "health_unit_id" => upa.id, "name" => "UPA Norte", "attendances" => hidden,
        "wait_within_30_pct" => nil, "no_show_pct" => nil, "left_pct" => hidden }
    ])

    get "/admin/api/analytics/quality", params: range.merge(health_unit_id: upa.id)
    expect(data["by_unit"].map { |r| r["health_unit_id"] }).to eq([ upa.id ])
    expect(data["attendance_outcomes"].first).to eq("outcome" => "discharged", "series" => [ hidden, 0 ], "total" => hidden)
    expect(data["units"].map { |u| u["health_unit_id"] }).to eq([ unit.id, upa.id ])
  end
end
