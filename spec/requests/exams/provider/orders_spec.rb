require "rails_helper"

# Contrato §6 (F-21.6): o prestador só vê e mexe nas guias dele (404 para a
# de outro, sem distinguir de inexistente); nunca prontuário; atrasos no cabeçalho.
RSpec.describe "Portal do prestador", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:unit) { create_unit("UBS Portal") }
  let(:doctor) { doctor!(unit) }
  let(:item) { exam_catalog_item! }
  let(:mine) { exam_provider!(name: "Lab A").tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:theirs) { exam_provider!(name: "Lab B").tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:lab_user) do
    staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: mine, user: u) }
  end

  def scheduled_for(provider, n, at: Time.current)
    travel_to(at) do
      order = exam_order!(patient: exam_patient!(n).first, unit: unit, requester: doctor)
      Exams::Steps.schedule(order: order, actor_user: doctor,
                            params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
      order.reload
    end
  end

  it "lista só as guias do prestador, com nome, nascimento e 3 dígitos do CPF; atrasos no cabeçalho" do
    own = scheduled_for(mine, 80)
    late = scheduled_for(mine, 81, at: 40.days.ago)
    other = scheduled_for(theirs, 82)
    sign_in_as(lab_user)
    get "/exams/provider/orders"
    expect(json_body["orders"].map { |o| o["id"] }).to contain_exactly(own.id, late.id)
    expect(response.headers["X-Overdue-Count"]).to eq("1")
    row = json_body["orders"].find { |o| o["id"] == own.id }
    expect(row["patient"].keys).to eq(%w[name birth_date cpf_last3])
    expect(row["result_fields"].map { |f| f["key"] }).to eq(%w[hba1c])
    expect(json_body["overdue_count"]).to eq(1)
    expect(row["patient"]["cpf_last3"]).to eq(own.patient.cpf[-3, 3])
    expect(response.body).not_to include(own.patient.cpf)
    json_post "/exams/provider/orders/#{other.id}/collect"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/exams/provider/orders/#{SecureRandom.uuid}/collect"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/exams/provider/orders/#{own.id}/collect"
    expect(json_body["status"]).to eq("collected")
    expect(own.reload.events.last).to have_attributes(kind: "collected", actor_user_id: lab_user.id, actor_provider_id: mine.id) # A35
  end

  it "agenda a guia autorizada para ele; nunca lê pedido pelas rotas da unidade" do
    authorized = travel_to(1.hour.ago) { exam_order!(patient: exam_patient!(83).first, unit: unit, requester: doctor) }
    ApplicationRecord.transaction do
      authorized.lock!
      ExamOrderEvent.create!(exam_order: authorized, kind: "authorized", actor_user: doctor, occurred_at: Time.current)
      authorized.update!(exam_provider_id: mine.id)
    end
    sign_in_as(lab_user)
    json_post "/exams/provider/orders/#{authorized.id}/schedule", scheduled_at: 2.days.from_now.iso8601, scheduled_place: "Lab A, sala 2"
    expect(json_body).to include("status" => "scheduled", "scheduled_place" => "Lab A, sala 2")
    expect(authorized.reload.events.last).to have_attributes(kind: "scheduled", actor_user_id: lab_user.id, actor_provider_id: mine.id) # A35
    get "/exams/orders/#{authorized.id}"
    expect(response).to have_http_status(:not_found)
    get "/exams/orders", params: { unit_id: unit.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "sem vínculo a prestador: 403 missing_role" do
    sign_in_as(staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider"))
    get "/exams/provider/orders"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
  end

  it "prestador simulado sem fake_lab utilizável: 403 feature_disabled, sem tocar na guia" do
    own = scheduled_for(mine, 84)
    mine.update!(simulated: true)
    sign_in_as(lab_user)
    get "/exams/provider/orders"
    expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "fake_lab" ])
    json_post "/exams/provider/orders/#{own.id}/collect"
    expect(response).to have_http_status(:forbidden)
    expect(own.reload.status).to eq("scheduled")
  end

  # A35: a unidade vê o prestador como ator; o funcionário do laboratório só na trilha (banco).
  it "a visão da unidade mostra o ator prestador, nunca o funcionário" do
    own = scheduled_for(mine, 85)
    sign_in_as(lab_user)
    json_post "/exams/provider/orders/#{own.id}/collect"
    expect(own.reload.events.last).to have_attributes(actor_user_id: lab_user.id, actor_provider_id: mine.id)
    sign_in_as(doctor)
    get "/exams/orders/#{own.id}"
    expect(json_body["events"].last).to include("kind" => "collected", "actor" => { "type" => "provider", "name" => "Lab A" })
    expect(response.body).not_to include(lab_user.email_address)
  end
end
