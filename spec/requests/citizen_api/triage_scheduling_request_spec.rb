require "rails_helper"

# Contratos §5: o resultado da triagem diz a unidade, o tipo e o prazo do
# pedido gerado (o texto é do wpda). Sem unidade, unit_name nulo; sem regra
# que case, scheduling_request nulo; nunca para outro par.
RSpec.describe "GET /citizen/triages/:id — scheduling_request", type: :request do
  before do
    Current.city = TEST_CITY_A
    ensure_appointment_types!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
  end
  after { Current.reset; Rails.cache.clear }

  let(:rule) { [ { "when" => { "gte" => ["outcome.score", 1] }, "appointment_type" => "consulta_medica", "priority" => "routine", "due_in_days" => 30 } ] }
  def body = JSON.parse(response.body)

  def finish(protocol_name, answer: "true")
    started = start_citizen_triage(protocol_name: protocol_name)
    json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: answer, idempotency_key: SecureRandom.uuid
    body.fetch("triage_id")
  end

  it "com e sem unidade; sem regra, null" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    triage_id = finish("saude-do-idoso")

    get "/citizen/triages/#{triage_id}"
    expect(body["scheduling_request"]).to eq("unit_name" => nil, "due_on" => (Time.zone.today + 30).iso8601,
                                             "appointment_type_name" => "Consulta médica")

    unit = create_unit("UBS Batel")
    AppointmentRequest.find_by!(origin_triage_id: triage_id).update!(target_unit: unit)
    get "/citizen/triages/#{triage_id}"
    expect(body["scheduling_request"]["unit_name"]).to eq("UBS Batel")

    # Sem regra de agendamento: a triagem concluída não gera pedido.
    active_protocol!("saude-mental")
    plain_id = finish("saude-mental")
    get "/citizen/triages/#{plain_id}"
    expect(response).to have_http_status(:ok)
    expect(body).to have_key("scheduling_request")
    expect(body["scheduling_request"]).to be_nil
  end

  it "triagem fundida mostra o pedido em que caiu" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    active_protocol!("saude-do-idoso-2", scheduling: rule)
    first_id = finish("saude-do-idoso")
    second_id = finish("saude-do-idoso-2")
    request = AppointmentRequest.find_by!(origin_triage_id: first_id)
    expect(request.request_triages.pluck(:triage_id)).to eq([ second_id ])

    get "/citizen/triages/#{second_id}"
    expect(body["scheduling_request"]).to include("appointment_type_name" => "Consulta médica")
  end

  it "tipo que a cidade não tem: o nome cai na chave" do
    active_protocol!("saude-do-idoso", scheduling: [ rule.first.merge("appointment_type" => "tipo_fora_do_catalogo") ])
    triage_id = finish("saude-do-idoso")
    get "/citizen/triages/#{triage_id}"
    expect(body["scheduling_request"]["appointment_type_name"]).to eq("tipo_fora_do_catalogo")
  end

  it "pedido encerrado não aparece" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    triage_id = finish("saude-do-idoso")
    json_post "/citizen/triages/#{triage_id}/revoke_consent"
    get "/citizen/triages/#{triage_id}"
    expect(body["scheduling_request"]).to be_nil
  end

  it "triagem de outro par do CPF verificado: null" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    mine = profiled_citizen!(age: 30, cpf: "52998224725")
    mine.update!(verification_level: "verified")
    other = profiled_citizen!(age: 70, cpf: "52998224725", phone: "+5541900000000")
    started = start_for!(other, "saude-do-idoso").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "true", idempotency_key: SecureRandom.uuid)
    expect(AppointmentRequest.where(origin_triage_id: started[:triage].id)).to exist

    get "/citizen/triages/#{started[:triage].id}"
    expect(response).to have_http_status(:ok)
    expect(body["scheduling_request"]).to be_nil
  end
end
