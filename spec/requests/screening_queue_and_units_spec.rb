require "rails_helper"

# Contratos §3–§5: fila do acolhimento, fila do profissional com cor (a
# recepção só vê cor, destino e espera), detalhe da chamada e escopo da unidade.
RSpec.describe "Filas com escuta e escopo da unidade", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  def body = JSON.parse(response.body)

  def screened!(n, color)
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(n), checked_in_at: 15.minutes.ago)
    screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: screening,
                              revision_params: revision_params(final_color: color, complaint_note: "MARCADOR-QUEIXA",
                                                               vitals: { "systolic" => 150, "diastolic" => 95 }),
                              destination: "same_day", destination_params: {}, by: nurse)
    attendance
  end

  it "fila do acolhimento para a recepção: quem espera escuta, por chegada" do
    waiting = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    screened!(2, "green")
    sign_in_as(reception!)
    get "/attendance/units/#{unit.id}/screening_queue"
    expect(response).to have_http_status(:ok)
    expect(body["items"].map { |i| i["attendance_id"] }).to eq([ waiting.id ])
    expect(body["items"].first.keys).to match_array(%w[attendance_id citizen checked_in_at triage_priority screening])
  end

  it "fila do profissional: vermelho no topo; a recepção recebe só cor, destino e espera" do
    freeze_time do
      plain = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: 1.hour.ago)
      red = screened!(2, "red")
      sign_in_as(reception!)
      get "/attendance/units/#{unit.id}/queue"
      expect(body["waiting"].map { |i| i["id"] }).to eq([ red.id, plain.id ])
      expect(body["waiting"].first["screening"])
        .to eq("id" => red.screening.id, "color" => "red", "destination" => "same_day", "waited_minutes" => 15)
      expect(body["waiting"].last["screening"]).to be_nil
      expect(response.body).not_to include("MARCADOR-QUEIXA", "systolic", "complaint")
    end
  end

  # Contrato §9: quem ainda aguarda acolhimento vem por último "e marcado".
  it "fila do profissional marca quem aguarda acolhimento (fora do escopo e com escuta concluída não)" do
    awaiting = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(2))
    green = screened!(3, "green")
    in_progress = walk_in_attendance!(unit, citizen: screening_citizen!(4))
    Screenings::Start.call(attendance: in_progress, by: nurse)
    sign_in_as(reception!)
    get "/attendance/units/#{unit.id}/queue"
    flags = body["waiting"].to_h { |i| [ i["id"], i["awaiting_screening"] ] }
    expect(flags).to eq(green.id => false, scheduled.id => false, awaiting.id => true, in_progress.id => true)
    expect(body["waiting"].last(2).map { |i| i["id"] }).to contain_exactly(awaiting.id, in_progress.id)
  end

  it "o detalhe da chamada traz a escuta para o profissional e deixa trilha" do
    red = screened!(1, "red")
    doctor = screener!(unit, cbo: "225125")
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{red.id}/call", health_unit_id: unit.id
    expect(response).to have_http_status(:ok)
    expect(body.dig("attendance", "screening", "current_revision", "final_color")).to eq("red")
    expect(DomainEvent.where(name: "screening.viewed").pluck(:payload))
      .to eq([ { "screening_id" => red.screening.id, "user_id" => doctor.id } ])
  end

  it "chamar o próximo traz a escuta concluída (com trilha); sem escuta concluída, null e sem trilha" do
    plain = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: 1.hour.ago)
    yellow = screened!(2, "yellow")
    doctor = screener!(unit, cbo: "225125")
    sign_in_as(doctor)
    json_post "/attendance/units/#{unit.id}/call_next"
    expect([ body.dig("attendance", "id"), body.dig("attendance", "screening", "id") ]).to eq([ yellow.id, yellow.screening.id ])
    json_post "/attendance/units/#{unit.id}/call_next"
    expect(body["attendance"]).to include("id" => plain.id, "screening" => nil)
    expect(DomainEvent.where(name: "screening.viewed").pluck(:payload))
      .to eq([ { "screening_id" => yellow.screening.id, "user_id" => doctor.id } ])
  end

  it "o admin muda o escopo; valor inválido 422; as listas devolvem o campo" do
    admin = staff_with("admin-escopo@cidade.gov.br", "municipal_admin")
    sign_in_as(admin)
    json_post "/attendance/units/#{unit.id}", name: unit.name, kind: unit.kind, screening_scope: "all"
    expect(response).to have_http_status(:ok)
    expect(body.dig("unit", "screening_scope")).to eq("all")
    json_post "/attendance/units/#{unit.id}", name: unit.name, kind: unit.kind, screening_scope: "todos"
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_screening_scope" ])
    json_post "/attendance/units/#{unit.id}", name: unit.name, kind: unit.kind
    expect(unit.reload.screening_scope).to eq("all")
    get "/attendance/units/all"
    expect(body["units"].first).to include("screening_scope" => "all")
    sign_in_as(nurse)
    get "/attendance/units"
    expect(body["units"].first).to include("screening_scope" => "all")
  end
end
