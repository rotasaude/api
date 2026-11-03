require "rails_helper"

# Módulo 30, Task 6 (ADR 0048; contrato §4, T18): a lista de passageiros
# impressa leva só nome, embarque, destino, hora, acompanhante e cadeira.
# Nunca CPF, CNS, CID, texto do pedido nem o alvo do pedido de regulação.
RSpec.describe Transport::ManifestPdf, type: :request do
  let!(:city) { transport_city! }
  let(:trip) { trip!(vehicle: vehicle!, driver: driver_user!.transport_driver) }
  let(:patient_and_citizen) { exam_patient!(exam_seq!) }
  let(:patient) { patient_and_citizen.first }

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  it "traz nome, embarque, destino, prestador, hora, acompanhante e cadeira; nada clínico nem CPF/CNS" do
    patient.update!(birth_date: "2015-01-01")
    cid10_release!
    request = regulation_request!(status: "draft", citizen: patient_and_citizen.last)
    at = Time.zone.parse("#{trip.date} 09:40")
    passenger!(trip, patient: patient, origin: "regulation", exception_reason: nil, regulation_request: request,
                     provider_name: "Hospital Universitário", appointment_at: at, wheelchair: true,
                     companion_name: "Mãe da Criança", companion_document: "98765432100", companion_attendance: "pending")
    gone = transport_patient!
    gone.update!(full_name: "Zacarias Removido Souza", social_name: nil)
    removed = passenger!(trip, patient: gone)
    removed.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Desistiu da viagem")

    text = text_of(described_class.call(trip))

    expect(text).to include(patient.display_name, "Praça Central", "Ponta Grossa", "Hospital Universitário", "09:40",
                            "Mãe da Criança", "cadeira de rodas", "07:00", trip.transport_vehicle.plate, "Sprinter 415")
    expect(text).not_to include("Zacarias Removido")
    forbidden = [ patient.cpf, patient.cpf.to_s.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4'), patient.cns, "I10",
                  "Hipertensão resistente", request.reload.target_name, "Cardiologia", "98765432100" ].compact_blank
    expect(request.target_name).to be_present
    expect(forbidden).not_to be_empty
    forbidden.each { |value| expect(text).not_to include(value) }
  end

  it "lista quem estiver em parada de destino e mostra a data do retorno de outro dia" do
    overnight = trip!(back: "06:00", vehicle: vehicle!, driver: driver_user!.transport_driver)
    stray = transport_patient!
    stray.update!(full_name: "Berenice Parada Solta", social_name: nil)
    destination_stop = overnight.transport_trip_stops.find_by!(kind: "destination")
    passenger!(overnight, patient: stray).update!(transport_trip_stop: destination_stop)

    text = text_of(described_class.call(overnight))

    expect(text).to include("Berenice Parada Solta", "Retorno: #{(overnight.date + 1).strftime('%d/%m/%Y')} 06:00")
  end

  it "devolve um PDF" do
    expect(described_class.call(trip)).to start_with("%PDF")
  end
end
