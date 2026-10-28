require "rails_helper"

RSpec.describe Surveillance::Duplicates do
  include ActiveSupport::Testing::TimeHelpers
  before { surveillance_city! }
  let(:patient) { surveillance_patient!(11) }
  let(:dengue) { Surveillance::Diseases.find("dengue", today: Time.zone.today) }
  let(:today) { Time.zone.today }

  def blocking(disease = dengue) = described_class.blocking(patient_id: patient.id, disease: disease, today: today)

  def close!(notification, at)
    notification.update!(status: "closed", classification: "discarded", closed_at: at)
    notification
  end

  it "nada bloqueia sem notificação; outra doença e outro paciente não contam" do
    expect(blocking).to be_nil
    notification!(patient: patient, disease_code: "tuberculose")
    notification!(patient: surveillance_patient!(12))
    expect(blocking).to be_nil
  end

  it "possible, notified e investigating bloqueiam (devolve a aberta)" do
    open = notification!(patient: patient, origin: "safety_net")
    expect(blocking).to eq(open)
    open.update!(status: "notified")
    expect(blocking).to eq(open)
    open.update!(status: "investigating")
    expect(blocking).to eq(open)
  end

  it "dismissed não bloqueia" do
    possible = notification!(patient: patient, origin: "safety_net")
    possible.update!(status: "dismissed", dismissed_at: Time.current)
    expect(blocking).to be_nil
  end

  it "fechada ou digitada bloqueia por repeat_after_days dias (30: dia 29 bloqueia, dia 30 libera)" do
    closed = close!(notification!(patient: patient), (today - 29).in_time_zone.change(hour: 10))
    expect(blocking).to eq(closed)
    closed.update!(status: "entered", official_number: "123", entered_at: Time.current)
    expect(blocking).to eq(closed)
    closed.update_columns(closed_at: (today - 30).in_time_zone.change(hour: 10))
    expect(blocking).to be_nil
  end

  it "a janela conta em dias da cidade: fechada às 23h de ontem conta como ontem" do
    one_day = dengue.with(repeat_after_days: 1)
    two_days = dengue.with(repeat_after_days: 2)
    late = close!(notification!(patient: patient), (today - 1).in_time_zone.change(hour: 23))
    # 23h de ontem em São Paulo = 02h de hoje em UTC: pelo dia UTC seria hoje e bloquearia.
    expect(late.closed_at.utc.to_date).to eq(today)
    expect(blocking(one_day)).to be_nil
    expect(blocking(two_days)).to eq(late)
    late.update_columns(closed_at: today.in_time_zone)
    expect(blocking(one_day)).to eq(late)
  end

  it "today é o dia de referência (não o relógio)" do
    closed = close!(notification!(patient: patient), Time.current)
    expect(described_class.blocking(patient_id: patient.id, disease: dengue, today: today + 29)).to eq(closed)
    expect(described_class.blocking(patient_id: patient.id, disease: dengue, today: today + 30)).to be_nil
  end
end
