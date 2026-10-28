require "rails_helper"

# Módulo 25, Task 13: quem teve caso na semana (K7) — a regra que o lembrete da
# negativa e o painel de pendências compartilham.
RSpec.describe Surveillance::WeekCases do
  before { surveillance_city! }

  let(:week) { Surveillance::EpiWeek.new(year: 2026, week: 42) } # 18 a 24/10/2026

  def at(date) = Time.zone.local(date.year, date.month, date.day, 12)

  def case!(n, status:, on:, unit:)
    notification!(patient: surveillance_patient!(n), unit: unit, suspected_at: at(on), status: status)
  end

  it "conta a unidade da notificação que passou da possível, pela semana da suspeita" do
    a = create_unit("UBS A #{SecureRandom.hex(2)}")
    b = create_unit("UBS B #{SecureRandom.hex(2)}")
    case!(1, status: "notified", on: week.starts_on, unit: a)
    n = case!(2, status: "notified", on: week.ends_on, unit: b)
    n.update_columns(status: "closed", classification: "discarded") # encerrada continua sendo caso

    expect(described_class.unit_ids_with_cases(week)).to eq(Set[a.id, b.id])
  end

  it "possible e dismissed não contam; fora da semana também não" do
    unit = create_unit("UBS C #{SecureRandom.hex(2)}")
    other = create_unit("UBS D #{SecureRandom.hex(2)}")
    case!(3, status: "possible", on: week.starts_on + 1, unit: unit)
    dismissed = case!(4, status: "possible", on: week.starts_on + 2, unit: unit)
    dismissed.update_columns(status: "dismissed", dismissed_at: Time.current)
    case!(5, status: "notified", on: week.starts_on - 1, unit: other)
    case!(6, status: "notified", on: week.ends_on + 1, unit: other)

    expect(described_class.unit_ids_with_cases(week)).to be_empty
  end
end
