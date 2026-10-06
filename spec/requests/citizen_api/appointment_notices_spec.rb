# spec/requests/citizen_api/appointment_notices_spec.rb
require "rails_helper"

# Contratos §5, §8: a caixa une campanhas e lembretes; o id é opaco e a
# leitura vale para os dois.
RSpec.describe "Caixa de avisos com lembretes", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:phone) { "+5541998765432" }
  let!(:ana) { person!(phone: phone, cpf: "52998224725") }
  let(:unit) { create_unit.tap { |u| u.update!(address_street: "Rua das Flores", address_number: "10") } }
  let(:link) { doctor_link!(unit) }
  let(:shift) { shift!(link, starts_at: 2.days.from_now.change(hour: 8)) }
  def body = JSON.parse(response.body)

  def reminder!(citizen, at: 30.minutes.ago)
    appointment = appointment_row!(triage_request!(citizen, unit: unit), shift,
                                   starts_at: shift.starts_at + (AppointmentNotice.count * 20).minutes)
    AppointmentNotice.create!(appointment: appointment, citizen: citizen, created_at: at)
  end

  it "une as duas fontes, mais novo primeiro, com a forma do lembrete; conta e marca lido nas duas" do
    campaign = recipient!(sent_campaign!(title: "Vacinação", dispatched_at: 2.hours.ago), ana, sms_status: "not_opted_in")
    notice = reminder!(ana)
    sign_in_citizen(phone)

    get "/citizen/notices"
    expect(body["notices"].map { |n| [ n["kind"], n["id"] ] })
      .to eq([ [ "appointment_reminder", notice.id ], [ "campaign", campaign.id ] ])
    expect(body["notices"].first).to eq(
      "kind" => "appointment_reminder", "id" => notice.id, "appointment_id" => notice.appointment_id,
      "appointment_type_name" => "Consulta médica", "unit_name" => unit.name,
      "unit_address" => { "street" => "Rua das Flores", "number" => "10", "complement" => nil, "zip" => nil },
      "scheduled_at" => notice.appointment.scheduled_at.iso8601,
      "professional_name" => link.professional.professional_name, "read" => false, "cpf_masked" => nil
    )
    expect(body["unread_count"]).to eq(2)

    json_post "/citizen/notices/#{notice.id}/read"
    expect(response).to have_http_status(:ok)
    first_read = notice.reload.read_at
    expect(first_read).to be_present
    json_post "/citizen/notices/#{notice.id}/read"
    expect(response).to have_http_status(:ok)
    expect(notice.reload.read_at).to eq(first_read)
    get "/citizen/notices"
    expect(body["unread_count"]).to eq(1)
    expect(body["notices"].first["read"]).to be(true)
    expect(body["notices"].last["read"]).to be(false)
  end

  it "duas pessoas no celular: cpf_masked; quem silenciou não conta; aviso de outro celular é 404" do
    bia = person!(phone: phone, cpf: "11144477735")
    reminder!(ana)
    reminder!(bia, at: 1.hour.ago)
    CitizenContactPreference.create!(citizen_id: bia.id, notices_muted: true)
    stranger = reminder!(person!, at: 2.hours.ago)
    sign_in_citizen(phone)

    get "/citizen/notices"
    expect(body["notices"].map { |n| n["cpf_masked"] }).to eq([ ana.cpf_masked, bia.cpf_masked ])
    expect(body["unread_count"]).to eq(1)
    json_post "/citizen/notices/#{stranger.id}/read"
    expect(response).to have_http_status(:not_found)
    expect(stranger.reload.read_at).to be_nil
  end
end
