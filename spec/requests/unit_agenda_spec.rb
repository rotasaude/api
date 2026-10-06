require "rails_helper"

RSpec.describe "GET /attendance/units/:id/agenda (por profissional)", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:reception) { staff_with("recepcao-agenda@cidade.gov.br", "citizen_verifier") }
  let(:day) { Time.zone.today + 4 }
  let(:template) do
    ScheduleTemplate.create!(name: "Manhã", fit_in_limit: 3, blocks: [
      { "starts" => "07:00", "ends" => "08:00", "kind" => "walk_in" },
      { "starts" => "08:00", "ends" => "09:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica" }
    ])
  end
  let(:shift) { shift!(link, starts_at: day.in_time_zone.change(hour: 7), ends_at: day.in_time_zone.change(hour: 11), template: template) }
  let(:cpfs) { %w[52998224725 11144477735 39053344705] }
  def citizen(i) = Citizen.create!(cpf: cpfs[i], phone: "+55419#{format('%08d', 50_000_000 + i)}")
  def body = JSON.parse(response.body)

  it "turnos com faixas e contador de encaixe, horários por profissional, livres sem profissional" do
    slot = appointment_row!(triage_request!(citizen(0), unit: unit), shift, starts_at: shift.starts_at + 1.hour)
    fit = appointment_row!(triage_request!(citizen(1), unit: unit), shift, starts_at: shift.starts_at + 1.hour,
                           kind: "fit_in", reason: "gestante com dor")
    other = triage_request!(citizen(2), unit: unit)
    legacy = Appointment.create!(request: other, citizen: other.citizen, health_unit: unit,
                                 scheduled_at: shift.starts_at + 3.hours, scheduled_by_user: reception,
                                 status: "confirmed", confirmed_at: Time.current)

    sign_in_as(reception)
    get "/attendance/units/#{unit.id}/agenda", params: { date: day.iso8601 }
    expect(response).to have_http_status(:ok)
    pro = body["professionals"].sole
    expect(pro).to include("id" => link.professional_id, "name" => link.professional.professional_name)
    expect(pro["shifts"].sole).to eq(
      "shift_id" => shift.id, "starts_at" => shift.starts_at.iso8601, "ends_at" => shift.ends_at.iso8601,
      "cancelled_at" => nil, "fit_in_count" => 1, "fit_in_limit" => 3,
      "blocks" => [ { "starts" => "07:00", "ends" => "08:00", "kind" => "walk_in" },
                    { "starts" => "08:00", "ends" => "09:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica",
                      "appointment_type_name" => "Consulta médica" } ]
    )
    expect(pro["appointments"].map { |a| a["id"] }).to contain_exactly(slot.id, fit.id)
    expect(pro["appointments"].find { |a| a["id"] == fit.id }["fit_in_reason"]).to eq("gestante com dor")
    expect(body["unassigned"].map { |a| [ a["id"], a["booking_kind"] ] }).to eq([ [ legacy.id, "legacy" ] ])
    expect(body["appointments"].map { |a| a["id"] }).to contain_exactly(slot.id, fit.id, legacy.id)
  end

  it "turno cancelado e modelo editado: o horário fica, marcado (Review Focus 3)" do
    slot = appointment_row!(triage_request!(citizen(0), unit: unit), shift, starts_at: shift.starts_at + 1.hour)
    template.update!(blocks: [ { "starts" => "07:00", "ends" => "11:00", "kind" => "walk_in" } ])
    shift.update!(cancelled_at: Time.current, cancelled_by_user: reception, cancel_reason: "troca de escala")

    sign_in_as(reception)
    get "/attendance/units/#{unit.id}/agenda", params: { date: day.iso8601 }
    pro = body["professionals"].sole
    expect(pro["shifts"].sole["cancelled_at"]).to be_present
    expect(pro["appointments"].sole).to include("id" => slot.id, "status" => "confirmed", "outside_template" => true,
                                               "shift_cancelled" => true, "scheduled_at" => slot.scheduled_at.iso8601)
  end

  it "turno sem modelo que cruza a meia-noite: uma faixa bookable do tipo resolvido, recortada em 24:00 e 00:00" do
    night = shift!(link, starts_at: day.in_time_zone.change(hour: 20), ends_at: (day + 1).in_time_zone.change(hour: 2))
    sign_in_as(reception)
    get "/attendance/units/#{unit.id}/agenda", params: { date: day.iso8601 }
    expect(body["professionals"].sole["shifts"].sole).to include(
      "shift_id" => night.id, "fit_in_count" => 0, "fit_in_limit" => Scheduling::FitInLimit.for(night),
      "blocks" => [ { "starts" => "20:00", "ends" => "24:00", "kind" => "bookable",
                      "appointment_type_key" => "consulta_medica", "appointment_type_name" => "Consulta médica" } ]
    )
    get "/attendance/units/#{unit.id}/agenda", params: { date: (day + 1).iso8601 }
    expect(body["professionals"].sole["shifts"].sole["blocks"]).to eq(
      [ { "starts" => "00:00", "ends" => "02:00", "kind" => "bookable",
          "appointment_type_key" => "consulta_medica", "appointment_type_name" => "Consulta médica" } ]
    )
  end

  it "turno sem modelo de CBO que nenhum tipo atende: nenhuma faixa" do
    tech = link_professional!(staff_with("tecnica-agenda@cidade.gov.br", "health_professional"), unit, cbo: "322205")
    shift!(tech, starts_at: day.in_time_zone.change(hour: 8))
    sign_in_as(reception)
    get "/attendance/units/#{unit.id}/agenda", params: { date: day.iso8601 }
    expect(body["professionals"].sole["shifts"].sole["blocks"]).to eq([])
  end
end
