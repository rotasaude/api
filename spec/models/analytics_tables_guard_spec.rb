require "rails_helper"

# Módulo 14 (ADR 0025; spec 2026-09-30 §3.1–§3.2): o banco recusa fato de
# métrica desconhecida, com valor < 1, ou repetido na mesma célula — inclusive
# com recortes nulos (índice único NULLS NOT DISTINCT) —, e run com tipo,
# estado ou janela inválidos. Tudo por SQL direto, sem passar pelo modelo.
RSpec.describe "Guardas das tabelas de Analytics" do
  let(:day) { Time.zone.today - 3 }

  def raw_fact!(**attrs)
    ApplicationRecord.transaction(requires_new: true) do
      AnalyticsDailyFact.create!({ day: day, metric: "triage.started", value: 3, consolidated_at: Time.current }.merge(attrs))
    end
  end

  it "métrica fora da lista e valor menor que 1 são recusados por CHECK" do
    expect do
      sql_in_savepoint("INSERT INTO analytics_daily_facts (day, metric, dim, value, consolidated_at) " \
                       "VALUES ('#{day.iso8601}', 'lixo', '', 3, now())")
    end.to raise_error(ActiveRecord::StatementInvalid, /ck_analytics_facts_metric/)
    expect do
      sql_in_savepoint("INSERT INTO analytics_daily_facts (day, metric, dim, value, consolidated_at) " \
                       "VALUES ('#{day.iso8601}', 'triage.started', '', 0, now())")
    end.to raise_error(ActiveRecord::StatementInvalid, /ck_analytics_facts_value/)
  end

  it "uma linha por célula, com recortes nulos tratados como iguais" do
    raw_fact!
    expect { raw_fact! }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { raw_fact!(neighborhood_id: SecureRandom.uuid) }.not_to raise_error
    expect { raw_fact!(dim: "timeout", metric: "triage.aborted") }.not_to raise_error
  end

  it "run: tipo, estado e janela garantidos por CHECK" do
    run = AnalyticsRun.create!(kind: "scheduled", status: "running", window_from: day - 30, window_to: day,
                               started_at: Time.current)
    {
      "status = 'lixo'" => /ck_analytics_runs_status/,
      "kind = 'lixo'" => /ck_analytics_runs_kind/,
      "window_from = window_to + 1" => /ck_analytics_runs_window/
    }.each do |assignment, error|
      expect { sql_in_savepoint("UPDATE analytics_runs SET #{assignment} WHERE id = '#{run.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, error), assignment
    end
  end

  it "o banco aceita o papel analyst" do
    user = staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br")
    expect do
      sql_in_savepoint("INSERT INTO memberships (id, user_id, role, granted_at, created_at, updated_at) " \
                       "VALUES (gen_random_uuid(), '#{user.id}', 'analyst', now(), now(), now())")
    end.not_to raise_error
  end
end
