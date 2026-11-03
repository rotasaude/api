require "rails_helper"

# Módulo 30, Task 4 (Desvio 2; Review Focus 1): a mesma pergunta da exclusion
# constraint, em SQL, antes de gravar — intervalo meio-aberto [), a própria
# viagem e as canceladas fora, todas as recusas de uma vez.
RSpec.describe Transport::Overlap do
  let!(:city) { transport_city! }
  let(:van) { vehicle! }
  let(:driver) { driver_user!.transport_driver }
  let(:day) { Date.current + 3 }
  let!(:existing) { trip!(date: day, departure: "07:00", back: "12:00", vehicle: van, driver: driver) }

  def candidate(dep, back, vehicle: van, driver: self.driver)
    TransportTrip.new(departure_at: Time.zone.parse("#{day} #{dep}"), return_at: Time.zone.parse("#{day} #{back}"),
                      transport_vehicle: vehicle, transport_driver: driver)
  end

  it "encostada (volta 12:00, saída 12:00) não cruza" do
    expect(described_class.problems(candidate("12:00", "15:00"))).to eq([])
    expect(described_class.problems(candidate("05:00", "07:00"))).to eq([])
  end

  it "um minuto de cruzamento recusa veículo e motorista juntos" do
    expect(described_class.problems(candidate("11:59", "13:00")))
      .to contain_exactly({ path: "vehicle_id", error: "vehicle_overlap" }, { path: "driver_id", error: "driver_overlap" })
  end

  it "só o recurso repetido é recusado; sem veículo nem motorista, nada" do
    other_van = vehicle!
    expect(described_class.problems(candidate("08:00", "09:00", vehicle: other_van))).to eq([ { path: "driver_id", error: "driver_overlap" } ])
    expect(described_class.problems(candidate("08:00", "09:00", driver: driver_user!.transport_driver)))
      .to eq([ { path: "vehicle_id", error: "vehicle_overlap" } ])
    expect(described_class.problems(candidate("08:00", "09:00", vehicle: nil, driver: nil))).to eq([])
  end

  it "ignora a própria viagem e a cancelada" do
    existing.departure_at = Time.zone.parse("#{day} 08:00")
    expect(described_class.problems(existing)).to eq([])
    existing.reload.update!(status: "cancelled", cancelled_at: Time.current)
    expect(described_class.problems(candidate("08:00", "09:00"))).to eq([])
  end

  it "outro dia não cruza; viagem que atravessa a noite cruza com a do dia seguinte" do
    expect(described_class.problems(candidate("07:00", "12:00").tap { |t| t.assign_attributes(departure_at: t.departure_at + 1.day, return_at: t.return_at + 1.day) }))
      .to eq([])
    overnight = TransportTrip.new(departure_at: Time.zone.parse("#{day - 1} 20:00"), return_at: Time.zone.parse("#{day} 07:30"),
                                  transport_vehicle: van, transport_driver: nil)
    expect(described_class.problems(overnight)).to eq([ { path: "vehicle_id", error: "vehicle_overlap" } ])
  end
end
