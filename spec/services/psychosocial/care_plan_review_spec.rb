require "rails_helper"

# Módulo 31 (contrato P16, §11): CarePlanReview.overdue_count (o painel) tem a
# MESMA semântica de CarePlanReview.due (a rota care_plans/due e o job), numa
# contagem SQL só: sem carregar matrícula nem paciente, e com o número de
# consultas independente de quantas matrículas há.
RSpec.describe Psychosocial::CarePlanReview do
  let!(:city) { psychosocial_city! }
  let(:today) { Date.new(2026, 11, 18) }
  let(:caps) { caps!(modality: "caps_ii") }
  let(:other) { caps!(modality: "caps_i") }
  let(:author) { caps_staff!(caps, lead: true) }

  def plan!(enrollment, version, review_on)
    PsychosocialCarePlan.create!(psychosocial_enrollment: enrollment, version: version, needs: "x", goals: [], intensity: "intensive",
                                 review_on: review_on, created_by_user: author)
  end

  def queries
    sqls = []
    callback = ->(*, payload) { sqls << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    sqls
  end

  it "conta o que due devolve, em todos os casos de borda, somando os CAPS" do
    a = enrollment!(caps, started_on: Date.new(2026, 10, 1))
    plan!(a, 1, Date.new(2026, 10, 1)) # vencida, mas a versão 2 está em dia
    plan!(a, 2, Date.new(2027, 1, 1))
    b = enrollment!(caps, started_on: Date.new(2026, 10, 1))
    plan!(b, 1, Date.new(2026, 11, 17)) # ontem: vencida
    c = enrollment!(caps, started_on: Date.new(2026, 10, 1))
    plan!(c, 1, today)                  # hoje: ainda não venceu (review_on < hoje)
    d = enrollment!(caps, started_on: Date.new(2026, 7, 1)) # sem PTS, > 90 dias
    enrollment!(caps, started_on: Date.new(2026, 8, 20))    # sem PTS, exatamente 90 dias: em dia
    enrollment!(caps, started_on: Date.new(2026, 8, 19))    # sem PTS, 91 dias: vencida
    closed = enrollment!(caps, started_on: Date.new(2026, 7, 1))
    plan!(closed, 1, Date.new(2026, 8, 1))
    closed.update!(closed_on: Date.new(2026, 11, 10), destination: "01", closed_by_user: author) # encerrada: fora
    e = enrollment!(other, started_on: Date.new(2026, 7, 1))
    plan!(e, 1, Date.new(2026, 9, 1))

    expected = [ caps, other ].sum { |unit| described_class.due(unit: unit, today: today).size }
    expect(expected).to eq(4) # b, d, a de 91 dias e e
    expect(described_class.overdue_count(units: [ caps, other ], today: today)).to eq(expected)
    expect(described_class.overdue_count(units: [ caps ], today: today)).to eq(described_class.due(unit: caps, today: today).size)
    expect(described_class.overdue_count(units: [], today: today)).to eq(0)
    expect(d.reload).to be_present
  end

  it "o prazo sem PTS acompanha care_plan_review_days do CAPS" do
    enrollment!(caps, started_on: Date.new(2026, 10, 1)) # 48 dias
    expect(described_class.overdue_count(units: [ caps ], today: today)).to eq(0)
    PsychosocialSetting.current.update!(care_plan_review_days: 30)
    expect(described_class.overdue_count(units: [ caps ], today: today)).to eq(1)
    expect(described_class.due(unit: caps, today: today).size).to eq(1)
  end

  it "uma contagem SQL: o número de consultas não cresce com as matrículas e nenhum paciente é carregado" do
    enrollment!(caps, started_on: Date.new(2026, 7, 1))
    small = queries { described_class.overdue_count(units: [ caps ], today: today) }
    7.times do
      e = enrollment!(caps, started_on: Date.new(2026, 7, 1))
      plan!(e, 1, Date.new(2026, 9, 1))
    end
    large = queries { expect(described_class.overdue_count(units: [ caps ], today: today)).to eq(8) }
    expect(large.size).to eq(small.size)
    expect(large.size).to be <= 2
    expect(large.grep(/FROM "patients"/)).to be_empty
    expect(large.grep(/FROM "psychosocial_enrollments"/).size).to eq(1)
  end
end
