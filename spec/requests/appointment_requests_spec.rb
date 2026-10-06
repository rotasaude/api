require "rails_helper"

RSpec.describe "Appointment requests", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; Rails.cache.clear; link_professional!(doctor, unit) }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  def returned_attendance(priority: 5, of: citizen)
    a = in_care!(waiting_attendance(of, unit: unit, by: reception), by: doctor)
    a.triage.update_columns(priority: priority)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: "reavaliar",
                            by: doctor).payload.fetch(:appointment_request)
  end

  it "lista pedidos abertos da unidade, marca horário e aparece na agenda do dia" do
    req = returned_attendance
    sign_in_as(reception)

    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"].first).to include("id" => req.id, "kind" => "return", "cpf_masked" => citizen.cpf_masked,
                                              "priority" => 5, "note" => "reavaliar", "reopened_reason" => nil)

    at = 3.days.from_now.change(hour: 14, min: 30)
    json_post "/attendance/requests/#{req.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    expect(body["appointment"]).to include("status" => "scheduled")

    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"]).to eq([])

    get "/attendance/units/#{unit.id}/agenda", params: { date: at.to_date.iso8601 }
    expect(body["appointments"].first).to include("cpf_masked" => citizen.cpf_masked, "kind" => "return",
                                                  "status" => "scheduled")
  end

  it "horário ocupado: 409 slot_taken com quantos; com allow_overlap marca o encaixe" do
    at = 3.days.from_now.change(hour: 14, min: 0)
    first = returned_attendance
    Appointments::Schedule.call(request: first, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception)
    # Outro cidadão: o mesmo cidadão no mesmo instante seria citizen_busy (ADR 0029).
    second = returned_attendance(of: Citizen.create!(cpf: "11144477735", phone: "+5541911112222"))
    sign_in_as(reception)

    json_post "/attendance/requests/#{second.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "slot_taken", "taken" => 1)

    json_post "/attendance/requests/#{second.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id,
                                                                allow_overlap: "true"
    expect(response).to have_http_status(:conflict) # só o booleano true libera

    json_post "/attendance/requests/#{second.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id,
                                                                allow_overlap: true
    expect(response).to have_http_status(:created)
  end

  it "profissional não marca horário (403)" do
    req = returned_attendance
    sign_in_as(doctor)
    json_post "/attendance/requests/#{req.id}/appointments", scheduled_at: 3.days.from_now.iso8601,
                                                             health_unit_id: unit.id
    expect(response).to have_http_status(:forbidden)
  end

  it "encerra pedido com justificativa" do
    req = returned_attendance
    sign_in_as(reception)
    json_post "/attendance/requests/#{req.id}/dismiss", reason: "cidadão mudou de cidade", health_unit_id: unit.id
    expect(response).to have_http_status(:ok)
    json_post "/attendance/requests/#{req.id}/dismiss", reason: "curto", health_unit_id: unit.id
    expect(response).to have_http_status(:conflict)
  end

  it "justificativa curta num pedido aberto: 422 e o pedido segue aberto" do
    req = returned_attendance
    sign_in_as(reception)
    json_post "/attendance/requests/#{req.id}/dismiss", reason: "curto", health_unit_id: unit.id
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("reason_too_short")
    expect(req.reload.status).to eq("open")
  end

  it "remarcar depois de expirar cria um horário novo; o antigo não muda" do
    req = returned_attendance
    old = Appointments::Schedule.call(request: req, scheduled_at: 3.days.from_now.iso8601, health_unit_id: unit.id,
                                      by: reception).payload.fetch(:appointment)
    Appointments::Lapse.call(appointment: old, to: "expired", now: old.confirmation_deadline_at)
    expect(req.reload).to have_attributes(status: "open", reopened_reason: "expired")
    snapshot = old.reload.attributes

    sign_in_as(reception)
    at = 5.days.from_now.change(hour: 9, min: 0)
    json_post "/attendance/requests/#{req.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    expect(body["appointment"]["id"]).not_to eq(old.id)
    expect(old.reload.attributes).to eq(snapshot)
    expect(req.reload).to have_attributes(status: "scheduled", reopened_reason: nil)
    expect(req.appointments.count).to eq(2)
    expect(DomainEvent.where(name: "appointment.scheduled").count).to eq(2)
  end

  describe "agenda do dia" do
    let(:other_unit) { create_unit("UPA Norte", kind: "upa") }

    def schedule_at(at)
      travel_to(at - 1.hour) do
        Appointments::Schedule.call(request: returned_attendance, scheduled_at: at.iso8601, health_unit_id: unit.id,
                                    by: reception).payload.fetch(:appointment)
      end
    end

    it "usa o dia da cidade: 23h30 locais entram no dia, não no seguinte" do
      late = schedule_at(Time.zone.parse("2026-10-02 23:30"))
      sign_in_as(reception)
      get "/attendance/units/#{unit.id}/agenda", params: { date: "2026-10-02" }
      expect(body["appointments"].map { |a| a["id"] }).to eq([ late.id ])
      get "/attendance/units/#{unit.id}/agenda", params: { date: "2026-10-03" }
      expect(body["appointments"]).to eq([])
    end

    it "data inválida cai no dia de hoje" do
      travel_to(Time.zone.parse("2026-10-02 08:00")) do
        today = Appointments::Schedule.call(request: returned_attendance,
                                            scheduled_at: Time.zone.parse("2026-10-02 15:00").iso8601,
                                            health_unit_id: unit.id, by: reception).payload.fetch(:appointment)
        sign_in_as(reception)
        get "/attendance/units/#{unit.id}/agenda", params: { date: "ontem" }
        expect(response).to have_http_status(:ok)
        expect(body["appointments"].map { |a| a["id"] }).to eq([ today.id ])
      end
    end

    it "não mostra horários de outra unidade" do
      mine = schedule_at(Time.zone.parse("2026-10-02 10:00"))
      sign_in_as(reception)
      get "/attendance/units/#{unit.id}/agenda", params: { date: "2026-10-02" }
      expect(body["appointments"].map { |a| a["id"] }).to eq([ mine.id ])
      get "/attendance/units/#{other_unit.id}/agenda", params: { date: "2026-10-02" }
      expect(body["appointments"]).to eq([])
    end

    it "profissional não vê a agenda nem a fila de pedidos (403)" do
      sign_in_as(doctor)
      get "/attendance/units/#{unit.id}/agenda"
      expect(response).to have_http_status(:forbidden)
      get "/attendance/units/#{unit.id}/requests"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
