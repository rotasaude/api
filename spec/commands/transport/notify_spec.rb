require "rails_helper"

# Módulo 30, Task 14 (ADR 0048; Desvio 8; contrato §8, §14 T15; D14): aviso
# de viagem na caixa do wpda, um por par validado do paciente e por (tipo,
# chave do evento), só em viagem confirmed/in_progress (o cancelamento só se a
# viagem tinha confirmed_at); SMS pelas regras do 17 (chave da cidade,
# provedor, opt-in, sem notices_muted nem appointment_reminders_muted, janela
# 8h–20h), texto fixo por evento, nunca o destino nem o prestador.
RSpec.describe Transport::Notify do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper

  around { |example| travel_to(Time.zone.local(2026, 11, 4, 10, 0)) { example.run } }
  before { SmsGateway::Test.reset! }
  after { SmsGateway::Test.reset! }

  let!(:city) { transport_city! }
  let(:dest) { destination! }
  let(:driver) { driver_user!.transport_driver }
  let(:trip) { trip!(date: Date.new(2026, 11, 5), vehicle: vehicle!, driver: driver, destination: dest) }
  let(:patient) { transport_patient! }
  let(:citizen) { Patients::Pairs.of(patient).sole }
  let!(:rider) { passenger!(trip, patient: patient, provider_name: "Hospital do Rim Centro", address: "Rua das Clínicas, 10") }

  let(:departure_text) { "Secretaria de Saúde de Curitiba: sua viagem de 05/11 sai às 07:00 de Praça Central." }

  def sms_on! = (CityProfile.current || CityProfile.create!(name: "Curitiba")).update!(campaigns_sms_enabled: true)
  def prefs!(who = citizen, opt_in: true, **over) = CitizenContactPreference.create!(citizen_id: who.id, sms_opt_in: opt_in, **over)
  def run_notices = perform_enqueued_jobs(only: Transport::NoticeJob)
  def notices(**where) = TransportTripNotice.where(transport_trip_passenger_id: rider.id, **where)
  def bodies = SmsGateway::Test.deliveries.map { |d| d[:body] }

  def confirm!
    result = Transport::ConfirmTrip.call(trip: trip, by: dispatcher!)
    raise "confirm falhou: #{result.reason}" unless result.ok?

    run_notices
  end

  # Segundo par validado do mesmo paciente (mesmo CPF, outro telefone).
  def second_pair!
    other = Citizen.create!(cpf: patient.cpf, phone: "+5541990001111")
    CitizenVerification.create!(citizen: other, verified_by_user: verifier!, verified_at: Time.current)
    other.update!(verification_level: "verified", profile_source: "verified", full_name: "Outra Pessoa", mother_name: "Mãe",
                  birth_date: patient.birth_date, sex: "female")
    other
  end

  # O mesmo evento entregue de novo (outro event_id): a dedup do consumidor
  # não o segura, só o índice único dos avisos.
  def redeliver!(event_name, payload)
    Transport::NoticeJob.perform_now(event_id: SecureRandom.uuid, event_name: event_name, city_slug: city.slug,
                                     payload: payload.deep_stringify_keys)
  end

  it "confirmar a viagem cria um aviso added por par validado; o evento repetido não duplica" do
    first = citizen
    other = second_pair!
    expect(Patients::Pairs.of(patient).count).to eq(2)
    confirm!
    expect(notices(kind: "added").pluck(:citizen_id)).to contain_exactly(first.id, other.id)
    expect(notices.pluck(:event_key).uniq).to eq([ "once" ])
    expect(notices.first.departure_at).to eq(trip.reload.departure_at)

    redeliver!("transport.trip_confirmed", trip_id: trip.id)
    expect(notices.count).to eq(2)
    expect(described_class.call(passenger: rider, kind: "added")).to eq(0)
  end

  it "com SMS ligado, opt-in e dentro da janela: SMS com o texto exato do added, sem destino nem prestador" do
    sms_on!
    prefs!
    confirm!
    expect(SmsGateway::Test.deliveries.size).to eq(1)
    expect(SmsGateway::Test.deliveries.first[:phone]).to eq(citizen.phone)
    expect(bodies.first).to eq(departure_text)
    expect(bodies.first).not_to include(dest.name, "Hospital do Rim", "Clínicas", patient.cpf)
    expect(notices.sole.sms).to be(true)
  end

  describe "aviso sem SMS" do
    before { sms_on! }

    it "sem opt-in" do
      prefs!(opt_in: false)
      confirm!
      expect(notices(kind: "added").sole.sms).to be(false)
      expect(SmsGateway::Test.deliveries).to be_empty
    end

    it "às 21h (fora da janela 8h–20h)" do
      prefs!
      Transport::ConfirmTrip.call(trip: trip, by: dispatcher!)
      expect(described_class.call(passenger: rider, kind: "added", now: Time.zone.local(2026, 11, 4, 21, 0))).to eq(1)
      expect(notices(kind: "added").sole.sms).to be(false)
      expect(SmsGateway::Test.deliveries).to be_empty
    end

    it "com appointment_reminders_muted" do
      prefs!(appointment_reminders_muted: true)
      confirm!
      expect(notices(kind: "added").sole.sms).to be(false)
      expect(SmsGateway::Test.deliveries).to be_empty
    end

    it "com notices_muted" do
      prefs!(notices_muted: true)
      confirm!
      expect(notices(kind: "added").sole.sms).to be(false)
      expect(SmsGateway::Test.deliveries).to be_empty
    end

    it "provedor que falha: o aviso nasce sem SMS e o log leva só a classe do erro" do
      prefs!
      allow(SmsGateway).to receive(:deliver).and_raise(RuntimeError, "provider down #{citizen.phone}")
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }
      confirm!
      expect(notices(kind: "added").sole.sms).to be(false)
      expect(logged).to eq([ "[transport.notice] SMS não saiu: RuntimeError" ])
    end
  end

  it "viagem planned: nenhum aviso (passageiro entrando ou viagem cancelada)" do
    expect(described_class.call(passenger: rider, kind: "added")).to eq(0)
    added = Transport::AddPassenger.call(trip: trip, by: dispatcher!,
                                         attrs: { "patient_id" => transport_patient!.id, "stop_id" => trip.transport_trip_stops.first.id,
                                                  "destination_id" => dest.id, "origin" => "exception",
                                                  "exception_reason" => "legacy_patient", "takes_seat" => true, "wheelchair" => false })
    raise "AddPassenger falhou: #{added.reason} #{added.details}" unless added.ok?

    Transport::CancelTrip.call(trip: trip, reason: "Veículo em manutenção corretiva", by: dispatcher!)
    run_notices
    expect(TransportTripNotice.count).to eq(0)
  end

  it "passageiro entrando em viagem confirmada → added; retirado → removed com o texto do cancelamento" do
    sms_on!
    confirm!
    newcomer = transport_patient!
    prefs!(Patients::Pairs.of(newcomer).sole)
    added = Transport::AddPassenger.call(trip: trip.reload, by: dispatcher!,
                                         attrs: { "patient_id" => newcomer.id, "stop_id" => trip.transport_trip_stops.first.id,
                                                  "destination_id" => dest.id, "origin" => "exception",
                                                  "exception_reason" => "legacy_patient", "takes_seat" => true, "wheelchair" => false })
    raise "AddPassenger falhou: #{added.reason} #{added.details}" unless added.ok?

    run_notices
    seat = added.payload.fetch(:passenger)
    expect(TransportTripNotice.where(transport_trip_passenger_id: seat.id).pluck(:kind)).to eq([ "added" ])

    Transport::RemovePassenger.call(passenger: seat.reload, reason: "Paciente desistiu da viagem", by: dispatcher!)
    run_notices
    expect(TransportTripNotice.where(transport_trip_passenger_id: seat.id).pluck(:kind)).to contain_exactly("added", "removed")
    expect(bodies.last).to eq("Secretaria de Saúde de Curitiba: sua viagem de 05/11 foi cancelada. " \
                              "Veja em #{Campaigns::SmsText.link(city)}")
  end

  it "viagem confirmada cancelada → cancelled; o passageiro já retirado não recebe" do
    confirm!
    Transport::CancelTrip.call(trip: trip.reload, reason: "Veículo em manutenção corretiva", by: dispatcher!)
    run_notices
    expect(notices.pluck(:kind)).to contain_exactly("added", "cancelled")
  end

  it "saída que muda 30 min → departure_changed uma vez por horário novo" do
    confirm!
    move = lambda do |hhmm|
      result = Transport::SaveTrip.call(trip: trip.reload, by: dispatcher!,
                                        attrs: { "departure_at" => Time.zone.parse("2026-11-05 #{hhmm}").iso8601 })
      raise "SaveTrip falhou: #{result.reason} #{result.details}" unless result.ok?

      run_notices
    end
    move.call("07:30")
    changed = notices(kind: "departure_changed")
    expect(changed.count).to eq(1)
    expect(changed.sole.event_key).to eq(Time.zone.parse("2026-11-05 07:30").iso8601)
    expect(changed.sole.departure_at).to eq(Time.zone.parse("2026-11-05 07:30"))

    redeliver!("transport.trip_changed", trip_id: trip.id, change: "departure")
    expect(notices(kind: "departure_changed").count).to eq(1)

    move.call("07:50") # 20 min: sem evento
    expect(notices(kind: "departure_changed").count).to eq(1)
    move.call("08:30")
    expect(notices(kind: "departure_changed").pluck(:event_key))
      .to contain_exactly(Time.zone.parse("2026-11-05 07:30").iso8601, Time.zone.parse("2026-11-05 08:30").iso8601)
  end

  it "rótulo da parada mudado → boarding_changed só para os passageiros dela, chave SHA-256 curta do rótulo" do
    confirm!
    stops = trip.reload.transport_trip_stops
    other_stop = trip.transport_trip_stops.create!(position: 3, kind: "boarding", label: "Posto do Distrito")
    # Embarques antes do destino: reordena pelo caminho real.
    result = Transport::SaveTrip.call(trip: trip.reload, by: dispatcher!, attrs: {
                                        "stops" => [
                                          { "id" => stops.first.id, "kind" => "boarding", "label" => "Terminal Norte" },
                                          { "id" => other_stop.id, "kind" => "boarding", "label" => "Posto do Distrito" },
                                          { "id" => stops.second.id, "kind" => "destination", "destination_id" => dest.id, "label" => dest.name }
                                        ]
                                      })
    raise "SaveTrip falhou: #{result.reason} #{result.details}" unless result.ok?

    elsewhere = passenger!(trip.reload, patient: transport_patient!, transport_trip_stop: other_stop)
    run_notices
    expect(notices(kind: "boarding_changed").sole.event_key).to eq(Digest::SHA256.hexdigest("Terminal Norte")[0, 16])
    expect(TransportTripNotice.where(transport_trip_passenger_id: elsewhere.id)).to be_empty
  end

  describe Transport::SmsText do
    let(:link) { Campaigns::SmsText.link(city) }

    before { CityProfile.create!(name: "Curitiba") unless CityProfile.current }

    it "um texto fixo por evento, com o prefixo do 17; parada truncada em 40; nunca destino nem prestador" do
      texts = Transport::Catalog::NOTICE_KINDS.to_h { |kind| [ kind, described_class.body(kind: kind, passenger: rider) ] }
      %w[added departure_changed boarding_changed reminder].each { |kind| expect(texts[kind]).to eq(departure_text) }
      %w[cancelled removed].each do |kind|
        expect(texts[kind]).to eq("Secretaria de Saúde de Curitiba: sua viagem de 05/11 foi cancelada. Veja em #{link}")
      end
      texts.each_value { |text| expect(text).not_to include(dest.name, "Hospital do Rim", "Clínicas") }

      rider.transport_trip_stop.update!(label: "Ponto de embarque da Unidade Básica do Bairro Alto")
      expect(described_class.body(kind: "reminder", passenger: rider.reload))
        .to eq("Secretaria de Saúde de Curitiba: sua viagem de 05/11 sai às 07:00 de Ponto de embarque da Unidade Básica do.")
    end
  end
end
