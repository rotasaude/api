require "rails_helper"

# ADR 0028 (spec 2026-10-05 §7; contratos §5.4): consulta ao CADSUS no balcão,
# atrás do interruptor. Do CADSUS só ficam o CNS (depois de o atendente
# confirmar a validação) e a marca da conferência.
RSpec.describe "CADSUS na validação presencial", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:verifier) { staff_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:maintainer) do
    Maintainer.create!(email_address: "cad-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:profile) { { birth_date: "1963-04-02", sex: "female" } }
  def json = JSON.parse(response.body)

  def switch_on! = Platform::Features.set!(city: city, key: "cadsus_lookup", enabled: true, maintainer: maintainer)

  def credential!(username = "rota")
    IntegrationCredential.create!(kind: "cadsus", secret: { "username" => username, "password" => "x" },
                                  set_by_user: admin, set_at: Time.current)
  end

  def lookup(person = citizen, code = issue_code_for(person))
    json_post "/attendance/cadsus_lookup", cpf: person.cpf, code: code
    code
  end

  def verify(code, **extra)
    json_post "/attendance/verifications", { cpf: citizen.cpf, code: code, document_checked: true }.merge(profile).merge(extra)
  end

  it "interruptor desligado: 403 feature_disabled e o CADSUS não é chamado" do
    credential!
    sign_in_as(verifier)
    expect(Cadsus::Client).not_to receive(:for)
    lookup
    expect([ response.status, json ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "cadsus_lookup" } ])
  end

  it "ligado sem credencial ou com credencial recusada: 503 cadsus_unavailable; a recusa marca a credencial" do
    switch_on!
    sign_in_as(verifier)
    lookup
    expect([ response.status, json ]).to eq([ 503, { "error" => "cadsus_unavailable" } ])
    credential!(Cadsus::Simulated::REFUSED_USERNAME)
    lookup
    expect(response).to have_http_status(:service_unavailable)
    expect(IntegrationCredential.find_by!(kind: "cadsus").last_check_status).to eq("unauthorized")
  end

  it "achado: CNS mascarado, comparação nula sem perfil, nada de CPF; pendente gravado, CNS ainda não" do
    switch_on!
    credential!
    sign_in_as(verifier)
    lookup
    expect(response).to have_http_status(:ok)
    expect(json.keys).to match_array(%w[found cns_masked birth_date_matches sex_matches])
    expect(json).to include("found" => true, "birth_date_matches" => nil, "sex_matches" => nil)
    expect(json["cns_masked"]).to match(/\A\*\*\* \*\*\*\* \*\*\*\* \d{4}\z/)
    expect(response.body).not_to include("52998224725")
    citizen.reload
    expect(citizen.cns).to be_nil
    expect(citizen.cadsus_pending_cns).to be_present
    expect(DomainEvent.where(name: "citizen.cadsus_looked_up").map(&:payload))
      .to eq([ { "citizen_id" => citizen.id, "user_id" => verifier.id, "found" => true } ])
  end

  it "compara nascimento e sexo com o perfil declarado do cidadão (ADR 0027), sem gravar os do CADSUS" do
    switch_on!
    credential!
    sign_in_as(verifier)
    found = Cadsus::Simulated.new(username: "rota").lookup(citizen.cpf)
    other_sex = found.sex == "female" ? "male" : "female"

    citizen.update!(birth_date: found.birth_date.iso8601, sex: found.sex, profile_source: "declared")
    lookup
    expect(json).to include("found" => true, "birth_date_matches" => true, "sex_matches" => true)

    citizen.update!(birth_date: (found.birth_date + 1).iso8601, sex: other_sex)
    lookup
    expect(json).to include("birth_date_matches" => false, "sex_matches" => false)
    expect(citizen.reload.birth_date).to eq((found.birth_date + 1).iso8601)
    expect(citizen.sex).to eq(other_sex)
  end

  it "não achado e fora do ar; código errado segue os erros do lookup" do
    switch_on!
    credential!
    sign_in_as(verifier)
    lookup(Citizen.create!(cpf: Cadsus::Simulated::NOT_FOUND_CPF, phone: "+5541998765433"))
    expect(json).to eq("found" => false, "cns_masked" => nil, "birth_date_matches" => nil, "sex_matches" => nil)
    lookup(Citizen.create!(cpf: Cadsus::Simulated::UNAVAILABLE_CPF, phone: "+5541998765434"))
    expect([ response.status, json ]).to eq([ 503, { "error" => "cadsus_unavailable" } ])
    issue_code_for(citizen)
    json_post "/attendance/cadsus_lookup", cpf: citizen.cpf, code: "000000"
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_code" } ])
    json_post "/attendance/cadsus_lookup", cpf: "123", code: "000000"
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_cpf" } ])
  end

  it "validação com cadsus_confirmed grava CNS e a marca, e limpa o pendente" do
    switch_on!
    credential!
    sign_in_as(verifier)
    code = lookup
    pending = citizen.reload.cadsus_pending_cns
    verify(code, cadsus_confirmed: true)
    expect(response).to have_http_status(:created)
    citizen.reload
    expect(citizen.cns).to eq(pending)
    expect(citizen.cadsus_checked_at).to be_present
    expect([ citizen.cadsus_pending_cns, citizen.cadsus_pending_session_id, citizen.cadsus_pending_at ]).to eq([ nil, nil, nil ])
    expect(citizen).to be_verification_level_verified
  end

  # Review Focus 5.
  it "consulta vencida ou de outra sessão: 409, nada validado, código intacto" do
    switch_on!
    credential!
    sign_in_as(verifier)
    lookup
    travel 12.minutes do
      # O código da consulta venceu (TTL de 10 min); o cidadão gera outro e
      # volta ao balcão — a consulta ao CADSUS já não vale.
      fresh = issue_code_for(citizen)
      verify(fresh, cadsus_confirmed: true)
      expect([ response.status, json ]).to eq([ 409, { "error" => "cadsus_lookup_missing" } ])
    end
    expect(citizen.reload).to be_verification_level_declared

    code = issue_code_for(citizen)

    lookup(citizen, code)
    sign_in_as(verifier)
    verify(code, cadsus_confirmed: true)
    expect([ response.status, json ]).to eq([ 409, { "error" => "cadsus_lookup_missing" } ])
    expect(citizen.reload).to be_verification_level_declared

    verify(code)
    expect(response).to have_http_status(:created)
    expect(citizen.reload.cns).to be_nil
  end
end
