require "rails_helper"

# Módulo 29, Task 5 (ADR 0047; Desvio 10): o motor do calendário, Ruby puro
# sobre o YAML vigente. Casos do PDF a conferir pela revisão de enfermagem
# (todo o calendário nasce `review: true`).
RSpec.describe Vaccination::Schedule do
  let(:calendar) { Vaccination::Calendar.current }
  let(:born) { Date.new(2026, 1, 10) }
  def run(today:, doses: [], checked: true, sex: "female", pregnant_since: nil)
    described_class.call(birth_date: born, sex: sex, pregnant_since: pregnant_since, doses: doses, checked: checked, today: today, calendar: calendar)
  end
  def item(items, series, dose) = items.find { |i| i.series == series && i.dose_code == dose }

  it "penta 1 devida aos 2 meses; em atraso depois da janela; não conferida vira unchecked" do
    expect(item(run(today: born + 60), "penta", "1")).to have_attributes(status: "due", due_on: born + 60)
    expect(item(run(today: born + 95), "penta", "1").status).to eq("overdue")
    expect(item(run(today: born + 95, checked: false), "penta", "1").status).to eq("unchecked")
  end

  it "penta 2 aprazada pelo intervalo recomendado a partir da dose real" do
    items = run(today: born + 80, doses: [ { id: "a", code: "42", dose_code: "1", on: born + 75 } ])
    expect(item(items, "penta", "1")).to have_attributes(status: "complete", applied_id: "a")
    expect(item(items, "penta", "2")).to have_attributes(status: "upcoming", due_on: born + 135)
  end

  it "hexa transcrita conta para penta e VIP" do
    items = run(today: born + 70, doses: [ { id: "h", code: "43", dose_code: "1", on: born + 61 } ])
    expect([ item(items, "penta", "1").status, item(items, "vip", "1").status ]).to eq(%w[complete complete])
  end

  it "rotavírus 1 depois de 105 dias de vida não se aplica mais" do
    expect(item(run(today: born + 120), "rota", "1").status).to eq("not_applicable")
  end

  it "dTpa da gestante só a partir da 20ª semana e só para gestante" do
    adult = Date.new(1996, 5, 1)
    items = described_class.call(birth_date: adult, sex: "female", pregnant_since: Date.new(2026, 6, 1), doses: [], checked: true,
                                 today: Date.new(2026, 10, 25), calendar: calendar)
    expect(item(items, "dtpa_pregnancy", "8")).to have_attributes(status: "due", due_on: Date.new(2026, 10, 19))
    no_pregnancy = described_class.call(birth_date: adult, sex: "female", pregnant_since: nil, doses: [], checked: true,
                                        today: Date.new(2026, 10, 25), calendar: calendar)
    expect(no_pregnancy.map(&:series)).not_to include("dtpa_pregnancy")
  end

  it "dTpa de uma gestação anterior não conta para a atual" do
    adult = Date.new(1996, 5, 1)
    old = { id: "old", code: "57", dose_code: "8", on: Date.new(2024, 3, 1) }
    now = { id: "now", code: "57", dose_code: "8", on: Date.new(2026, 10, 20) }
    call = ->(doses) { described_class.call(birth_date: adult, sex: "female", pregnant_since: Date.new(2026, 6, 1), doses: doses, checked: true, today: Date.new(2026, 10, 25), calendar: calendar) }
    expect(item(call.([ old ]), "dtpa_pregnancy", "8").status).to eq("due")
    expect(item(call.([ old, now ]), "dtpa_pregnancy", "8")).to have_attributes(status: "complete", applied_id: "now")
  end

  it "dose anterior pendente: a seguinte fica upcoming sem data" do
    expect(item(run(today: born + 60), "penta", "2")).to have_attributes(status: "upcoming", due_on: nil)
  end

  it "dose sem código casado conta para a menor dose pendente; repetição do mesmo código não avança a série" do
    items = run(today: born + 80, doses: [ { id: "x", code: "42", dose_code: "9", on: born + 62 } ])
    expect(item(items, "penta", "1")).to have_attributes(status: "complete", applied_id: "x")
    repeated = run(today: born + 200, doses: [ { id: "a", code: "42", dose_code: "1", on: born + 62 }, { id: "b", code: "42", dose_code: "1", on: born + 64 } ])
    expect(item(repeated, "penta", "1").applied_id).to eq("a")
    expect(item(repeated, "penta", "2").status).not_to eq("complete")
  end

  it "séries fora do público pela idade não entram" do
    child = run(today: born + 60).map(&:series)
    expect(child).to include("penta", "bcg")
    expect(child).not_to include("hpv", "dt_adult", "dtpa_pregnancy")
    adult = described_class.call(birth_date: Date.new(1990, 1, 1), sex: "male", pregnant_since: nil, doses: [], checked: true,
                                 today: Date.new(2026, 11, 2), calendar: calendar).map(&:series)
    expect(adult).to include("dt_adult")
    expect(adult).not_to include("penta", "hpv", "influenza")
  end

  it "série que se repete: devida a partir da idade mínima; depois, a última dose + o período" do
    adult = Date.new(1990, 1, 1)
    call = ->(doses) { described_class.call(birth_date: adult, sex: "male", pregnant_since: nil, doses: doses, checked: true, today: Date.new(2026, 11, 2), calendar: calendar) }
    expect(item(call.([]), "dt_adult", "6")).to have_attributes(status: "overdue", due_on: adult + 2555)
    last = { id: "dt", code: "25", dose_code: "6", on: Date.new(2020, 5, 1) }
    expect(item(call.([ last ]), "dt_adult", "6")).to have_attributes(status: "upcoming", due_on: Date.new(2020, 5, 1) + 3650, applied_id: "dt")
  end

  # Review Focus 2: o caso mais comum no go-live.
  it "criança de 1 ano, caderneta não conferida, nenhuma dose: nenhum overdue; os itens passados viram unchecked" do
    items = run(today: born + 365, checked: false)
    expect(items.map(&:status)).not_to include("overdue")
    expect(item(items, "penta", "1")).to have_attributes(status: "unchecked", due_on: born + 60)
    expect(item(items, "penta", "3")).to have_attributes(status: "unchecked", due_on: born + 180)
    expect(item(items, "bcg", "9").status).to eq("unchecked")
    expect(item(items, "vip", "6")).to have_attributes(status: "upcoming", due_on: nil)
    expect(item(items, "rota", "1").status).to eq("not_applicable")
    # A mesma criança com a caderneta conferida: os passados ficam em atraso.
    expect(item(run(today: born + 365, checked: true), "penta", "1").status).to eq("overdue")
  end
end
