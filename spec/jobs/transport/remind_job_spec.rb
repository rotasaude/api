require "rails_helper"

# Módulo 30, Task 14 (Desvio 8; §14 T15): lembrete da véspera da viagem
# confirmada, das 17h às 20h no fuso da cidade, como o lembrete do 17; um só
# por passageiro e par (índice único), rodando a cada 15 minutos.
RSpec.describe Transport::RemindJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:eve) { Date.new(2026, 11, 4) }
  let!(:city) { travel_to(eve.in_time_zone.change(hour: 9)) { transport_city! } }
  let(:trip_date) { eve + 1 }

  def confirmed_trip!(date: trip_date, status: "confirmed")
    travel_to(eve.in_time_zone.change(hour: 9)) do
      trip = trip!(date: date, vehicle: vehicle!, driver: driver_user!.transport_driver, status: status)
      [ trip, passenger!(trip) ]
    end
  end

  def run_at(hour, min = 0) = travel_to(eve.in_time_zone.change(hour: hour, min: min)) { described_class.perform_now }
  def reminders = TransportTripNotice.where(kind: "reminder")

  it "18h da véspera: um aviso reminder por par; rodar de novo não duplica" do
    _trip, rider = confirmed_trip!
    run_at(18)
    run_at(18, 15)
    expect(reminders.pluck(:transport_trip_passenger_id, :event_key)).to eq([ [ rider.id, "once" ] ])
    expect(reminders.sole.citizen_id).to eq(Patients::Pairs.of(rider.patient).sole.id)
  end

  it "16h da véspera: nada; às 20h (fora da janela): nada" do
    confirmed_trip!
    run_at(16, 45)
    run_at(20, 0)
    expect(reminders).to be_empty
  end

  it "só viagens confirmadas de amanhã: planned, de depois de amanhã e passageiro retirado ficam de fora" do
    confirmed_trip!(status: "planned")
    confirmed_trip!(date: trip_date + 1)
    _trip, removed = confirmed_trip!
    removed.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Paciente desistiu da viagem")
    run_at(18)
    expect(reminders).to be_empty
  end

  it "transporte desligado na cidade: nada" do
    confirmed_trip!
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    run_at(18)
    expect(reminders).to be_empty
  end

  it "está no recurring.yml a cada 15 minutos, na fila housekeeping" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("production").fetch("transport_remind")
    expect(task).to include("class" => "Transport::RemindJob", "queue" => "housekeeping", "schedule" => "every 15 minutes")
  end
end
