require "rails_helper"

# Módulo 25, Task 13 (fix round 1): a regra de "vencida" tem uma definição em
# SQL (DiseaseNotification.overdue_sql) e o espelho em Ruby (#overdue?); a fila
# e os alertas diários usam a SQL. Aqui as duas coincidem num fixture misto.
RSpec.describe "DiseaseNotification overdue rule" do
  before { surveillance_city! }

  let(:now) { Time.current }

  def mixed_fixture!
    rows = [
      [ "possible", -1.hour ], [ "possible", 1.hour ], [ "notified", -2.days ], [ "notified", 3.days ],
      [ "investigating", -2.days ], [ "closed", -2.days ], [ "dismissed", -2.days ]
    ]
    rows.each_with_index.map do |(status, offset), i|
      n = notification!(patient: surveillance_patient!(i + 1), disease_code: "dengue", status: %w[possible notified].include?(status) ? status : nil)
      attrs = { status: status, due_at: now + offset }
      attrs[:classification] = "discarded" if status == "closed"
      attrs[:dismissed_at] = now if status == "dismissed"
      n.update_columns(attrs)
      n
    end
  end

  it "o escopo, a fila e os contadores devolvem exatamente as linhas com overdue? verdadeiro" do
    mixed_fixture!
    expected = DiseaseNotification.all.select { |n| n.overdue?(now) }.map(&:id)

    expect(expected.size).to eq(2) # possible e notified com o prazo passado
    expect(DiseaseNotification.overdue_at(now).pluck(:id)).to match_array(expected)
    expect(Surveillance::Queue.call(filters: { "overdue" => "true" }, limit: 50, now: now).payload[:rows].map(&:id)).to match_array(expected)
    expect(Surveillance::Queue.counts(now: now)[:overdue]).to eq(expected.size)
  end
end
