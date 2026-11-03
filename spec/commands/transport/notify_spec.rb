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

  # Relógio parado às 10h da véspera; `travel` entre os passos dá a cada aviso
  # o seu created_at (o "último aviso" é o mais novo).
  before { travel_to(Time.zone.local(2026, 11, 4, 10, 0)) }
  before { SmsGateway::Test.reset! }
  after { SmsGateway::Test.reset! }
  after { travel_back }

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
  def run_notices
    perform_enqueued_jobs(only: Transport::NoticeJob)
    perform_enqueued_jobs(only: Transport::PassengerNoticeJob)
  end

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
    perform_enqueued_jobs(only: Transport::PassengerNoticeJob)
  end

  def move!(hhmm)
    travel 1.minute
    result = Transport::SaveTrip.call(trip: trip.reload, by: dispatcher!,
                                      attrs: { "departure_at" => Time.zone.parse("2026-11-05 #{hhmm}").iso8601 })
    raise "SaveTrip falhou: #{result.reason} #{result.details}" unless result.ok?
  end

  def departures(kind: "departure_changed") = notices(kind: kind).order(:created_at).map { |n| n.departure_at.strftime("%H:%M") }
  def latest_notice = notices.order(:created_at).last

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

  it "viagem confirmada cancelada → cancelled só para os ativos: o já retirado e o anonimizado não recebem" do
    gone = passenger!(trip, patient: transport_patient!)
    erased = passenger!(trip, patient: transport_patient!, anonymized_at: Time.current)
    confirm!
    expect(TransportTripNotice.where(transport_trip_passenger_id: erased.id)).to be_empty
    expect(TransportTripNotice.where(transport_trip_passenger_id: gone.id).pluck(:kind)).to eq([ "added" ])

    Transport::RemovePassenger.call(passenger: gone.reload, reason: "Paciente desistiu da viagem", by: dispatcher!)
    run_notices
    move!("08:00")
    run_notices
    travel 1.minute
    Transport::CancelTrip.call(trip: trip.reload, reason: "Veículo em manutenção corretiva", by: dispatcher!)
    run_notices
    expect(notices.pluck(:kind)).to contain_exactly("added", "departure_changed", "cancelled")
    expect(TransportTripNotice.where(transport_trip_passenger_id: gone.id).pluck(:kind)).to contain_exactly("added", "removed")
    expect(TransportTripNotice.where(transport_trip_passenger_id: erased.id)).to be_empty
  end

  describe "mudança da saída (Ruling I-2: comparada com o último valor avisado ao par)" do
    before { confirm! }

    it "30 min → departure_changed com a chave do evento; o evento repetido não duplica" do
      move!("07:30")
      run_notices
      changed = notices(kind: "departure_changed").sole
      expect(changed.event_key).to eq(DomainEvent.where(name: "transport.trip_changed").sole.id)
      expect(changed.departure_at).to eq(Time.zone.parse("2026-11-05 07:30"))
      redeliver!("transport.trip_changed", trip_id: trip.id, change: "departure")
      expect(notices(kind: "departure_changed").count).to eq(1)
    end

    it "A→B→A→B: avisa cada ida e volta, e o último aviso mostra a saída real" do
      %w[08:00 07:00 08:00].each do |hhmm|
        move!(hhmm)
        run_notices
      end
      expect(departures).to eq(%w[08:00 07:00 08:00])
      expect(latest_notice.departure_at).to eq(trip.reload.departure_at)
    end

    it "gradual 07:00→07:20→07:40→08:00: avisa quando o acumulado chega a 30 min (07:40), não a cada passo" do
      %w[07:20 07:40 08:00].each do |hhmm|
        move!(hhmm)
        run_notices
      end
      expect(departures).to eq(%w[07:40])
    end

    it "FW14: par validado depois da confirmação (sem aviso anterior) recebe o departure_changed da mudança de 30 min" do
      citizen # o primeiro par, antes do segundo existir
      late = second_pair!
      move!("07:30")
      run_notices
      late_notices = TransportTripNotice.where(transport_trip_passenger_id: rider.id, citizen_id: late.id)
      expect(late_notices.pluck(:kind)).to eq([ "departure_changed" ])
      expect(late_notices.sole.departure_at).to eq(Time.zone.parse("2026-11-05 07:30"))
      expect(notices(citizen_id: citizen.id, kind: "departure_changed").count).to eq(1)
    end

    it "FW14b: o created_at do aviso é lido depois da trava do passageiro" do
      allow(TransportTripPassenger).to receive(:lock).and_wrap_original do |original, *args|
        travel 5.minutes # quem esperou a trava chega depois
        original.call(*args)
      end
      move!("07:30")
      asked_at = Time.current
      Transport::Notify.call(passenger: rider, kind: "departure_changed", event_key: "fw14b")
      expect(notices(event_key: "fw14b").sole.created_at).to be >= asked_at + 5.minutes
    end

    it "A→B→A processado depois: nenhum 'mudou' mostrando a saída que não mudou" do
      move!("08:00")
      move!("07:00")
      run_notices
      expect(notices(kind: "departure_changed")).to be_empty
      expect(latest_notice.departure_at).to eq(trip.reload.departure_at)
    end
  end

  it "rótulo da parada mudado → boarding_changed só para os passageiros dela, com o rótulo novo; voltar e ir de novo avisa de novo" do
    confirm!
    stops = trip.reload.transport_trip_stops
    other_stop = trip.transport_trip_stops.create!(position: 3, kind: "boarding", label: "Posto do Distrito")
    elsewhere = passenger!(trip.reload, patient: transport_patient!, transport_trip_stop: other_stop)
    relabel = lambda do |label|
      travel 1.minute
      result = Transport::SaveTrip.call(trip: trip.reload, by: dispatcher!, attrs: {
                                          "stops" => [
                                            { "id" => stops.first.id, "kind" => "boarding", "label" => label },
                                            { "id" => other_stop.id, "kind" => "boarding", "label" => "Posto do Distrito" },
                                            { "id" => stops.second.id, "kind" => "destination", "destination_id" => dest.id, "label" => dest.name }
                                          ]
                                        })
      raise "SaveTrip falhou: #{result.reason} #{result.details}" unless result.ok?

      run_notices
    end
    relabel.call("Terminal Norte")
    changed = notices(kind: "boarding_changed").sole
    expect(changed.boarding_label).to eq("Terminal Norte")
    expect(changed.event_key).to eq(DomainEvent.where(name: "transport.trip_changed").sole.id)
    relabel.call("Praça Central")
    relabel.call("Terminal Norte")
    expect(notices(kind: "boarding_changed").order(:created_at).pluck(:boarding_label))
      .to eq([ "Terminal Norte", "Praça Central", "Terminal Norte" ])
    expect(TransportTripNotice.where(transport_trip_passenger_id: elsewhere.id, kind: "boarding_changed")).to be_empty
  end

  it "Ruling I-1: um job por passageiro; a falha do 2º não desfaz nem reenvia o SMS do 1º na nova tentativa" do
    sms_on!
    prefs!
    second = passenger!(trip, patient: transport_patient!)
    second_citizen = Patients::Pairs.of(second.patient).sole
    prefs!(second_citizen)
    Transport::ConfirmTrip.call(trip: trip, by: dispatcher!)
    perform_enqueued_jobs(only: Transport::NoticeJob)
    jobs = enqueued_jobs.select { |job| job[:job] == Transport::PassengerNoticeJob }
    expect(jobs.size).to eq(2)
    clear_enqueued_jobs

    failing = true
    allow(Transport::Notify).to receive(:call).and_wrap_original do |original, **kwargs|
      raise ActiveRecord::StatementInvalid, "boom" if failing && kwargs[:passenger].id == second.id

      original.call(**kwargs)
    end
    run = ->(rider_id) { Transport::PassengerNoticeJob.perform_now(city_slug: city.slug, passenger_id: rider_id, kind: "added") }
    run.call(rider.id)
    expect { run.call(second.id) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(notices(kind: "added").count).to eq(1)

    failing = false
    run.call(second.id) # nova tentativa do 2º
    run.call(rider.id)  # e mesmo um reenvio do 1º
    phones = SmsGateway::Test.deliveries.map { |d| d[:phone] }
    expect(phones.tally).to eq(citizen.phone => 1, second_citizen.phone => 1)
  end

  it "D7: cidade desconhecida → PassengerNoticeJob levanta CityMissing (nunca some calado)" do
    expect { Transport::PassengerNoticeJob.perform_now(city_slug: "cidade-que-nao-existe", passenger_id: rider.id, kind: "added") }
      .to raise_error(CityScopedJob::CityMissing)
  end

  it "transporte desligado: o evento não gera aviso" do
    Transport::ConfirmTrip.call(trip: trip, by: dispatcher!)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    run_notices
    expect(TransportTripNotice.count).to eq(0)
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
