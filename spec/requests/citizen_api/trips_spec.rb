require "rails_helper"

# Módulo 30, Task 15 (ADR 0048; contrato §8; §14 T14; Desvio 16): "Minhas
# viagens" do cidadão — só o par validado do celular da sessão (outro celular
# 404, só declarado 403 not_verified); transporte desligado 403
# feature_disabled; tfd desligado → "tfd": []. Viagens sem veículo, motorista,
# procedimento nem CID, em departure_at crescente; TFD sem rascunho, sem
# laudo nem motivo, com a soma da ajuda de custo e `paid` só quando os
# pagamentos alcançam o total. Trilha citizen uma vez por requisição.
RSpec.describe "Cidadão — minhas viagens", type: :request do
  let!(:city) { transport_city!(tfd: true) }
  let(:patient) { transport_patient! }
  let(:citizen) { Patients::Pairs.of(patient).sole }
  let(:ponta_grossa) { destination! }
  let(:londrina) { destination!(name: "Londrina", ibge: "4113700", km: 380) }
  let(:vehicle) { vehicle! }
  let(:driver) { driver_user! }

  def read!(id = citizen.id)
    sign_in_citizen(citizen.phone)
    get "/citizen/trips", params: { citizen_id: id }
  end

  def pay!(tfd, cents)
    TfdPayment.create!(tfd_case: tfd, paid_on: Date.current, amount_cents: cents, payment_method: "pix", receipt_number: "REC-#{cents}",
                       by_user: committee!)
  end

  it "cidadão validado vê a viagem com embarque, destino (nome e prestador) e situação, sem placa, motorista, procedimento ou CID" do
    trip = trip!(date: Date.current + 2, vehicle: vehicle, driver: driver.transport_driver, status: "confirmed", destination: ponta_grossa)
    rider = passenger!(trip, patient: patient, provider_name: "Hospital do Rim Centro", address: "Rua das Clínicas, 10",
                             companion_name: "Filha do Paciente", companion_attendance: "pending")

    read!

    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to eq(%w[items tfd])
    departure = trip.departure_at.in_time_zone
    expect(json_body["items"]).to eq([
      { "id" => rider.id, "date" => trip.date.iso8601, "departure_at" => departure.iso8601, "boarding" => { "label" => "Praça Central" },
        "destination" => { "name" => "Ponta Grossa", "provider_name" => "Hospital do Rim Centro" }, "status" => "confirmed", "companion" => true }
    ])
    expect(json_body["items"].sole["departure_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/)
    expect(response.body).not_to include(vehicle.plate, Transport::Json.user_name(driver), driver.email_address, "Clínicas", "Filha do Paciente", "N185", "0301010072")
    expect(response.body).not_to match(/vehicle|driver|plate|cid|procedure|sigtap/i)
  end

  it "itens em departure_at crescente; retirado fora; janela de hoje − 90 dias; cancelada aparece com a situação" do
    later = passenger!(trip!(date: Date.current + 5, destination: ponta_grossa), patient: patient)
    past = passenger!(trip!(date: Date.current - 10, vehicle: vehicle, driver: driver.transport_driver, status: "done", destination: ponta_grossa),
                      patient: patient, attendance: "boarded")
    passenger!(trip!(date: Date.current - 91, destination: ponta_grossa), patient: patient)
    passenger!(trip!(date: Date.current + 3, destination: ponta_grossa), patient: patient, removed_at: Time.current, removed_by_user: dispatcher!,
                                                                         remove_reason: "Paciente desistiu da viagem")
    gone = trip!(date: Date.current + 1, destination: ponta_grossa)
    cancelled = passenger!(gone, patient: patient)
    gone.update!(status: "cancelled", cancelled_at: Time.current, cancelled_by_user: dispatcher!, cancel_reason: "Veículo quebrado na estrada")

    read!

    expect(json_body["items"].map { |i| [ i["id"], i["status"], i["companion"] ] })
      .to eq([ [ past.id, "done", false ], [ cancelled.id, "cancelled", false ], [ later.id, "planned", false ] ])
    expect(response.body).not_to include("Veículo quebrado", "desistiu")
  end

  it "até 50: fica com as 50 mais novas, mostradas em ordem crescente" do
    rows = (0..50).map do |n|
      passenger!(trip!(date: Date.current - 80 + n, destination: ponta_grossa), patient: patient)
    end

    read!

    expect(json_body["items"].map { |i| i["id"] }).to eq(rows.last(50).map(&:id))
  end

  it "FW12: mais de 50 passadas e algumas futuras → todas as futuras primeiro, completa com as passadas mais recentes, crescente" do
    past = (1..60).map { |n| passenger!(trip!(date: Date.current - n, destination: ponta_grossa), patient: patient) }
    future = (1..3).map { |n| passenger!(trip!(date: Date.current + n, destination: ponta_grossa), patient: patient) }
    today = passenger!(trip!(date: Date.current, departure: "23:00", back: "23:30", destination: ponta_grossa), patient: patient)

    read!

    ids = json_body["items"].map { |i| i["id"] }
    expect(ids.size).to eq(50)
    expect(ids.last(4)).to eq([ today.id ] + future.map(&:id))
    expect(ids.first(46)).to eq(past.first(46).reverse.map(&:id)) # as 46 mais recentes (ontem para trás), crescente
    expect(json_body["items"].map { |i| i["departure_at"] }).to eq(json_body["items"].map { |i| i["departure_at"] }.sort)
  end

  it "FW12: mais de 50 futuras → as 50 mais próximas, sem nenhuma passada" do
    passenger!(trip!(date: Date.current - 1, destination: ponta_grossa), patient: patient)
    future = (1..52).map { |n| passenger!(trip!(date: Date.current + n, destination: ponta_grossa), patient: patient) }

    read!

    expect(json_body["items"].map { |i| i["id"] }).to eq(future.first(50).map(&:id))
  end

  it "FW10: total de ajuda 0 → paid false mesmo sem pagamento a alcançar" do
    tfd = tfd_case!(status: "travelling", patient: patient, destination: londrina)
    leg = TfdLeg.create!(tfd_case: tfd, direction: "outbound", mode: "bus_ticket", date: Date.current, distance_km: 380,
                         ticket_amount_cents: 100, ticket_carrier: "Viação", done_at: Time.current, created_by_user: committee!)
    TfdAllowance.create!(tfd_case: tfd, tfd_leg: leg, person: "patient", kind: "ground_km", sigtap_code: "0803010125", quantity: 8,
                         table_cents: 0, complement_cents: 0, total_cents: 0, competence: Date.current.strftime("%Y%m"))

    read!

    expect(json_body["tfd"].sole).to include("allowance_total_cents" => 0, "paid" => false)
  end

  it "TFD aparece com allowance_total_cents e paid: false (pagamento parcial); rascunho nunca; returned aparece; laudo nunca" do
    tfd = tfd_case!(status: "authorized", patient: patient, destination: londrina)
    tfd_leg_done!(tfd, "outbound", Date.current - 1)
    total = TfdAllowance.where(tfd_case: tfd).sum(:total_cents)
    expect(total).to be_positive
    pay!(tfd, total - 1)
    tfd_case!(status: "draft", patient: patient, destination: londrina)
    returned = tfd_case!(status: "returned", patient: patient, destination: londrina)
    tfd.update_columns(appointment_at: Time.zone.parse("#{(Date.current + 7).iso8601} 09:30"))

    read!

    by_id = json_body["tfd"].index_by { |row| row["id"] }
    expect(by_id.keys).to contain_exactly(tfd.id, returned.id)
    expect(by_id[tfd.id]).to eq("id" => tfd.id, "status" => "travelling", "destination_name" => "Londrina",
                                "appointment_at" => tfd.reload.appointment_at.in_time_zone.iso8601,
                                "allowance_total_cents" => total, "paid" => false)
    expect(by_id[returned.id]).to eq("id" => returned.id, "status" => "returned", "destination_name" => "Londrina", "appointment_at" => nil,
                                     "allowance_total_cents" => nil, "paid" => false)
    expect(response.body).not_to include("N185", "0301010072", "nefrologia", "limitação de mobilidade")
    expect(response.body).not_to match(/report|justification|reason|cid/i)

    pay!(tfd, 1)
    read!
    expect(json_body["tfd"].find { |row| row["id"] == tfd.id }["paid"]).to be(true)
  end

  it "tfd desligado: \"tfd\": [] e as viagens continuam" do
    tfd_case!(status: "authorized", patient: patient, destination: londrina)
    rider = passenger!(trip!(date: Date.current + 1, destination: ponta_grossa), patient: patient)
    Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)

    read!

    expect(response).to have_http_status(:ok)
    expect(json_body["tfd"]).to eq([])
    expect(json_body["items"].map { |i| i["id"] }).to eq([ rider.id ])
  end

  it "trilha citizen uma vez por requisição" do
    events = []
    allow(DomainEvents).to receive(:publish).and_wrap_original { |m, *args, **kw| events << [ args.first, kw ]; m.call(*args, **kw) }

    read!

    viewed = events.select { |name, _| name == "clinical_record.viewed" }
    expect(viewed.size).to eq(1)
    expect(viewed.first.last).to include(patient_id: patient.id, access: "citizen")
  end

  it "par só declarado: 403 not_verified" do
    declared = profiled_citizen!(age: 30, phone: "+5541990000124")
    sign_in_citizen(declared.phone)
    get "/citizen/trips", params: { citizen_id: declared.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "not_verified")
  end

  it "pessoa de outro celular: 404" do
    other = Patients::Pairs.of(transport_patient!).sole
    read!(other.id)
    expect(response).to have_http_status(:not_found)
  end

  it "sem sessão: 401" do
    get "/citizen/trips", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:unauthorized)
  end

  it "transporte desligado: 403 feature_disabled; sanitary_transport e tfd em features da sessão quando ligados" do
    sign_in_citizen(citizen.phone)
    get "/citizen/session"
    expect(json_body["features"]).to include("sanitary_transport", "tfd")

    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/trips", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "sanitary_transport")
    get "/citizen/session"
    expect(json_body["features"]).not_to include("sanitary_transport", "tfd")
  end
end
