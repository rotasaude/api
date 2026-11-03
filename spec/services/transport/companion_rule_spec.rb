require "rails_helper"

# Módulo 30, Task 5 (ADR 0048; plano, Desvio 5; §14 T17): acompanhante sem
# motivo só para criança (idade <= max_age_child) ou idoso (>= min_age_elderly)
# na data da viagem; fora disso exige motivo. No TFD, só com a indicação do
# laudo (o motivo não supre).
RSpec.describe Transport::CompanionRule do
  before { transport_city! }

  let(:trip_day) { Date.new(2026, 11, 20) }

  def patient_born(date) = Patient.new(full_name: "Paciente de Teste", birth_date: date.iso8601)
  def check(patient, reason: nil, origin: "exception", tfd_case: nil)
    described_class.check(patient: patient, on: trip_day, origin: origin, tfd_case: tfd_case, reason: reason)
  end

  it "15 anos e 364 dias → :ok; 16 anos completos no dia → recusa sem motivo, aceita com motivo" do
    expect(check(patient_born(trip_day - 16.years + 1.day))).to eq(:ok)
    sixteen = patient_born(trip_day - 16.years)
    expect(check(sixteen)).to eq(:companion_not_allowed)
    expect(check(sixteen, reason: "Paciente com deficiência intelectual")).to eq(:ok)
  end

  it "60 anos completos no dia da viagem → :ok; 59 (faz 60 amanhã) → recusa" do
    expect(check(patient_born(trip_day - 60.years))).to eq(:ok)
    expect(check(patient_born(trip_day - 60.years + 1.day))).to eq(:companion_not_allowed)
  end

  it "sem data de nascimento conhecida: só com motivo" do
    expect(check(Patient.new(full_name: "Sem Nascimento"))).to eq(:companion_not_allowed)
    expect(check(Patient.new(full_name: "Sem Nascimento"), reason: "Paciente acamado")).to eq(:ok)
  end

  it "a regra da cidade (12/65) vale no lugar do padrão 15/60" do
    TransportSetting.current.update!(companion_max_age_child: 12, companion_min_age_elderly: 65)
    expect(check(patient_born(trip_day - 12.years))).to eq(:ok)
    expect(check(patient_born(trip_day - 13.years))).to eq(:companion_not_allowed)
    expect(check(patient_born(trip_day - 64.years))).to eq(:companion_not_allowed)
    expect(check(patient_born(trip_day - 65.years))).to eq(:ok)
  end

  it "TFD: só com a indicação do laudo; o motivo e a idade não suprem" do
    child = patient_born(trip_day - 8.years)
    indicated = TfdCase.new(report: { "companion_indicated" => true })
    not_indicated = TfdCase.new(report: { "companion_indicated" => false })
    expect(check(patient_born(trip_day - 40.years), origin: "tfd", tfd_case: indicated)).to eq(:ok)
    expect(check(child, origin: "tfd", tfd_case: not_indicated)).to eq(:companion_not_allowed)
    expect(check(patient_born(trip_day - 40.years), origin: "tfd", tfd_case: not_indicated, reason: "Paciente com baixa visão"))
      .to eq(:companion_not_allowed)
    expect(check(child, origin: "tfd", tfd_case: TfdCase.new(report: {}))).to eq(:companion_not_allowed)
  end
end
