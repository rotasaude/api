# spec/requests/citizen_api/start_by_name_spec.rb
require "rails_helper"

# Contratos §3.5 (ADR 0027): POST /citizen/conversations exige protocol_name e
# perfil, e confere a oferta.
RSpec.describe "Início de triagem por nome", type: :request do
  before do
    create_default_protocol!
    active_protocol!("saude-do-idoso", offer: { "eligibility" => { "gte" => ["profile.age", 60] } })
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  def start(params) = json_post("/citizen/conversations", { consent_version: "1" }.merge(params))

  let(:admin) { staff_with("catalogo-#{SecureRandom.hex(3)}@cidade.gov.br") }

  it "sem protocol_name: 422 protocol_name_required, antes de gravar o CPF" do
    expect { start(cpf: "529.982.247-25") }.not_to change(Citizen, :count)
    expect(status_and_error).to eq([ 422, "protocol_name_required" ])
    [ "", 1, [ "x" ] ].each do |value|
      start(cpf: "529.982.247-25", protocol_name: value)
      expect(status_and_error).to eq([ 422, "protocol_name_required" ]), value.inspect
    end
  end

  it "par sem perfil: 409 profile_required" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    start(citizen_id: citizen.id, protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME)
    expect(status_and_error).to eq([ 409, "profile_required" ])
  end

  # ADR 0023 / LGPD: bairro inválido é recusado antes de resolve_citizen, que
  # criaria o par (com o CPF) para um CPF novo.
  it "CPF novo com neighborhood_id inválido: 422 invalid_neighborhood e nenhum CPF gravado" do
    expect do
      start(cpf: "529.982.247-25", protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME, neighborhood_id: SecureRandom.uuid)
    end.not_to change(Citizen, :count)
    expect(status_and_error).to eq([ 422, "invalid_neighborhood" ])
    expect(Citizen.where(cpf: "52998224725")).to be_empty
  end

  # Desvio 12: o caminho por cpf continua, mas o par novo nasce sem perfil.
  # O par (celular + CPF) FICA gravado, sem perfil, como o RegisterPerson faz;
  # nenhuma conversa nem triagem.
  it "CPF novo pelo caminho de compatibilidade: 409 profile_required, par gravado sem perfil" do
    expect do
      start(cpf: "529.982.247-25", protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME)
    end.to change(Citizen, :count).by(1)
    expect([ Conversation.count, Triage.count ]).to eq([ 0, 0 ])
    expect(status_and_error).to eq([ 409, "profile_required" ])
    citizen = Citizen.find_by!(cpf: "52998224725", phone: "+5541998765432")
    expect(citizen.profile?).to be(false)
  end

  it "não oferecido e triagem em andamento: 409" do
    TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin)
    neto = profiled_citizen!(age: 8, sex: "male")
    start(citizen_id: neto.id, protocol_name: "saude-do-idoso")
    expect(status_and_error).to eq([ 409, "not_offered" ])

    start(citizen_id: neto.id, protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME)
    expect(response).to have_http_status(:created)
    start(citizen_id: neto.id, protocol_name: "outro-qualquer")
    expect(status_and_error).to eq([ 409, "triage_in_progress" ])
  end

  it "protocolo pausado: not_offered" do
    TriageOffer.create!(protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME, enabled: false, updated_by_user: admin)
    par = profiled_citizen!(age: 30)
    start(citizen_id: par.id, protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME)
    expect(status_and_error).to eq([ 409, "not_offered" ])
  end
end
