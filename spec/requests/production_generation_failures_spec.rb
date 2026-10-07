require "rails_helper"

# Contratos §6 (ADR 0030; spec §5): fichas que não puderam ser geradas e
# "gerar de novo" (step-up, só municipal_admin).
RSpec.describe "Produção — fichas não geradas", type: :request do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:admin) do
    staff_with("prod-admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  before do
    Current.city = TEST_CITY_A
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    allow(Ledi::DeliverJob).to receive(:perform_later)
    ciap2_release!
  end
  after { Current.reset }

  def failed_screening!
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    attendance = walk_in_attendance!(unit, citizen: citizen)
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    Ledi::ScreeningFicha.generate(started.reload, city: city)
    [ started, citizen ]
  end

  it "lista as não resolvidas com o atendimento e os motivos; resolved=true lista as resolvidas" do
    screening, = failed_screening!
    sign_in_as(admin)
    get "/production/generation_failures", params: { resolved: "false" }
    expect(response).to have_http_status(:ok)
    item = body["items"].sole
    expect(item.keys).to match_array(%w[id source_type source_id attendance_id reason_codes created_at resolved_at])
    expect(item.values_at("source_type", "source_id", "attendance_id", "resolved_at"))
      .to eq([ "Screening", screening.id, screening.attendance_id, nil ])
    expect(item["reason_codes"]).to include("unit_without_cnes", "citizen_without_sex")
    get "/production/generation_failures"
    expect(body["items"].size).to eq(1)
    get "/production/generation_failures", params: { resolved: "true" }
    expect(body["items"]).to eq([])
  end

  it "gerar de novo: step-up; ainda faltando atualiza os motivos; corrigido resolve e a ficha nasce; de novo 409" do
    screening, citizen = failed_screening!
    failure = LediGenerationFailure.sole
    sign_in_as(admin)
    json_post "/production/generation_failures/#{failure.id}/retry"
    expect(status_and_error).to eq([ 401, "mfa_required" ])

    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    exportable_unit!(unit, nurse)
    json_post "/production/generation_failures/#{failure.id}/retry"
    expect(response).to have_http_status(:ok)
    expect(body.values_at("reason_codes", "resolved_at")).to eq([ %w[citizen_without_birth_date citizen_without_sex], nil ])

    citizen.update!(birth_date: "1980-05-10", sex: "female", profile_source: "declared")
    json_post "/production/generation_failures/#{failure.id}/retry"
    expect(body["resolved_at"]).to be_present
    expect(LediOutboxEntry.where(source_id: screening.id).count).to eq(1)
    expect(DomainEvent.where(name: "ledi.generation_retried").count).to eq(2)
    json_post "/production/generation_failures/#{failure.id}/retry"
    expect(status_and_error).to eq([ 409, "already_resolved" ])
    json_post "/production/generation_failures/#{SecureRandom.uuid}/retry"
    expect(status_and_error).to eq([ 404, "not_found" ])
  end

  it "analyst lê e não tenta de novo; viewer 403; interruptor desligado 403" do
    failed_screening!
    sign_in_as(staff_with("analista@cidade.gov.br", "analyst")).update!(mfa_verified_at: Time.current)
    get "/production/generation_failures"
    expect(response).to have_http_status(:ok)
    json_post "/production/generation_failures/#{LediGenerationFailure.sole.id}/retry"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    sign_in_as(staff_with("viewer@cidade.gov.br", "viewer"))
    get "/production/generation_failures"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    ledi_off!(city)
    sign_in_as(admin)
    get "/production/generation_failures"
    expect(status_and_error).to eq([ 403, "feature_disabled" ])
  end
  # Contratos §9: "Reenviar" de ficha de escuta recusada devolve a ficha NOVA
  # (mesmo formato do GET /production); regenerar duas vezes → not_rejected.
  it "reenviar ficha de escuta recusada: 200 com a nova; de novo 409; identificação quebrada e exportação inutilizável 409" do
    exportable_unit!(unit, nurse)
    citizen = screening_citizen!(1)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    Ledi::ScreeningFicha.generate(started.reload, city: city)
    rejected = LediOutboxEntry.sole.tap { |e| e.reject!([ { "field" => "cpfCidadao", "code" => "invalid" } ]) }
    sign_in_as(admin).update!(mfa_verified_at: Time.current)

    unit.update!(cnes: nil)
    json_post "/production/fichas/#{rejected.id}/resend"
    expect(status_and_error).to eq([ 409, "generation_failed" ])
    unit.update!(cnes: "1234567")

    json_post "/production/fichas/#{rejected.id}/resend"
    expect(response).to have_http_status(:ok)
    expect(body.keys).to match_array(%w[id ficha_type status attempts last_error_codes replaces_outbox_id created_at
                                        accepted_at])
    expect(body.values_at("status", "replaces_outbox_id")).to eq([ "pending", rejected.id ])
    expect(body["id"]).not_to eq(rejected.id)
    fresh = LediOutboxEntry.find(body["id"])
    expect(fresh.uuid).not_to eq(rejected.uuid)

    json_post "/production/fichas/#{rejected.id}/resend"
    expect(status_and_error).to eq([ 409, "not_rejected" ])

    fresh.reject!([ { "field" => "cpfCidadao", "code" => "invalid" } ])
    city.update!(record_mode: "off")
    json_post "/production/fichas/#{fresh.id}/resend"
    expect(status_and_error).to eq([ 409, "export_unusable" ])
  end
end
