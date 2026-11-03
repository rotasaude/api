require "rails_helper"

# Módulo 30, Task 7 (ADR 0048; contrato §4, §14 T6, T18): séries recorrentes
# da central, suspensão, pendências e o job diário por cidade.
RSpec.describe "Transporte — séries e pendências", type: :request do
  let!(:city) { transport_city! }
  let(:dest) { destination! }
  let(:patient) { transport_patient! }
  let(:monday) { Date.current.next_occurring(:monday) }
  def body(**over)
    { patient_id: patient.id, destination_id: dest.id, weekdays: [ 1, 3, 5 ], appointment_time: "07:00", departure_time: "05:30",
      return_time: "13:00", boarding_label: "Posto do Distrito", starts_on: monday.iso8601, wheelchair: false }.merge(over)
  end

  before { sign_in_as(dispatcher!) }

  it "cria e lê a série na forma <series> (T6), sem documento inteiro do acompanhante" do
    json_post "/transport/series", body(provider_name: "Clínica Renal Campos Gerais",
                                        companion: { name: "Maria Acompanhante", document: "MG1234567", reason: "Paciente com limitação de mobilidade" })
    expect(response).to have_http_status(:created)
    expect(json_body).to eq(
      "id" => json_body["id"], "patient" => { "id" => patient.id, "display_name" => patient.display_name },
      "destination" => { "id" => dest.id, "name" => dest.name }, "provider_name" => "Clínica Renal Campos Gerais",
      "weekdays" => [ 1, 3, 5 ], "appointment_time" => "07:00", "departure_time" => "05:30", "return_time" => "13:00",
      "boarding_label" => "Posto do Distrito", "starts_on" => monday.iso8601, "ends_on" => nil, "wheelchair" => false,
      "companion" => { "name" => "Maria Acompanhante", "document_last4" => "4567" }, "status" => "active", "suspended_from" => nil
    )
    series = TransportSeries.find(json_body["id"])
    expect(series.created_by_user_id).to eq(dispatcher!.id)
    get "/transport/series/#{series.id}"
    expect(json_body["departure_time"]).to eq("05:30")
    get "/transport/series"
    expect(json_body["items"].map { |s| s["id"] }).to eq([ series.id ])
    expect(response.body).not_to include("MG1234567")
  end

  it "recusas de campo todas de uma vez: weekdays fora de 1..7, volta antes da saída, fim antes do início, embarque e volta obrigatórios" do
    json_post "/transport/series", body(weekdays: [ 0, 8 ], departure_time: "13:00", return_time: "13:00",
                                        ends_on: (monday - 1).iso8601)
    expect(response.status).to eq(422)
    expect(json_body["problems"]).to contain_exactly(
      { "path" => "weekdays", "error" => "invalid_request" }, { "path" => "return_time", "error" => "return_before_departure" },
      { "path" => "ends_on", "error" => "invalid_request" }
    )
    json_post "/transport/series", body.except(:return_time, :boarding_label)
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("return_time", "boarding_label")
    json_post "/transport/series", body(boarding_label: "ab", weekdays: [ 1, 1 ], departure_time: "5:30")
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("boarding_label", "weekdays", "departure_time")
    json_post "/transport/series", body(weekdays: [])
    expect(json_body["path"]).to eq("weekdays")
    expect(TransportSeries.count).to eq(0)
  end

  it "acompanhante fora da regra de idade sem motivo → companion_not_allowed" do
    json_post "/transport/series", body(companion: { name: "Maria Acompanhante" })
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "companion_not_allowed", "companion" ])
    expect(TransportSeries.count).to eq(0)
  end

  it "PATCH altera só o que veio; o paciente não troca; ends_on no passado → ended" do
    json_post "/transport/series", body(starts_on: (Date.current - 30).iso8601)
    id = json_body["id"]
    json_patch "/transport/series/#{id}", weekdays: [ 2, 4 ], departure_time: "06:00"
    expect(json_body).to include("weekdays" => [ 2, 4 ], "departure_time" => "06:00", "return_time" => "13:00", "status" => "active")
    json_patch "/transport/series/#{id}", patient_id: transport_patient!.id
    expect([ response.status, json_body["path"] ]).to eq([ 422, "patient_id" ])
    json_patch "/transport/series/#{id}", return_time: "05:00"
    expect(json_body["problems"]).to eq([ { "path" => "return_time", "error" => "return_before_departure" } ])
    json_patch "/transport/series/#{id}", ends_on: (Date.current - 1).iso8601
    expect(json_body["status"]).to eq("ended")
    json_patch "/transport/series/#{SecureRandom.uuid}", weekdays: [ 1 ]
    expect(response).to have_http_status(:not_found)
  end

  it "suspender pela rota: tira das viagens futuras, status suspended com suspended_from" do
    json_post "/transport/series", body
    series = TransportSeries.find(json_body["id"])
    Transport::MaterializeSeries.call(series: series, today: monday)
    json_post "/transport/series/#{series.id}/suspend", from_on: Date.current.iso8601, reason: "Transplante realizado, fim da diálise"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "suspended", "suspended_from" => Date.current.iso8601)
    expect(TransportTripPassenger.where(transport_series_id: series.id, removed_at: nil).count).to eq(0)
    json_post "/transport/series/#{series.id}/suspend", from_on: Date.current.iso8601, reason: "curto"
    expect([ response.status, json_body["path"] ]).to eq([ 422, "reason" ])
  end

  it "GET /transport/pending traz as pendências abertas de hoje em diante, só com series_id, date e reason" do
    json_post "/transport/series", body
    series = TransportSeries.find(json_body["id"])
    full = trip!(date: monday, vehicle: vehicle!(seats: 1, wheelchair_spots: 0), driver: driver_user!.transport_driver, status: "confirmed",
                 destination: dest)
    passenger!(full)
    Transport::MaterializeSeries.call(series: series, today: monday)
    TransportPendingItem.create!(transport_series: series, date: Date.current - 1, reason: "no_seat")
    TransportPendingItem.create!(transport_series: series, date: monday + 30, reason: "no_wheelchair_spot", resolved_at: Time.current)
    get "/transport/pending"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("items" => [ { "series_id" => series.id, "date" => monday.iso8601, "reason" => "no_seat" } ])
  end

  it "FR I4: a pendência refused (recusa do AddPassenger fora da lotação) aparece em /transport/pending" do
    json_post "/transport/series", body
    series = TransportSeries.find(json_body["id"])
    TransportPendingItem.create!(transport_series: series, date: monday, reason: "refused")
    get "/transport/pending"
    expect(json_body).to eq("items" => [ { "series_id" => series.id, "date" => monday.iso8601, "reason" => "refused" } ])
  end

  it "motorista e comissão → 403 missing_role; transporte desligado → 403 feature_disabled" do
    [ driver_user!, committee! ].each do |user|
      sign_in_as(user)
      get "/transport/series"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      get "/transport/pending"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      json_post "/transport/series", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
    sign_in_as(dispatcher!)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    get "/transport/pending"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "sanitary_transport")
  end

  describe Transport::MaterializeSeriesJob do
    after { Current.reset }

    def new_series!(**over)
      Transport::SaveSeries.call(attrs: body(**{ starts_on: Date.current.iso8601, weekdays: [ 1, 2, 3, 4, 5, 6, 7 ] }.merge(over)).deep_stringify_keys,
                                 by: dispatcher!).payload[:series]
    end

    it "materializa as séries ativas da cidade, 21 dias à frente, e rodar de novo não duplica" do
      series = new_series!
      described_class.perform_now
      expect(TransportTrip.where(transport_series_id: series.id).count).to eq(21)
      expect { described_class.perform_now }.not_to(change { [ TransportTrip.count, TransportTripPassenger.count, TransportPendingItem.count ] })
    end

    it "com sanitary_transport desligado não faz nada" do
      new_series!
      Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
      described_class.perform_now
      expect(TransportTrip.count).to eq(0)
      expect(TransportTripPassenger.count).to eq(0)
    end

    it "série suspensa ou encerrada fica de fora" do
      suspended = new_series!
      suspended.update!(suspended_from: Date.current, suspend_reason: "Paciente internado no hospital")
      ended = new_series!(patient_id: transport_patient!.id, starts_on: (Date.current - 10).iso8601)
      ended.update!(ends_on: Date.current - 1)
      described_class.perform_now
      expect(TransportTrip.count).to eq(0)
    end

    it "trava e relê a série: suspensa por outra transação logo antes do processamento → nada" do
      series = new_series!
      allow_any_instance_of(TransportSeries).to receive(:lock!).and_wrap_original do |original, *args|
        TransportSeries.where(id: series.id).update_all(suspended_from: Date.current, suspend_reason: "Suspensa por outra sessão da central")
        original.call(*args)
      end
      described_class.perform_now
      expect(TransportTrip.count).to eq(0)
      expect(TransportTripPassenger.count).to eq(0)
    end

    it "show com query string → 422 (dado só no corpo)" do
      series = new_series!
      get "/transport/series/#{series.id}?patient_id=x"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "patient_id" ])
    end

    it "uma série que falha não impede as outras; o log leva só o id e a classe do erro" do
      bad = new_series!
      good = new_series!(patient_id: transport_patient!.id)
      allow(Transport::MaterializeSeries).to receive(:call).and_call_original
      allow(Transport::MaterializeSeries).to receive(:call).with(series: having_attributes(id: bad.id), today: anything)
                                                           .and_raise(ActiveRecord::StatementInvalid, "Posto do Distrito secreto")
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message }
      expect { described_class.perform_now }.to raise_error(EachCityJob::AggregatedFailure)
      expect(TransportTrip.where(transport_series_id: good.id).count).to eq(21)
      expect(TransportTrip.where(transport_series_id: bad.id).count).to eq(0)
      line = logged.find { |message| message.include?("series=") }
      expect(line).to include("series=#{bad.id}", "ActiveRecord::StatementInvalid")
      expect(logged.join).not_to include("Posto do Distrito")
    end

    it "está agendado todo dia às 2h na fila housekeeping" do
      task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("production").fetch("transport_materialize_series")
      expect(task).to include("class" => "Transport::MaterializeSeriesJob", "queue" => "housekeeping",
                              "schedule" => "every day at 2am America/Sao_Paulo")
    end
  end
end
