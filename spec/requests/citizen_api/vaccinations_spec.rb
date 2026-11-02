require "rails_helper"

# Módulo 29 (ADR 0047; contrato §9; §15 V11/V17, W1-W6): a caderneta do
# cidadão. Forma fixa, sem lote, vacinador nem dose cancelada; `rnds` é "sent"
# só com a entrada aceita; `upcoming` só com caderneta conferida.
RSpec.describe "Cidadão — caderneta de vacinação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-11-02 10:00:00") }
  let(:room) { vaccine_room! }

  before do
    travel_to(now)
    vaccination_city!
  end

  let(:pair) { exam_patient!(exam_seq!) }
  let(:patient) { pair.first }
  let(:citizen) { pair.last }

  def outbox!(immunization, status, **extra)
    attrs = { immunization: immunization, kind: "application", status: status, next_attempt_at: Time.current, deadline_at: 1.day.from_now }
    attrs[:accepted_at] = Time.current if status == "accepted"
    attrs[:block_reason] = "patient_without_cns_or_cpf" if status == "blocked"
    RndsOutboxEntry.create!(attrs.merge(extra))
  end

  def read!(id = citizen.id)
    sign_in_citizen(citizen.phone)
    get "/citizen/vaccinations", params: { citizen_id: id }
  end

  it "devolve a forma fixa: dose aplicada e transcrita, sem lote, vacinador nem cancelada" do
    sent = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-09-01 09:00:00"))
    outbox!(sent, "accepted")
    transcribed = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-06-15 08:00:00"), transcription: true, stock_lot: nil,
                                             lot_number_text: "LOTE-SECRETO-9", manufacturer_text: "Fabricante X", place_text: "UBS antiga")
    create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-08-01 08:00:00"), cancelled_at: Time.current,
                               cancelled_by_user: room_member!(room), cancel_reason: "Registrada na pessoa errada")

    read!

    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to eq(%w[checked items upcoming])
    expect(json_body["checked"]).to be(false)
    expect(json_body["items"].size).to eq(2)
    first, second = json_body["items"]
    expect(first.keys).to eq(%w[immunobiological_name dose_name applied_on place_name transcription rnds])
    expect(first).to include("applied_on" => "2026-09-01", "place_name" => room.health_unit.name, "transcription" => false, "rnds" => "sent",
                             "immunobiological_name" => Vaccination::Immunobiologicals.find("42").name)
    expect(second).to include("applied_on" => "2026-06-15", "place_name" => nil, "transcription" => true, "rnds" => "sending")
    expect(response.body).not_to include("LOTE-SECRETO", "Fabricante X", "UBS antiga", "Registrada na pessoa errada", transcribed.id)
    expect(response.body).not_to match(/lot|vaccinator|cancel/i)
  end

  it "items em applied_on decrescente" do
    dates = %w[2026-03-10 2026-09-20 2026-06-05]
    dates.each { |day| create_immunization!(room, patient: patient, applied_at: Time.zone.parse("#{day} 10:00:00")) }
    read!
    expect(json_body["items"].map { |i| i["applied_on"] }).to eq(%w[2026-09-20 2026-06-05 2026-03-10])
  end

  it "rnds é 'sent' só com a entrada aceita; pendente, enviando, bloqueada, recusada, falha e sem entrada são 'sending'" do
    accepted = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-01 10:00:00"))
    outbox!(accepted, "accepted")
    %w[pending sending blocked rejected failed].each_with_index do |status, index|
      record = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-09-#{10 + index} 10:00:00"))
      outbox!(record, status)
    end
    create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-08-01 10:00:00"))

    read!

    expect(json_body["items"].map { |i| i["rnds"] }).to eq(%w[sent] + %w[sending] * 6)
  end

  it "upcoming: sem conferência é vazio; com conferência traz as próximas doses (também com data passada) em due_on crescente" do
    patient.update_columns(birth_date: (now.to_date - 61).iso8601, sex: "female")
    read!
    expect(json_body["checked"]).to be(false)
    expect(json_body["upcoming"]).to eq([])

    VaccinationRecordCheck.create!(patient: patient, mode: "confirmed_complete", checked_by_user: room_member!(room), vaccine_room: room, checked_at: Time.current)
    read!

    expect(json_body["checked"]).to be(true)
    upcoming = json_body["upcoming"]
    expect(upcoming).not_to be_empty
    expect(upcoming.first.keys).to eq(%w[immunobiological_name dose_name due_on])
    dates = upcoming.map { |u| u["due_on"] }
    expect(dates.compact).to eq(dates.compact.sort)
    expect(dates).to eq(dates.compact + dates.select(&:nil?)) # nulas, se houver, no fim
    expect(dates.compact).to all(match(/\A\d{4}-\d{2}-\d{2}\z/))
    expect(dates.compact.min).to be <= now.to_date.iso8601 # dose devida: data passada é permitida (W6)
    expect(response.body).not_to match(/atrasad/i)
  end

  it "upcoming não repete a dose que já foi aplicada" do
    patient.update_columns(birth_date: (now.to_date - 61).iso8601, sex: "female")
    VaccinationRecordCheck.create!(patient: patient, mode: "confirmed_complete", checked_by_user: room_member!(room), vaccine_room: room, checked_at: Time.current)
    read!
    before = json_body["upcoming"].map { |u| [ u["immunobiological_name"], u["dose_name"] ] }
    penta = [ Vaccination::Immunobiologicals.find("42").name, Vaccination::Terminologies.name("dose", "1") ]
    expect(before).to include(penta)

    create_immunization!(room, patient: patient, applied_at: Time.current)
    read!
    expect(json_body["upcoming"].map { |u| [ u["immunobiological_name"], u["dose_name"] ] }).not_to include(penta)
  end

  it "paciente sem registro de vacina: caderneta vazia e a trilha citizen é gravada uma vez" do
    events = []
    allow(DomainEvents).to receive(:publish).and_wrap_original { |m, *args, **kw| events << [ args.first, kw ]; m.call(*args, **kw) }
    read!
    expect(json_body).to eq("checked" => false, "items" => [], "upcoming" => [])
    viewed = events.select { |name, _| name == "clinical_record.viewed" }
    expect(viewed.size).to eq(1)
    expect(viewed.first.last).to include(patient_id: patient.id, access: "citizen")
  end

  it "par só declarado: 403 not_verified" do
    declared = profiled_citizen!(age: 30, phone: "+5541990000124")
    sign_in_citizen(declared.phone)
    get "/citizen/vaccinations", params: { citizen_id: declared.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "not_verified")
  end

  it "pessoa de outro celular: 404" do
    other = exam_patient!(exam_seq!).last
    sign_in_citizen(citizen.phone)
    get "/citizen/vaccinations", params: { citizen_id: other.id }
    expect(response).to have_http_status(:not_found)
  end

  it "sem sessão: 401" do
    get "/citizen/vaccinations", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:unauthorized)
  end

  it "interruptor desligado: 403 feature_disabled e some de features da sessão; ligado aparece" do
    sign_in_citizen(citizen.phone)
    get "/citizen/session"
    expect(json_body["features"]).to include("vaccination")

    Platform::Features.set!(city: Current.city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/vaccinations", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "vaccination")
    get "/citizen/session"
    expect(json_body["features"]).not_to include("vaccination")
  end
end
