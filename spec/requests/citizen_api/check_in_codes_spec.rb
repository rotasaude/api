require "rails_helper"

RSpec.describe "Citizen check-in codes", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  it "gera o código para triagem própria elegível" do
    triage = completed_web_triage_for(citizen)
    sign_in_citizen("+5541998765432")

    json_post "/citizen/triages/#{triage.id}/check_in_code"
    expect(response).to have_http_status(:created)
    expect(body["code"]).to match(/\A\d{6}\z/)
    expect(body["expires_at"]).to be_present
  end

  it "triagem de outro celular: 404" do
    triage = completed_web_triage_for(citizen)
    sign_in_citizen("+5541911112222")

    json_post "/citizen/triages/#{triage.id}/check_in_code"
    expect(response).to have_http_status(:not_found)
  end

  it "triagem de 4 dias: 422 triage_too_old" do
    triage = completed_web_triage_for(citizen, completed_at: 4.days.ago)
    sign_in_citizen("+5541998765432")

    json_post "/citizen/triages/#{triage.id}/check_in_code"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("triage_too_old")
  end

  it "triagem com atendimento: 409 already_checked_in" do
    triage = completed_web_triage_for(citizen)
    unit = create_unit
    verifier = User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: "citizen_verifier", granted_at: Time.current)
    end
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
    Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                              by: verifier)
    sign_in_citizen("+5541998765432")

    json_post "/citizen/triages/#{triage.id}/check_in_code"
    expect(response).to have_http_status(:conflict)
    expect(body["error"]).to eq("already_checked_in")
  end

  it "limite de 10 por hora pela sessão" do
    # O cache do ambiente de teste é :null_store, que nunca conta; troca por um
    # real só aqui (mesmo padrão do teto de /graphql em maintenance).
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    triage = completed_web_triage_for(citizen)
    sign_in_citizen("+5541998765432")

    10.times { json_post "/citizen/triages/#{triage.id}/check_in_code" }
    json_post "/citizen/triages/#{triage.id}/check_in_code"
    expect(response).to have_http_status(:too_many_requests)
  end
end
