# spec/requests/admin/api/analytics_demand_spec.rb
require "rails_helper"

# Contratos §1.1 (demanda): séries, totais do período, listas ordenadas por
# total (suprimido conta 0), recortes que valem só onde o contrato diz, e a
# lista de todas as unidades para o seletor.
RSpec.describe "GET /admin/api/analytics/demand", type: :request do
  let(:monday) { (Time.zone.today - 21).beginning_of_week }
  let(:range) { { from: monday.iso8601, to: (monday + 13).iso8601 } } # duas semanas
  let(:hidden) { { "suppressed" => true } }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let(:batel) { Neighborhood.create!(name: "Batel", source: "manual", active: false) }
  let(:unit) { create_unit("UBS Centro") }
  let(:upa) { create_unit("UPA Norte", kind: "upa", active: false) }

  def data = JSON.parse(response.body)["data"]

  def triage_fact!(metric, day, value, neighborhood: nil, protocol: "resp", version: 1, **attrs)
    fact!(metric: metric, day: day, value: value, neighborhood_id: neighborhood&.id, protocol_name: protocol,
          protocol_version: version, **attrs)
  end

  before do
    # O recorte protocol_name exige nome existente (Analytics::Params).
    ProtocolDefinition.create!(name: "resp", version: 1, status: "active", definition: analytics_definition(name: "resp"))
    ProtocolDefinition.create!(name: "arbo", version: 2, status: "active",
                               definition: analytics_definition(name: "arbo", version: 2))
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "analyst"))
  end

  it "séries de triagem, totais do período e listas por tier, protocolo e bairro" do
    triage_fact!("triage.started", monday, 8, neighborhood: centro)
    triage_fact!("triage.started", monday + 8, 3)
    triage_fact!("triage.completed", monday + 1, 6, neighborhood: centro, tier: "alta")
    triage_fact!("triage.completed", monday + 3, 7, tier: "alta")
    triage_fact!("triage.completed", monday + 9, 2, neighborhood: batel, protocol: "arbo", version: 2, tier: "baixa")
    triage_fact!("triage.aborted", monday + 2, 5, dim: "timeout")

    get "/admin/api/analytics/demand", params: range

    expect(data["periods"]).to eq([ monday.iso8601, (monday + 7).iso8601 ])
    expect(data["triages"]).to eq("started" => [ 8, hidden ], "completed" => [ 13, hidden ], "aborted" => [ 5, 0 ])
    # Total do grupo: cada total só olha as próprias partes; aborted todo visível.
    expect(data["triages_total"]).to eq("started" => hidden, "completed" => hidden, "aborted" => 5)
    expect(data["by_tier"]).to eq([
      { "tier" => "alta", "series" => [ 13, 0 ], "total" => 13 },
      { "tier" => "baixa", "series" => [ 0, hidden ], "total" => hidden }
    ])
    expect(data["by_protocol"]).to eq([
      { "protocol_name" => "resp", "series" => [ 13, 0 ], "total" => 13 },
      { "protocol_name" => "arbo", "series" => [ 0, hidden ], "total" => hidden }
    ])
    expect(data["by_neighborhood"]).to eq([
      { "neighborhood_id" => nil, "name" => "Sem bairro", "total" => 7 },
      { "neighborhood_id" => centro.id, "name" => "Centro", "total" => 6 },
      { "neighborhood_id" => batel.id, "name" => "Batel", "total" => hidden }
    ])
  end

  it "totais do período visíveis quando nenhuma parte é oculta" do
    triage_fact!("triage.started", monday, 8, neighborhood: centro)
    triage_fact!("triage.started", monday + 8, 9, neighborhood: centro)
    triage_fact!("triage.completed", monday + 1, 6, neighborhood: centro, tier: "alta")
    triage_fact!("triage.completed", monday + 9, 7, neighborhood: centro, tier: "alta")
    triage_fact!("triage.aborted", monday + 2, 5, neighborhood: centro, dim: "timeout")

    get "/admin/api/analytics/demand", params: range

    expect(data["triages"]).to eq("started" => [ 8, 9 ], "completed" => [ 6, 7 ], "aborted" => [ 5, 0 ])
    expect(data["triages_total"]).to eq("started" => 17, "completed" => 13, "aborted" => 5)
  end

  it "total do grupo: tier ou protocolo oculto esconde a célula de triages.completed; bairro oculto, os totais" do
    triage_fact!("triage.started", monday, 20, neighborhood: centro)
    triage_fact!("triage.completed", monday, 10, neighborhood: centro, tier: "alta")
    triage_fact!("triage.completed", monday, 3, neighborhood: centro, tier: "baixa")

    get "/admin/api/analytics/demand", params: range

    expect(data["triages"]["completed"]).to eq([ hidden, 0 ]) # 13 sairia por 13 − 10
    expect(data["by_tier"].map { |row| row["total"] }).to eq([ 10, hidden ])
    expect(data["triages_total"]).to eq("started" => 20, "completed" => hidden, "aborted" => 0)

    AnalyticsDailyFact.delete_all
    triage_fact!("triage.started", monday, 20, neighborhood: centro)
    triage_fact!("triage.completed", monday, 10, neighborhood: centro, tier: "alta")
    triage_fact!("triage.completed", monday, 3, neighborhood: batel, tier: "alta")

    get "/admin/api/analytics/demand", params: range

    expect(data["triages"]).to eq("started" => [ 20, 0 ], "completed" => [ 13, 0 ], "aborted" => [ 0, 0 ])
    expect(data["by_neighborhood"].map { |row| row["total"] }).to eq([ 10, hidden ])
    expect(data["triages_total"]).to eq("started" => 20, "completed" => hidden, "aborted" => 0)
  end

  it "total do grupo: cada total de triagem só é escondido por células das próprias partes" do
    triage_fact!("triage.started", monday, 20, neighborhood: centro)
    triage_fact!("triage.completed", monday, 10, neighborhood: centro, tier: "alta")
    triage_fact!("triage.completed", monday, 3, neighborhood: batel, tier: "alta")
    triage_fact!("triage.aborted", monday, 20, dim: "timeout")
    triage_fact!("triage.aborted", monday + 8, 2, dim: "timeout")

    get "/admin/api/analytics/demand", params: range

    expect(data["triages"]["started"]).to eq([ 20, 0 ])
    expect(data["triages"]["aborted"]).to eq([ 20, hidden ])
    expect(data["triages_total"]).to eq("started" => 20, "completed" => hidden, "aborted" => hidden)
  end

  it "chegadas por unidade, pedidos por tipo e motivo (todos, mesmo zerados) e a lista de todas as unidades" do
    fact!(metric: "attendance.checked_in", day: monday, value: 9, health_unit_id: unit.id, dim: "code")
    fact!(metric: "attendance.checked_in", day: monday + 7, value: 2, health_unit_id: upa.id, dim: "cpf_exception")
    fact!(metric: "request.opened", day: monday, value: 5, health_unit_id: unit.id, dim: "return")
    fact!(metric: "request.closed", day: monday + 8, value: 6, health_unit_id: unit.id, dim: "fulfilled")

    get "/admin/api/analytics/demand", params: range

    expect(data["attendances_by_unit"]).to eq([
      { "health_unit_id" => unit.id, "name" => "UBS Centro", "series" => [ 9, 0 ], "total" => 9 },
      { "health_unit_id" => upa.id, "name" => "UPA Norte", "series" => [ 0, hidden ], "total" => hidden }
    ])
    expect(data["requests_opened"]).to eq([
      { "kind" => "return", "series" => [ 5, 0 ], "total" => 5 },
      { "kind" => "referral", "series" => [ 0, 0 ], "total" => 0 }
    ])
    expect(data["requests_closed"]).to eq([
      { "reason" => "fulfilled", "series" => [ 0, 6 ], "total" => 6 },
      { "reason" => "citizen_cancelled", "series" => [ 0, 0 ], "total" => 0 },
      { "reason" => "dismissed", "series" => [ 0, 0 ], "total" => 0 }
    ])
    expect(data["units"]).to eq([
      { "health_unit_id" => unit.id, "name" => "UBS Centro", "active" => true },
      { "health_unit_id" => upa.id, "name" => "UPA Norte", "active" => false }
    ])
  end

  it "bairro e protocolo recortam só as triagens; unidade só chegadas e pedidos; units não muda" do
    triage_fact!("triage.started", monday, 8, neighborhood: centro)
    triage_fact!("triage.started", monday, 6)
    triage_fact!("triage.started", monday, 9, neighborhood: centro, protocol: "arbo")
    fact!(metric: "attendance.checked_in", day: monday, value: 9, health_unit_id: unit.id, dim: "code")
    fact!(metric: "attendance.checked_in", day: monday, value: 7, health_unit_id: upa.id, dim: "code")

    get "/admin/api/analytics/demand", params: range.merge(neighborhood_id: centro.id, protocol_name: "resp",
                                                           health_unit_id: unit.id)
    expect(data["filter"]).to eq("neighborhood_id" => centro.id, "health_unit_id" => unit.id,
                                 "protocol_name" => "resp", "protocol_version" => nil)
    expect(data["triages"]["started"]).to eq([ 8, 0 ])
    expect(data["attendances_by_unit"].map { |r| r["health_unit_id"] }).to eq([ unit.id ])
    expect(data["units"].size).to eq(2)

    get "/admin/api/analytics/demand", params: range.merge(neighborhood_id: "none")
    expect(data["triages"]["started"]).to eq([ 6, 0 ])
    expect(data["attendances_by_unit"].map { |r| r["health_unit_id"] }).to contain_exactly(unit.id, upa.id)
  end

  it "pedidos abertos e encerrados: célula oculta esconde o total da linha" do
    fact!(metric: "request.opened", day: monday, value: 10, health_unit_id: unit.id, dim: "referral")
    fact!(metric: "request.opened", day: monday + 7, value: 2, health_unit_id: unit.id, dim: "referral")
    fact!(metric: "request.closed", day: monday + 1, value: 3, health_unit_id: unit.id, dim: "dismissed")
    fact!(metric: "request.closed", day: monday + 8, value: 20, health_unit_id: unit.id, dim: "dismissed")

    get "/admin/api/analytics/demand", params: range

    expect(data["requests_opened"]).to include({ "kind" => "referral", "series" => [ 10, hidden ], "total" => hidden })
    expect(data["requests_closed"]).to include({ "reason" => "dismissed", "series" => [ hidden, 20 ], "total" => hidden })
  end

  it "granularidade mensal: célula oculta no mês esconde o total do grupo" do
    first = (Time.zone.today << 3).beginning_of_month
    fact!(metric: "attendance.checked_in", day: first + 2, value: 10, health_unit_id: unit.id, dim: "code")
    fact!(metric: "attendance.checked_in", day: first.next_month + 2, value: 2, health_unit_id: unit.id, dim: "code")

    get "/admin/api/analytics/demand", params: { from: first.iso8601, to: first.next_month.end_of_month.iso8601,
                                                 granularity: "month" }

    expect(data["periods"]).to eq([ first.iso8601, first.next_month.iso8601 ])
    expect(data["attendances_by_unit"]).to eq([
      { "health_unit_id" => unit.id, "name" => "UBS Centro", "series" => [ 10, hidden ], "total" => hidden }
    ])
  end

  # Contratos §1: demanda recorta por protocolo, não por versão.
  it "protocol_version na demanda é ignorado e volta nulo no filter" do
    triage_fact!("triage.started", monday, 8, version: 1)
    triage_fact!("triage.started", monday, 9, version: 7)

    get "/admin/api/analytics/demand", params: range.merge(protocol_name: "resp", protocol_version: "1")
    expect(data["filter"]).to include("protocol_name" => "resp", "protocol_version" => nil)
    expect(data["triages"]["started"]).to eq([ 17, 0 ])

    get "/admin/api/analytics/demand", params: range.merge(protocol_version: "lixo")
    expect(response).to have_http_status(:ok)
    expect(data["filter"]["protocol_version"]).to be_nil
  end
end
