require "rails_helper"

# Contratos §5, §8.
RSpec.describe "Meus horários (agenda)", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit.tap { |u| u.update!(address_street: "Rua XV de Novembro", address_number: "100", address_zip: "80020310") } }
  let(:link) { doctor_link!(unit) }
  let(:shift) { shift!(link, starts_at: 4.days.from_now.change(hour: 8)) }
  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  it "lista pedido e horário com os campos novos; pede outro horário; 409 na segunda vez" do
    request = triage_request!(citizen, unit: unit)
    appointment = appointment_row!(request, shift, starts_at: shift.starts_at)
    request.update!(status: "scheduled")
    orphan = triage_request!(citizen, unit: nil, type_key: "retorno")
    sign_in_citizen("+5541998765432")

    get "/citizen/appointments", params: { citizen_id: citizen.id }
    items = body["appointments"].index_by { |i| i.dig("request", "id") }
    expect(items[orphan.id]["request"]).to include("kind" => "triage", "target_unit_name" => nil,
                                                   "appointment_type_name" => "Retorno",
                                                   "due_on" => orphan.due_on.iso8601)
    expect(items[orphan.id]["appointment"]).to be_nil
    expect(items[request.id]["appointment"]).to include(
      "id" => appointment.id, "appointment_type_name" => "Consulta médica",
      "professional_name" => link.professional.professional_name, "ends_at" => appointment.ends_at.iso8601,
      "can_request_reschedule" => true,
      "unit" => { "name" => unit.name, "address" => { "street" => "Rua XV de Novembro", "number" => "100",
                                                      "complement" => nil, "zip" => "80020310" } }
    )

    json_post "/citizen/appointments/#{appointment.id}/reschedule_request",
              reason_code: "work", note: "entro às 7h", preferred_period: "afternoon"
    expect(response).to have_http_status(:ok)
    expect(body["appointment"]).to include("id" => appointment.id, "status" => "cancelled_by_citizen",
                                           "can_request_reschedule" => false)

    get "/citizen/appointments", params: { citizen_id: citizen.id }
    reopened = body["appointments"].find { |i| i.dig("request", "id") == request.id }["request"]
    expect(reopened).to include("status" => "open", "reopened_reason" => nil)

    json_post "/citizen/appointments/#{appointment.id}/reschedule_request", reason_code: "work", preferred_period: "any"
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "not_reschedulable")
  end

  it "horário de outro celular: 404; motivo inválido: 422" do
    request = triage_request!(citizen, unit: unit)
    appointment = appointment_row!(request, shift, starts_at: shift.starts_at)
    sign_in_citizen("+5541911112222")
    json_post "/citizen/appointments/#{appointment.id}/reschedule_request", reason_code: "work", preferred_period: "any"
    expect(response).to have_http_status(:not_found)

    sign_in_citizen("+5541998765432")
    json_post "/citizen/appointments/#{appointment.id}/reschedule_request", reason_code: "ferias", preferred_period: "any"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_reason_code")
    expect(appointment.reload.status).to eq("confirmed")
  end
end
