# spec/requests/booking_spec.rb
require "rails_helper"

# Contratos §4.3, §9: três formas de marcar; health_unit_id nas três.
RSpec.describe "POST /attendance/requests/:id/appointments (agenda)", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:reception) { staff_with("recepcao-marca@cidade.gov.br", "citizen_verifier") }
  let(:day) { Time.zone.today + 5 }
  let!(:shift) { shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 10)) }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:req) { triage_request!(citizen, unit: unit) }
  def body = JSON.parse(response.body)

  def slot_body(at = shift.starts_at)
    { kind: "slot", health_unit_id: unit.id, professional_id: link.professional_id, starts_at: at.iso8601,
      appointment_type_key: "consulta_medica" }
  end

  before { sign_in_as(reception) }

  it "vaga: 201 com o horário na forma única; remarcar move o anterior" do
    json_post "/attendance/requests/#{req.id}/appointments", slot_body
    expect(response).to have_http_status(:created)
    first_id = body.dig("appointment", "id")
    expect(body["appointment"]).to include("booking_kind" => "slot", "status" => "scheduled", "shift_id" => shift.id,
                                           "appointment_type_name" => "Consulta médica", "fit_in" => false,
                                           "professional" => { "id" => link.professional_id,
                                                               "name" => link.professional.professional_name },
                                           "citizen" => { "id" => citizen.id, "cpf_masked" => citizen.cpf_masked })
    expect(body["appointment"]).to have_key("confirmation_deadline_at")
    expect(body["appointment"]).not_to have_key("fit_in_reason")

    json_post "/attendance/requests/#{req.id}/appointments", slot_body(shift.starts_at + 40.minutes)
    expect(response).to have_http_status(:created)
    expect(Appointment.find(first_id).status).to eq("moved")
    expect(DomainEvent.where(name: "appointment.moved").map { |e| e.payload["from_appointment_id"] }).to eq([ first_id ])
  end

  it "encaixe: 201 com a justificativa visível para a recepção; justificativa curta 422 invalid_reason" do
    json_post "/attendance/requests/#{req.id}/appointments",
              slot_body.merge(kind: "fit_in", shift_id: shift.id, reason: "curta")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_reason")
    json_post "/attendance/requests/#{req.id}/appointments",
              slot_body(shift.starts_at + 5.minutes).merge(kind: "fit_in", shift_id: shift.id, reason: "gestante com dor")
    expect(response).to have_http_status(:created)
    expect(body["appointment"]).to include("booking_kind" => "fit_in", "fit_in" => true, "fit_in_reason" => "gestante com dor")
  end

  it "livre: em dia com turno 409 use_slots; em dia sem turno (e sem kind) marca como hoje" do
    json_post "/attendance/requests/#{req.id}/appointments",
              kind: "legacy", health_unit_id: unit.id, scheduled_at: shift.starts_at.change(hour: 14).iso8601
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "use_slots")

    json_post "/attendance/requests/#{req.id}/appointments",
              health_unit_id: unit.id, scheduled_at: (shift.starts_at + 1.day).change(hour: 14).iso8601
    expect(response).to have_http_status(:created)
    expect(body["appointment"]).to include("booking_kind" => "legacy", "ends_at" => nil, "professional" => nil,
                                           "appointment_type_key" => nil, "appointment_type_name" => nil,
                                           "shift_id" => nil, "status" => "scheduled")
    expect(body["appointment"]["confirmation_deadline_at"]).to be_present
  end

  it "livre com o cidadão ocupado no mesmo horário (outra unidade): 409 citizen_busy" do
    other_unit = create_unit("UBS Sul")
    other_shift = shift!(doctor_link!(other_unit), starts_at: (day + 1).in_time_zone.change(hour: 14))
    appointment_row!(triage_request!(citizen, unit: other_unit, type_key: "consulta_enfermagem"), other_shift,
                     starts_at: other_shift.starts_at)
    json_post "/attendance/requests/#{req.id}/appointments",
              kind: "legacy", health_unit_id: unit.id, scheduled_at: (other_shift.starts_at + 10.minutes).iso8601
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "citizen_busy")
    expect(req.reload.status).to eq("open")
  end

  it "unidade diferente da do pedido: 422 wrong_unit; vaga fora da grade 409; kind desconhecido 422" do
    json_post "/attendance/requests/#{req.id}/appointments", slot_body.merge(health_unit_id: create_unit("UBS Sul").id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "wrong_unit")
    json_post "/attendance/requests/#{req.id}/appointments", slot_body(shift.starts_at + 5.minutes)
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "slot_unavailable")
    json_post "/attendance/requests/#{req.id}/appointments", slot_body.merge(kind: "grupo")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_kind")
  end

  it "pedido inexistente: 404" do
    json_post "/attendance/requests/#{SecureRandom.uuid}/appointments", slot_body
    expect(response).to have_http_status(:not_found)
  end

  it "violação da trava vira 409 slot_taken (nunca 500)" do
    slot = Scheduling::Availability.for(unit: unit, from: day, to: day, appointment_type: AppointmentType.find_by!(key: "consulta_medica")).first
    appointment_row!(triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit), shift,
                     starts_at: shift.starts_at)
    allow(Scheduling::Availability).to receive(:for).and_return([ slot ])
    json_post "/attendance/requests/#{req.id}/appointments", slot_body
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "slot_taken")
  end
end
