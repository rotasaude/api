# Módulo 14, critério de fechamento (ADR 0025 "Invariantes"; spec 2026-09-30
# §10.2). Cada bloco tem a mutação que precisa deixá-lo vermelho (registrada
# no relatório da entrega).
require "rails_helper"

RSpec.describe "Invariantes do Analytics (ADR 0025)", type: :request do
  let!(:city_record) { register_test_city! }
  let(:today) { Time.zone.today }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let(:unit) { create_unit("UBS Invariante") }
  let(:operator_password) { "s3nha-forte-1" }

  before { create_default_protocol! }

  def json = JSON.parse(response.body)

  def snapshot
    AnalyticsDailyFact.order(:day, :metric, :dim, :tier, :neighborhood_id, :health_unit_id, :question_id)
                      .pluck(:day, :metric, :health_unit_id, :neighborhood_id, :protocol_name, :protocol_version,
                             :tier, :question_id, :dim, :value)
  end

  # Inteiros do JSON que são contagem: protocol_version e o eco do filtro não são.
  def counts_in(node, &block)
    case node
    when Hash then node.each { |key, value| counts_in(value, &block) unless %w[protocol_version filter].include?(key) }
    when Array then node.each { |value| counts_in(value, &block) }
    when Integer then yield node
    end
  end

  # Caminhos das células { suppressed: true } — prova que a varredura passou
  # pelas células pequenas (e não só achou [] por falta delas).
  LABELS = %w[name kind reason bucket status outcome tier value question_id protocol_name].freeze

  def hidden_paths(node, path = "", acc = [])
    case node
    when Hash
      return acc << path if node == { "suppressed" => true }

      node.each { |key, value| hidden_paths(value, "#{path}.#{key}", acc) }
    when Array
      node.each_with_index do |value, i|
        label = value.is_a?(Hash) && LABELS.map { |key| value[key] }.compact.first
        hidden_paths(value, "#{path}[#{label || i}]", acc)
      end
    end
    acc
  end

  def operator!
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: operator_password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  # Mutação: acrescentar `t.uuid :citizen_id` ao create_table de analytics_daily_facts
  # (migração e dump) e recarregar os bancos de teste.
  it "analytics_daily_facts, analytics_runs e city_analytics_indicators não têm coluna de pessoa" do
    expect(AnalyticsDailyFact.column_names).to match_array(%w[id day metric health_unit_id neighborhood_id protocol_name
                                                              protocol_version tier question_id dim value consolidated_at])
    expect(AnalyticsRun.column_names).to match_array(%w[id window_from window_to kind status started_at finished_at
                                                        published_at error])
    expect(CityAnalyticsIndicator.column_names).to match_array(%w[id city_id week_start indicator value suppressed
                                                                  published_at])
  end

  # Mutação: em Analytics::Suppression.cell, devolver `count.to_i` sem o wrap; ou, em
  # Analytics::Publish#indicators, trocar `Suppression.cell(total(week, "triage.started"))`
  # por `total(week, "triage.started")`.
  it "nenhuma resposta do Analytics e nenhuma linha publicada traz contagem de 1 a 4" do
    monday = (today - 21).beginning_of_week
    ProtocolDefinition.create!(name: "arbo", version: 1, status: "active", definition: analytics_definition(name: "arbo"))
    (0..13).each do |offset|
      day = monday + offset
      small = (offset % 4) + 1
      triage = { protocol_name: "arbo", protocol_version: 1 }
      fact!(metric: "triage.started", day: day, value: small, neighborhood_id: offset.even? ? centro.id : nil, **triage)
      fact!(metric: "triage.completed", day: day, value: small, neighborhood_id: centro.id, tier: "alta", **triage)
      fact!(metric: "triage.aborted", day: day, value: small, dim: "timeout", **triage)
      fact!(metric: "calibration.outcome", day: day, value: small, tier: "alta", dim: "none", **triage)
      fact!(metric: "epi.answer", day: day, value: small, neighborhood_id: centro.id, question_id: "febre", dim: "true", **triage)
      %w[attendance.closed attendance.wait appointment.ended request.opened attendance.checked_in].zip(%w[left 0-15 no_show return code])
        .each { |metric, dim| fact!(metric: metric, day: day, value: small, health_unit_id: unit.id, dim: dim) }
    end
    fact!(metric: "triage.started", day: monday - 7, value: 2, protocol_name: "arbo", protocol_version: 1)
    # Varredura forte (verificação de 2026-09-30): por frente, uma linha ou
    # célula de cada lista cuja SOMA no período e no recorte fica em 1..4 —
    # fatos de um dia só, em chaves que a grade acima não usa.
    # Mutação: em Analytics::QualityQuery#by_unit, `attendances: at.call(outcomes, OUTCOMES)` sem o
    # Suppression.cell; ou, em DemandQuery#fixed_rows / #unit_rows, trocar `**row(...)` por
    # `series: ..., total: by_period.values.sum`; ou, em CalibrationQuery#tier_row, `outcomes` sem cell.
    vila = Neighborhood.create!(name: "Vila Pequena", source: "manual")
    tiny = create_unit("UBS Pequena")
    day = monday + 3
    arbo = { protocol_name: "arbo", protocol_version: 1 }
    fact!(metric: "triage.completed", day: day, value: 2, neighborhood_id: vila.id, tier: "media", **arbo)
    fact!(metric: "triage.completed", day: day, value: 3, neighborhood_id: centro.id, tier: "alta",
          protocol_name: "resp", protocol_version: 1)
    fact!(metric: "calibration.outcome", day: day, value: 2, tier: "baixa", dim: "referred", **arbo)
    fact!(metric: "epi.answer", day: day, value: 3, neighborhood_id: centro.id, question_id: "sintoma", dim: "Manchas", **arbo)
    [ %w[attendance.closed referred], %w[attendance.closed return], %w[attendance.wait 30-60], %w[attendance.wait 120+],
      %w[appointment.ended expired], %w[appointment.ended checked_in], %w[request.opened referral],
      %w[request.closed fulfilled], %w[request.closed dismissed], %w[attendance.checked_in code] ]
      .each_with_index { |(metric, dim), i| fact!(metric: metric, day: day, value: (i % 4) + 1, health_unit_id: tiny.id, dim: dim) }
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "analyst"))

    found = []
    hidden = []
    base = { from: (monday - 7).iso8601, to: (monday + 13).iso8601 }
    filters = [ {}, { neighborhood_id: centro.id }, { neighborhood_id: "none" }, { neighborhood_id: vila.id },
                { health_unit_id: unit.id }, { health_unit_id: tiny.id }, { protocol_name: "arbo", protocol_version: "1" } ]
    [ {}, { granularity: "month" } ].product(filters).each do |granularity, filter|
      %w[demand quality calibration epidemiology].each do |front|
        get "/admin/api/analytics/#{front}", params: base.merge(granularity).merge(filter)
        expect(response).to have_http_status(:ok), "#{front} #{granularity} #{filter}: #{response.body}"
        counts_in(json["data"]) { |n| found << [ front, granularity, filter, n ] if (1..4).cover?(n) }
        hidden.concat(hidden_paths(json["data"]).map { |path| "#{front}#{path}" }) if granularity.empty? && filter.empty?
      end
    end
    expect(found).to be_empty
    expect(hidden).to include(
      "demand.by_tier[media].total", "demand.by_protocol[resp].total", "demand.by_neighborhood[Vila Pequena].total",
      "demand.attendances_by_unit[UBS Pequena].total", "demand.requests_opened[referral].total",
      "demand.requests_closed[fulfilled].total", "demand.requests_closed[dismissed].total",
      "quality.wait.buckets[30-60].total", "quality.wait.buckets[120+].total", "quality.appointments[expired].total",
      "quality.attendance_outcomes[referred].total", "quality.attendance_outcomes[return].total",
      "quality.by_unit[UBS Pequena].attendances", "calibration.versions[arbo].rows[baixa].outcomes.referred",
      "epidemiology.questions[sintoma].options[Manchas].total"
    )

    Analytics::Publish.call(from: monday - 7, to: monday + 13)
    rows = CityAnalyticsIndicator.where(city_id: city_record.id)
    expect(rows.where(indicator: CityAnalyticsIndicator::COUNT_INDICATORS, value: 1..4)).to be_empty
    expect(rows.where(suppressed: true).where.not(value: nil)).to be_empty
    expect(rows.find_by!(week_start: monday - 7, indicator: "triages_started")).to have_attributes(suppressed: true, value: nil)
  end

  # Total do grupo (contratos §0, decisão de 2026-09-30).
  # Mutação: em Analytics::Suppression.group, devolver sempre `cell(total)`; ou, em
  # BaseQuery#row, voltar `total: Suppression.cell(by_period.values.sum)`; ou, em
  # Analytics::Suppression.group_rate, devolver sempre `rate(numerator, denominator)`; ou,
  # em QualityQuery#by_unit, usar como partes só o total de cada linha da unidade.
  it "nenhum total ou taxa é exibido quando alguma parte que o compõe, na mesma resposta, está oculta" do
    monday = (today - 21).beginning_of_week
    ProtocolDefinition.create!(name: "arbo", version: 1, status: "active", definition: analytics_definition(name: "arbo"))
    other = create_unit("UPA Invariante", kind: "upa")
    # Grade com contagens grandes e pequenas misturadas: sem a regra, o total
    # (quase sempre >= 5) sairia visível ao lado da parte oculta.
    (0..13).each do |offset|
      day = monday + offset
      small = (offset % 4) + 1
      big = 10 + offset
      triage = { protocol_name: "arbo", protocol_version: 1 }
      fact!(metric: "triage.started", day: day, value: big, neighborhood_id: centro.id, **triage)
      fact!(metric: "triage.started", day: day, value: small, **triage) if offset.odd?
      fact!(metric: "triage.completed", day: day, value: big, neighborhood_id: centro.id, tier: "alta", **triage)
      fact!(metric: "triage.completed", day: day, value: small, tier: "baixa", **triage) if offset % 3 == 0
      fact!(metric: "triage.aborted", day: day, value: big, dim: "timeout", **triage)
      fact!(metric: "calibration.outcome", day: day, value: big, tier: "alta", dim: "discharged", **triage)
      fact!(metric: "calibration.outcome", day: day, value: small, tier: "alta", dim: "left", **triage) if offset == 5
      fact!(metric: "calibration.outcome", day: day, value: big, tier: "baixa", dim: "none", **triage)
      fact!(metric: "epi.answer", day: day, value: big, question_id: "febre", dim: "true", **triage)
      fact!(metric: "epi.answer", day: day, value: small, question_id: "febre", dim: "false", **triage) if offset == 9
      [ unit, other ].each do |at|
        %w[attendance.closed attendance.wait appointment.ended attendance.checked_in request.opened]
          .zip(%w[discharged 0-15 checked_in code return])
          .each { |metric, dim| fact!(metric: metric, day: day, value: big, health_unit_id: at.id, dim: dim) }
      end
      %w[attendance.closed attendance.wait appointment.ended attendance.checked_in request.opened]
        .zip(%w[left 120+ no_show cpf_exception referral])
        .each { |metric, dim| fact!(metric: metric, day: day, value: small, health_unit_id: unit.id, dim: dim) if offset == 8 }
      # Mesmas linhas com 9 na 1ª semana: a célula da 2ª (1) segue oculta, mas o
      # total da linha na unidade (10) passa de 4 — by_unit precisa olhar as células.
      %w[attendance.closed attendance.wait appointment.ended].zip(%w[left 120+ no_show])
        .each { |metric, dim| fact!(metric: metric, day: day, value: 9, health_unit_id: unit.id, dim: dim) if offset == 1 }
    end
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "analyst"))

    hidden = { "suppressed" => true }
    hidden_in = ->(values) { values.any? { |value| value == hidden } }
    violations = []
    exercised = Hash.new(0)
    check = lambda do |label, parts, *shown|
      next unless hidden_in.call(parts)

      exercised[label.split(":").first] += 1
      shown.each { |value| violations << label unless value == hidden || value.nil? }
    end
    rows_with_series = lambda do |node, &block|
      case node
      when Hash
        block.call(node) if node.key?("series") && node.key?("total")
        node.each_value { |value| rows_with_series.call(value, &block) }
      when Array then node.each { |value| rows_with_series.call(value, &block) }
      end
    end
    column = ->(rows, index) { rows.map { |row| row["series"][index] } }

    base = { from: monday.iso8601, to: (monday + 13).iso8601 }
    filters = [ {}, { neighborhood_id: centro.id }, { health_unit_id: unit.id }, { protocol_name: "arbo" } ]
    [ {}, { granularity: "month" } ].product(filters).each do |granularity, filter|
      %w[demand quality calibration epidemiology].each do |front|
        get "/admin/api/analytics/#{front}", params: base.merge(granularity).merge(filter)
        expect(response).to have_http_status(:ok), "#{front} #{granularity} #{filter}: #{response.body}"
        data = json["data"]
        where = "#{front} #{granularity} #{filter}"
        rows_with_series.call(data) { |row| check.call("row: #{where} #{row.except('series', 'total')}", row["series"], row["total"]) }

        case front
        when "demand"
          parts = data["by_tier"] + data["by_protocol"]
          data["periods"].each_index do |i|
            check.call("triages.completed[p]: #{where} #{i}", column.call(parts, i), data["triages"]["completed"][i])
          end
          breakdown = (data["by_tier"] + data["by_protocol"] + data["by_neighborhood"]).map { |row| row["total"] }
          triages_total = data["triages_total"]
          check.call("triages_total: #{where}", data["triages"]["started"], triages_total["started"])
          check.call("triages_total: #{where}", data["triages"]["aborted"], triages_total["aborted"])
          check.call("triages_total: #{where}", data["triages"]["completed"] + breakdown, triages_total["completed"])
        when "quality"
          rates = [ [ data["wait"]["buckets"], data["wait"]["within_30_pct"], data["wait"]["within_30_pct_total"] ],
                    [ data["appointments"].select { |row| %w[checked_in no_show].include?(row["status"]) },
                      data["no_show_pct"], data["no_show_pct_total"] ],
                    [ data["attendance_outcomes"], data["left_pct"], data["left_pct_total"] ] ]
          rates.each do |rows, series, total|
            data["periods"].each_index { |i| check.call("rate[p]: #{where} #{i}", column.call(rows, i), series[i]) }
            check.call("rate_total: #{where}", rows.flat_map { |row| row["series"] + [ row["total"] ] }, total)
          end
          # by_unit: com o recorte da unidade, as linhas de faixa, estado e
          # desfecho da resposta SÃO as partes da taxa daquela unidade.
          if filter[:health_unit_id]
            row = data["by_unit"].find { |entry| entry["health_unit_id"] == filter[:health_unit_id] }
            totals = ->(rows) { rows.map { |entry| entry["total"] } }
            check.call("by_unit_rate: #{where} wait", totals.call(data["wait"]["buckets"]), row["wait_within_30_pct"])
            check.call("by_unit_rate: #{where} no_show", totals.call(rates[1][0]), row["no_show_pct"])
            check.call("by_unit_rate: #{where} left", totals.call(data["attendance_outcomes"]), row["left_pct"])
            check.call("by_unit_attendances: #{where}", totals.call(data["attendance_outcomes"]), row["attendances"])
          end
        when "calibration"
          data["versions"].flat_map { |version| version["rows"] }.each do |row|
            check.call("calibration: #{where} #{row['tier']}", row["outcomes"].values, row["total"], *row["shares"].values)
          end
        end
      end
    end

    expect(violations).to be_empty
    expect(exercised.keys).to include("row", "triages.completed[p]", "triages_total", "rate[p]", "rate_total", "calibration",
                                      "by_unit_rate")
  end

  # Mutação: em Analytics::Consolidate::Epidemiology, tirar
  # `AND s.step -> 'analytic' = 'true'::jsonb`; ou trocar a condição de answer_type por `TRUE`.
  it "nenhum fato epidemiológico vem de pergunta sem analytic, nem de integer ou text" do
    definition = analytics_definition(marks: %w[febre sintoma idade])
    definition["steps"] << { "id" => "obs", "prompt" => "Algo mais?", "answer_type" => "text", "analytic" => true,
                             "branches" => {} }
    protocol = ProtocolDefinition.create!(name: "triagem-arbovirose", version: 1, status: "active", definition: definition)
    a_triage!(day: today - 2, protocol: protocol,
              answers: { "febre" => "true", "sintoma" => "Manchas", "gestante" => "true", "idade" => "34", "obs" => "true" })

    scheduled_run!

    expect(AnalyticsDailyFact.where(metric: "epi.answer").distinct.pluck(:question_id)).to match_array(%w[febre sintoma])
  end

  # Mutação: em Analytics::Consolidate.call, apagar a linha
  # `AnalyticsDailyFact.where(day: from..to).delete_all`.
  it "consolidar a mesma janela duas vezes produz os mesmos fatos" do
    protocol = analytics_protocol!
    an_attendance!(triage: a_triage!(day: today - 4, protocol: protocol, neighborhood: centro,
                                     answers: { "febre" => "true" }), unit: unit, wait_minutes: 45)
    a_triage!(day: today - 6, status: "aborted_by_cancellation")

    scheduled_run!
    first = snapshot
    scheduled_run!

    expect(AnalyticsRun.pluck(:status)).to eq(%w[succeeded succeeded])
    expect(snapshot).to eq(first)
    expect(first).not_to be_empty
  end

  # Mutação: em Analytics::Consolidate.call, trocar
  # `AnalyticsDailyFact.where(day: from..to).delete_all` por `AnalyticsDailyFact.delete_all`.
  it "a revogação não altera fato fora da janela; dentro dela, a pessoa sai na próxima execução" do
    protocol = analytics_protocol!
    old = a_triage!(day: today - 40, protocol: protocol, neighborhood: centro, answers: { "febre" => "true" })
    recent = a_triage!(day: today - 5, protocol: protocol, neighborhood: centro, answers: { "febre" => "true" })
    Analytics::Run.call(kind: "rebuild", from: today - 40, to: today - 31)
    scheduled_run!
    outside = AnalyticsDailyFact.where(day: today - 40).pluck(:metric, :dim, :neighborhood_id, :value).sort
    expect(outside).to include([ "epi.answer", "true", centro.id, 1 ])

    [ old, recent ].each do |triage|
      RevokeConsent.call(conversation: triage.conversation, reason: "citizen_web")
      AnonymizeRevokedTriageJob.new.handle(conversation_id: triage.conversation_id)
    end
    scheduled_run!

    expect(AnalyticsDailyFact.where(day: today - 40).pluck(:metric, :dim, :neighborhood_id, :value).sort).to eq(outside)
    expect(AnalyticsDailyFact.where(day: today - 5, metric: %w[triage.completed calibration.outcome epi.answer])).to be_empty
    expect(AnalyticsDailyFact.where(day: today - 5, metric: "triage.aborted").pluck(:dim, :neighborhood_id))
      .to eq([ [ "revocation", nil ] ])
  end

  # Mutação: em Analytics::Run#purge, trocar `...(Time.zone.today - FACT_RETENTION)`
  # por `..(Time.zone.today - FACT_RETENTION)`; ou FACT_RETENTION = 1.year.
  it "a purga apaga só fatos com mais de 5 anos" do
    older = fact!(metric: "triage.started", day: today - 5.years - 1, value: 9)
    edge = fact!(metric: "triage.started", day: today - 5.years, value: 9)
    year_ago = fact!(metric: "triage.started", day: today - 400, value: 9)

    scheduled_run!

    expect(AnalyticsDailyFact.where(id: [ older.id, edge.id, year_ago.id ]).pluck(:id))
      .to contain_exactly(edge.id, year_ago.id)
  end

  # Mutação: acrescentar "viewer" a Admin::Api::AnalyticsController::ROLES; ou, no
  # AnalyticsController, apagar o `render ... if Current.session.operator_grant?` de
  # require_authentication e fazer require_analytics_role aceitar `current_user.nil?`.
  it "só analyst e municipal_admin da cidade leem /admin/api/analytics; o operador, com ou sem grant, não" do
    consolidated_run!
    range = { from: (today - 14).iso8601, to: (today - 1).iso8601 }
    Membership::ROLES.each do |role|
      sign_in_as(staff_with("#{role}-#{SecureRandom.hex(2)}@cidade.gov.br", role))
      get "/admin/api/analytics/demand", params: range
      expect(response.status).to eq(%w[analyst municipal_admin].include?(role) ? 200 : 403), role
    end

    sign_in_operator_grant(operator!)
    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:forbidden)

    # Operador verificado SEM grant na cidade: entra de verdade no host do console
    # e só então a rota de analytics deve sumir (404), não apenas por roteamento.
    host! "admin.rotasaude.app"
    operator = operator!
    post "/session", params: { email_address: operator.email_address, password: operator_password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
    get "/admin/api/analytics/demand", params: range
    expect(response).to have_http_status(:not_found)
  end

  # Mutação: em Analytics::CityIndicatorsQuery#call, calcular last_published_at com
  # `CityConnection.with(city) { AnalyticsRun.maximum(:published_at) }`; ou, em
  # CityType#analytics_indicators, envolver a leitura em `inside { ... }`.
  it "o console do operador e o maintenance nunca abrem o banco da cidade para ler indicador" do
    CityAnalyticsIndicator.create!(city: city_record, week_start: (today - 14).beginning_of_week,
                                   indicator: "triages_started", value: 40, suppressed: false, published_at: Time.current)
    operator = operator!
    host! "admin.rotasaude.app"
    post "/session", params: { email_address: operator.email_address, password: operator_password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    maintainer = Maintainer.create!(email_address: "mt-#{SecureRandom.hex(3)}@rotasaude.app", password: operator_password,
                                    otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    frontend = "https://maintenance.rotasaude.app"
    browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    allow(CityConnection).to receive(:with).and_call_original

    get "/city_analytics"
    expect(response).to have_http_status(:ok)

    host! "maintenance-api.rotasaude.app"
    post "/session", params: { email_address: maintainer.email_address, password: operator_password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    query = 'query($slug: String!, $from: ISO8601Date!, $to: ISO8601Date!) { city(slug: $slug) { analyticsIndicators(from: $from, to: $to) { value } } }'
    post "/graphql", params: { query: query, variables: { slug: city_record.slug, from: (today - 21).iso8601,
                                                          to: (today - 1).iso8601 }.to_json }, headers: browser
    expect(json["errors"]).to be_nil
    expect(json.dig("data", "city", "analyticsIndicators")).to eq([ { "value" => 40.0 } ])

    expect(CityConnection).not_to have_received(:with)
  end
end
