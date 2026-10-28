require "rails_helper"

# Módulo 26a, Task 7: "vencido" tem uma definição em SQL
# (RegulationRequest.overdue_sql) e o espelho em Ruby (#overdue?); a fila e os
# contadores usam a SQL. Aqui as duas coincidem num fixture misto.
RSpec.describe "RegulationRequest overdue rule" do
  let!(:city) { regulation_city! }
  let(:today) { Time.zone.today }

  it "overdue_sql e #overdue? devolvem exatamente as mesmas linhas" do
    unit = create_unit("UBS Vencido")
    doctor = doctor!(unit)
    rows = %w[pending returned authorized external scheduled completed denied].flat_map do |status|
      [ -1, 0, 1 ].map do |offset|
        r = regulation_request!(unit: unit, doctor: doctor)
        r.update_columns(status: status, due_on: today + offset)
        r
      end
    end
    expected = rows.select { |r| r.reload.overdue?(today) }.map(&:id)

    expect(expected.size).to eq(4) # pending, returned, authorized, external com due_on ontem
    expect(RegulationRequest.where(RegulationRequest.overdue_sql(today)).pluck(:id)).to match_array(expected)
    expect(RegulationRequest.overdue_at(today).pluck(:id)).to match_array(expected)
  end
end
