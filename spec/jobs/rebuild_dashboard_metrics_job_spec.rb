require "rails_helper"

# Caracterização (Ruling R12/R31): prende o contrato de agregação do job ANTES
# de remover a dimensão de município. As asserções (linhas de dashboard_metrics
# por dimension/period/key/value) NÃO mudam quando o corpo do job muda — só o
# harness e a montagem dos dados mudam junto com o schema.
#
# Harness desta versão: o corpo ATUAL do job ainda lê conversations.municipality_id
# e grava dashboard_metrics.municipality_id, colunas que o schema de cidade não
# tem. Para caracterizá-lo verde, o exemplo roda contra o schema PRÉ-CORTE que
# ainda existe no banco de teste compartilhado (rota_saude_test, tabelas vazias),
# dentro da transação das fixtures (rollback ao final — nada persiste).
RSpec.describe RebuildDashboardMetricsJob, type: :job do
  LEGACY_SHARED_SCHEMA = CityTestDatabases.city("legacyshared", "rota_saude_test").freeze

  REBUILD_CHAR_MODELS = [Municipality, Conversation, Triage, ProtocolDefinition, DashboardMetric].freeze

  # Registra o pool ANTES do exemplo, para o setup de fixtures transacionais
  # piná-lo e fazer rollback do que o exemplo gravar.
  before(:context) { CityConnection.ensure_pool(LEGACY_SHARED_SCHEMA) }

  around do |example|
    within_city(LEGACY_SHARED_SCHEMA) do
      REBUILD_CHAR_MODELS.each(&:reset_column_information)
      example.run
    ensure
      REBUILD_CHAR_MODELS.each(&:reset_column_information)
    end
  end

  REBUILD_CHAR_DEFINITION = {
    "name" => "triage-respiratoria", "version" => 1, "start_step_id" => "tosse",
    "steps" => [
      { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
        "branches" => { "true" => "febre", "false" => nil }, "weights" => { "true" => 3, "false" => 0 } },
      { "id" => "febre", "prompt" => "Está com febre alta?", "answer_type" => "boolean",
        "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
    ],
    "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                   "priority_map" => { "baixa" => 9, "alta" => 1 } }
  }.freeze

  REBUILD_CHAR_DAY1 = "2026-09-01".freeze
  REBUILD_CHAR_DAY2 = "2026-09-02".freeze

  # — montagem (muda com o schema; as asserções abaixo não) —

  def municipality
    @municipality ||= Municipality.create!(name: "Char City", slug: "char-city")
  end

  def protocol
    @protocol ||= ProtocolDefinition.create!(
      municipality: municipality, name: "triage-respiratoria", version: 1,
      status: "active", definition: REBUILD_CHAR_DEFINITION
    )
  end

  def conversation(phone)
    Conversation.create!(municipality: municipality, phone: phone, state: "consented")
  end

  def completed_triage(phone, tier:, priority:, day:)
    Triage.create!(
      conversation: conversation(phone), protocol_definition: protocol,
      protocol_name: "triage-respiratoria", status: "completed",
      tier: tier, priority: priority, answers: {},
      completed_at: Time.zone.parse("#{day} 12:00:00 UTC")
    )
  end

  def in_progress_triage(phone)
    Triage.create!(
      conversation: conversation(phone), protocol_definition: protocol,
      protocol_name: "triage-respiratoria", status: "in_progress", answers: {}
    )
  end

  def stale_metric!
    DashboardMetric.create!(municipality_id: municipality.id, dimension: "triages_total",
                            period: "2020-01-01", key: "total", value: 99)
  end

  # O job é `prepend EachCityJob`: `perform` itera o catálogo. Aqui interessa o
  # corpo por cidade, então chama a implementação do próprio job.
  def run_body(**kwargs)
    described_class.instance_method(:perform).super_method.bind_call(described_class.new, **kwargs)
  end

  def metric_rows
    DashboardMetric.pluck(:dimension, :period, :key, :value)
  end

  before do
    completed_triage("+5541990000001", tier: "alta",  priority: 1, day: REBUILD_CHAR_DAY1)
    completed_triage("+5541990000002", tier: "alta",  priority: 1, day: REBUILD_CHAR_DAY1)
    completed_triage("+5541990000003", tier: "baixa", priority: 9, day: REBUILD_CHAR_DAY1)
    completed_triage("+5541990000004", tier: "alta",  priority: 1, day: REBUILD_CHAR_DAY2)
    in_progress_triage("+5541990000005")
    stale_metric!
  end

  it "rebuilds tier, total and priority counts per completion day from completed triages only" do
    run_body

    expect(metric_rows).to contain_exactly(
      [ "triages_by_tier",       REBUILD_CHAR_DAY1, "alta",  2 ],
      [ "triages_by_tier",       REBUILD_CHAR_DAY1, "baixa", 1 ],
      [ "triages_by_tier",       REBUILD_CHAR_DAY2, "alta",  1 ],
      [ "triages_total",         REBUILD_CHAR_DAY1, "total", 3 ],
      [ "triages_total",         REBUILD_CHAR_DAY2, "total", 1 ],
      [ "priority_distribution", REBUILD_CHAR_DAY1, "1",     2 ],
      [ "priority_distribution", REBUILD_CHAR_DAY1, "9",     1 ],
      [ "priority_distribution", REBUILD_CHAR_DAY2, "1",     1 ]
    )
  end

  it "with since:, wipes every existing metric and rebuilds only triages completed from that moment on" do
    run_body(since: "#{REBUILD_CHAR_DAY2} 00:00:00 UTC")

    expect(metric_rows).to contain_exactly(
      [ "triages_by_tier",       REBUILD_CHAR_DAY2, "alta",  1 ],
      [ "triages_total",         REBUILD_CHAR_DAY2, "total", 1 ],
      [ "priority_distribution", REBUILD_CHAR_DAY2, "1",     1 ]
    )
  end

  it "leaves no metric rows when there is no completed triage" do
    Triage.where(status: "completed").delete_all

    run_body

    expect(metric_rows).to be_empty
  end
end
