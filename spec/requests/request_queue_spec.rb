require "rails_helper"

# Contratos §4.1, §9, §10; spec §5.3: ordem por atraso, prazo e prioridade;
# marcas; fila sem unidade; detalhe com a nota (só ali).
RSpec.describe "Fila de pedidos (agenda)", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ensure_appointment_types!; sign_in_as(reception) }
  after { Current.reset }

  let(:reception) { staff_with("recepcao-fila@cidade.gov.br", "citizen_verifier") }
  let(:unit) { create_unit }
  let(:cpfs) { %w[52998224725 11144477735 39053344705 87748248800 15350946056] }
  def citizen(i) = Citizen.create!(cpf: cpfs[i], phone: "+55419#{format('%08d', 60_000_000 + i)}")
  def body = JSON.parse(response.body)
  let(:today) { Time.zone.today }

  it "ordena atrasados, depois prazo, depois prioridade; marca e mostra a origem" do
    late = triage_request!(citizen(0), unit: unit, due_on: today - 1)
    soon_routine = triage_request!(citizen(1), unit: unit, due_on: today + 5)
    soon_priority = triage_request!(citizen(2), unit: unit, due_on: today + 5, priority: "priority")
    later = triage_request!(citizen(3), unit: unit, due_on: today + 20, priority: "priority")

    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"].map { |r| r["id"] }).to eq([ late.id, soon_priority.id, soon_routine.id, later.id ])
    first = body["requests"].first
    expect(first).to include("kind" => "triage", "origin" => "triage", "origin_unit_name" => nil, "overdue" => true,
                             "appointment_type_key" => "consulta_medica", "appointment_type_name" => "Consulta médica",
                             "priority" => "routine", "due_on" => (today - 1).iso8601, "reschedule_requested" => false,
                             "reschedule_count" => 0, "needs_reschedule" => false, "appointment" => nil,
                             "target_unit_id" => unit.id, "triage_priority" => late.root_triage.priority)
    expect(body["requests"].second).to include("overdue" => false, "priority" => "priority")
    expect(first).not_to have_key("reschedule_note")
  end

  it "remarcação pedida pelo cidadão: reschedule_requested, reopened_reason nulo; expired passa" do
    asked = triage_request!(citizen(0), unit: unit)
    asked.update!(reopened_reason: "citizen_reschedule", reschedule_reason_code: "work", preferred_period: "morning",
                  reschedule_count: 1)
    expired = triage_request!(citizen(1), unit: unit, type_key: "consulta_enfermagem")
    expired.update!(reopened_reason: "expired")

    get "/attendance/units/#{unit.id}/requests"
    rows = body["requests"].index_by { |r| r["id"] }
    expect(rows[asked.id]).to include("reschedule_requested" => true, "reopened_reason" => nil,
                                      "reschedule_reason_code" => "work", "preferred_period" => "morning",
                                      "reschedule_count" => 1)
    expect(rows[expired.id]).to include("reschedule_requested" => false, "reopened_reason" => "expired")
  end

  it "pedido marcado em turno cancelado volta à fila como needs_reschedule, com o horário" do
    link = doctor_link!(unit)
    shift = shift!(link, starts_at: (today + 3).in_time_zone.change(hour: 8))
    req = triage_request!(citizen(0), unit: unit)
    appointment = appointment_row!(req, shift, starts_at: shift.starts_at)
    req.update!(status: "scheduled")
    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"]).to eq([])

    shift.update!(cancelled_at: Time.current, cancelled_by_user: reception, cancel_reason: "troca de escala")
    get "/attendance/units/#{unit.id}/requests"
    row = body["requests"].sole
    expect(row).to include("id" => req.id, "needs_reschedule" => true, "overdue" => false)
    expect(row["appointment"]).to include("id" => appointment.id, "shift_cancelled" => true)
  end

  it "pedido marcado numa vaga que o modelo editado tirou volta à fila como needs_reschedule" do
    template = ScheduleTemplate.create!(name: "Manhã", blocks: [ { "starts" => "08:00", "ends" => "09:00",
                                                                   "kind" => "bookable",
                                                                   "appointment_type_key" => "consulta_medica" } ])
    shift = shift!(doctor_link!(unit), starts_at: (today + 3).in_time_zone.change(hour: 8), template: template)
    req = triage_request!(citizen(0), unit: unit)
    appointment = appointment_row!(req, shift, starts_at: shift.starts_at)
    req.update!(status: "scheduled")
    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"]).to eq([])

    template.update!(blocks: [ { "starts" => "08:00", "ends" => "09:00", "kind" => "walk_in" } ])
    get "/attendance/units/#{unit.id}/requests"
    row = body["requests"].sole
    expect(row).to include("id" => req.id, "needs_reschedule" => true)
    expect(row["appointment"]).to include("id" => appointment.id, "outside_template" => true, "shift_cancelled" => false)
  end

  it "fila sem unidade, atribuição (duas vezes = 409) e detalhe com a nota" do
    orphan = triage_request!(citizen(4), unit: nil)
    orphan.update!(reschedule_note: "trabalho de manhã")
    get "/attendance/requests/unassigned"
    expect(body["requests"].map { |r| r["id"] }).to eq([ orphan.id ])
    expect(body["requests"].first).not_to have_key("reschedule_note")

    get "/attendance/requests/#{orphan.id}"
    expect(body).to include("id" => orphan.id, "reschedule_note" => "trabalho de manhã", "target_unit_id" => nil)

    json_post "/attendance/requests/#{orphan.id}/assign_unit", unit_id: unit.id
    expect(response).to have_http_status(:ok)
    expect(body).to include("id" => orphan.id, "target_unit_id" => unit.id)
    expect(body).not_to have_key("reschedule_note")
    json_post "/attendance/requests/#{orphan.id}/assign_unit", unit_id: unit.id
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "already_assigned")

    get "/attendance/requests/unassigned"
    expect(body["requests"]).to eq([])
  end

  it "atribuição: unidade inválida 422, pedido inexistente 404; detalhe inexistente 404" do
    orphan = triage_request!(citizen(4), unit: nil)
    json_post "/attendance/requests/#{orphan.id}/assign_unit", unit_id: "x"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_unit")
    json_post "/attendance/requests/#{SecureRandom.uuid}/assign_unit", unit_id: unit.id
    expect(response).to have_http_status(:not_found)
    get "/attendance/requests/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
  end

  it "sem papel de recepção: 403 nas rotas novas" do
    orphan = triage_request!(citizen(4), unit: nil)
    sign_in_as(staff_with("medica-sem-fila@cidade.gov.br", "health_professional"))
    get "/attendance/requests/unassigned"
    expect(response).to have_http_status(:forbidden)
    get "/attendance/requests/#{orphan.id}"
    expect(response).to have_http_status(:forbidden)
    json_post "/attendance/requests/#{orphan.id}/assign_unit", unit_id: unit.id
    expect(response).to have_http_status(:forbidden)
    expect(orphan.reload.target_unit_id).to be_nil
  end

  it "pedido de retorno: origem atendimento, tipo retorno, prazo de 30 dias" do
    doctor = staff_with("medica-fila@cidade.gov.br", "health_professional")
    link_professional!(doctor, unit)
    a = in_care!(waiting_attendance(citizen(0), unit: unit, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: "reavaliar", by: doctor)
    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"].sole).to include("origin" => "attendance", "origin_unit_name" => unit.name,
                                             "appointment_type_key" => "retorno", "priority" => "routine",
                                             "due_on" => (today + 30).iso8601)
  end
end
