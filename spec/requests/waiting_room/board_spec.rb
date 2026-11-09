require "rails_helper"

# Módulo 32a (ADR 0050; contrato §8 e §14 Q8; plano, Valor fixado 6): o
# painel da TV da sala de espera. `GET /waiting_room/board` com o cabeçalho
# `X-Display-Token`, sem cookie de sessão: as últimas 8 chamadas com senha dos
# últimos 30 min e, só numa UPA com os dois flags, a mediana de espera por cor
# ("lt5_patients" com menos de 5). Nunca nome, CPF, CNS, cor da pessoa, queixa
# nem id de paciente, encontro ou atendimento; sem trilha e sem evento — a
# leitura só grava `last_seen_at` (no máximo a cada 60 s).
RSpec.describe "Painel da TV", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city!(waiting_room: true) }
  let(:upa) { upa! }
  let(:other_upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let!(:room) { call_location!(upa, name: "Consultório 1") }
  let!(:pair) { paired_display!(upa) }
  let(:token) { pair.last }
  before { urgency_protocol! }
  after { Current.reset }

  def board(t = token) = get("/waiting_room/board", headers: { "X-Display-Token" => t })

  it "mostra senha e local da última chamada e nada da pessoa" do
    patient = urgency_patient!(1)
    e = arrived!(upa, patient: patient)
    classified!(e, color: "red", by: nurse, vital_signs: { spo2: 85 })
    sign_in_as(doctor)
    json_post "/attendance/units/#{upa.id}/call_next", call_location_id: room.id
    expect(response).to have_http_status(:ok)
    reset!                                             # sem cookie de sessão: a TV não tem login
    host! test_city_host
    expect { board }.not_to change(DomainEvent, :count)
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to contain_exactly("unit", "calls", "wait_times", "updated_at")
    expect(json_body["unit"]).to eq("name" => upa.name)
    expect(json_body["calls"].map { |c| c.keys.sort }.uniq).to eq([ %w[called_at kind location ticket] ])
    expect(json_body["calls"].first).to include("ticket" => "U-001", "location" => "Consultório 1", "kind" => "care")
    text = response.body
    [ patient.full_name, patient.cpf, patient.cns, e.id, e.attendance_id, patient.id, "SpO2", "spo2", UrgencyHelpers::JUSTIFICATION ]
      .compact.each { |s| expect(text).not_to include(s) }
    # A cor só existe nos tempos por cor (agregados), nunca na chamada da pessoa.
    expect(json_body["wait_times"].map { |w| w.keys.sort }.uniq).to eq([ %w[color median_minutes] ])
    expect(json_body["wait_times"].map { |w| w["color"] }).to eq(Urgency::Catalog::COLORS)
    expect(json_body["wait_times"].map { |w| w["median_minutes"] }.uniq).to eq([ "lt5_patients" ])
  end

  it "o token de uma UPA não lê outra; revogado → 401 display_revoked; sem token → 401" do
    other_token = paired_display!(other_upa).last
    e = arrived!(upa, patient: urgency_patient!(2)).tap { |x| classified!(x, color: "green", by: nurse, pain_scale: 5) }
    called!(e, by: doctor, call_location: room)
    board(other_token)
    expect(response).to have_http_status(:ok)
    expect(json_body["calls"]).to eq([])
    board
    expect(json_body["calls"].size).to eq(1)
    WaitingRoom::Revoke.call(display: pair.first, by: urgency_admin!)
    board
    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error"]).to eq("display_revoked")
    get "/waiting_room/board"
    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error"]).to eq("invalid_token")
    board("x" * 64)
    expect(json_body["error"]).to eq("invalid_token")
  end

  it "com 5 ou mais numa cor sai a mediana; UBS nunca tem tempos" do
    5.times { |i| travel_to((10 + i).minutes.ago) { arrived!(upa, patient: urgency_patient!(10 + i)).tap { |x| classified!(x, color: "green", by: nurse, pain_scale: 5) } } }
    board
    expect(json_body["wait_times"].find { |w| w["color"] == "green" }["median_minutes"]).to eq(12)
    expect(json_body["wait_times"].find { |w| w["color"] == "yellow" }["median_minutes"]).to eq("lt5_patients")
    ubs_token = paired_display!(create_unit("UBS TV")).last
    board(ubs_token)
    expect(response).to have_http_status(:ok)
    expect(json_body["wait_times"]).to be_nil
  end

  it "sem tempos quando a unidade ou a TV desliga show_wait_times" do
    hidden_token = paired_display!(upa, show_wait_times: false).last
    board(hidden_token)
    expect(json_body["wait_times"]).to be_nil
    board
    expect(json_body["wait_times"]).to be_an(Array)
    upa.update!(show_wait_times: false)
    board
    expect(json_body["wait_times"]).to be_nil
  end

  it "só as 8 chamadas mais recentes com senha dos últimos 30 min" do
    old = arrived!(upa, patient: urgency_patient!(30))
    travel_to(31.minutes.ago) { Attendances::CallRecord.record!(attendance: old.attendance, kind: "classification", location: room, by: nurse, enabled: true) }
    encounters = 9.times.map { |i| arrived!(upa, patient: urgency_patient!(40 + i)) }
    encounters.each_with_index do |x, i|
      travel_to((9 - i).minutes.ago) { Attendances::CallRecord.record!(attendance: x.attendance, kind: "classification", location: nil, by: nurse, enabled: true) }
    end
    board
    expect(json_body["calls"].size).to eq(8)
    expect(json_body["calls"].map { |c| c.keys.sort }.uniq).to eq([ %w[called_at kind location ticket] ])
    expect(json_body["calls"].map { |c| c["ticket"] }).to eq(encounters.drop(1).reverse.map { |x| x.attendance.ticket })
    expect(json_body["calls"].first).to include("location" => nil, "kind" => "classification")
    expect(json_body["calls"].map { |c| c["ticket"] }).not_to include(old.attendance.ticket)
  end

  it "grava last_seen_at no máximo a cada 60 s, sem mexer em updated_at" do
    display = pair.first
    board
    seen = display.reload.last_seen_at
    updated = display.updated_at
    expect(seen).to be_present
    travel 30.seconds do
      board
      expect(display.reload.last_seen_at).to eq(seen)
    end
    travel 61.seconds do
      board
      expect(display.reload.last_seen_at).to be > seen
      expect(display.updated_at).to eq(updated)
    end
  end

  it "limite de 30 leituras por minuto por token; interruptor desligado → 403 feature_disabled" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    30.times { board }
    expect(response).to have_http_status(:ok)
    board
    expect(response).to have_http_status(:too_many_requests)
    expect(json_body).to eq("error" => "too_many_requests")
    board(paired_display!(other_upa).last)
    expect(response).to have_http_status(:ok)

    Platform::Features.set!(city: city, key: WaitingRoom::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)
    board
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "waiting_room_display")
  end
end
