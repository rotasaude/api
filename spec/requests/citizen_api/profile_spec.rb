require "rails_helper"

# Contratos §3.1–§3.3 (ADR 0027): o par nasce com perfil; o perfil declarado se
# corrige; o verificado não muda pelo canal do cidadão.
RSpec.describe "Perfil do par", type: :request do
  before do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }

  def create_person(**params)
    json_post "/citizen/people", { cpf: "529.982.247-25", consent_version: "1", birth_date: "1963-04-02",
                                   sex: "female" }.merge(params)
  end

  describe "POST /citizen/people" do
    it "cria o par com perfil e bairro: 201 e a pessoa no formato de GET /citizen/people" do
      create_person(gender_identity: "cis_woman", neighborhood_id: centro.id)
      expect(response).to have_http_status(:created)
      expect(body["person"]).to include(
        "cpf_masked" => "***.982.247-**", "verification_level" => "declared",
        "neighborhood" => { "id" => centro.id, "name" => "Centro" },
        "profile" => { "birth_date" => "1963-04-02", "sex" => "female", "gender_identity" => "cis_woman",
                       "profile_source" => "declared" }
      )
      expect(DomainEvent.where(name: "citizen.profile_changed").sole.payload).to eq("citizen_id" => body.dig("person", "id"))

      get "/citizen/people"
      expect(body["people"].sole["profile"]).to include("birth_date" => "1963-04-02")
    end

    it "par já existente: 200 e o perfil não é sobrescrito" do
      create_person
      create_person(birth_date: "1990-01-01", sex: "male")
      expect(response).to have_http_status(:ok)
      expect(body.dig("person", "profile")).to include("birth_date" => "1963-04-02", "sex" => "female")
      expect(Citizen.count).to eq(1)
    end

    it "termo desatualizado: 409 antes de gravar qualquer coisa" do
      expect { create_person(consent_version: "0") }.not_to change(Citizen, :count)
      expect(status_and_error).to eq([ 409, "consent_outdated" ])
    end

    it "valores inválidos: 422 com o motivo e nenhum CPF gravado" do
      {
        { cpf: "111.111.111-11" } => "invalid_cpf",
        { birth_date: "2999-01-01" } => "invalid_birth_date",
        { sex: "x" } => "invalid_sex",
        { gender_identity: "x" } => "invalid_gender_identity",
        { neighborhood_id: SecureRandom.uuid } => "invalid_neighborhood"
      }.each do |params, error|
        expect { create_person(**params) }.not_to change(Citizen, :count)
        expect(status_and_error).to eq([ 422, error ]), params.inspect
      end
    end

    it "teto de pessoas por celular: 422 too_many_people" do
      Citizen::MAX_PER_PHONE.times { |i| Citizen.create!(cpf: CampaignHistory.cpf_for("teto-#{i}"), phone: "+5541998765432") }
      create_person
      expect(status_and_error).to eq([ 422, "too_many_people" ])
    end
  end

  describe "POST /citizen/people/:id/profile" do
    let!(:person) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

    it "grava o perfil declarado; gender_identity null apaga" do
      json_post "/citizen/people/#{person.id}/profile", birth_date: "1963-04-02", sex: "female", gender_identity: "cis_woman"
      expect(response).to have_http_status(:ok)
      json_post "/citizen/people/#{person.id}/profile", birth_date: "1963-04-02", sex: "female", gender_identity: nil
      expect(body.dig("person", "profile")).to eq("birth_date" => "1963-04-02", "sex" => "female",
                                                  "gender_identity" => nil, "profile_source" => "declared")
    end

    it "verificado: 409 profile_verified" do
      person.update!(birth_date: "1963-04-02", sex: "female", profile_source: "verified")
      json_post "/citizen/people/#{person.id}/profile", birth_date: "1970-01-01", sex: "female", gender_identity: nil
      expect(status_and_error).to eq([ 409, "profile_verified" ])
    end

    it "valor inválido: 422; par de outro celular: 404" do
      json_post "/citizen/people/#{person.id}/profile", birth_date: "1963-04-02", sex: "outro", gender_identity: nil
      expect(status_and_error).to eq([ 422, "invalid_sex" ])
      other = Citizen.create!(cpf: "52998224725", phone: "+5541900000000")
      json_post "/citizen/people/#{other.id}/profile", birth_date: "1963-04-02", sex: "female", gender_identity: nil
      expect(status_and_error).to eq([ 404, "not_found" ])
    end
  end

  it "GET /citizen/people: profile null sem perfil" do
    Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    get "/citizen/people"
    expect(body["people"].sole["profile"]).to be_nil
  end
end
