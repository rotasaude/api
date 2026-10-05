require "rails_helper"

# Contratos §3.4 e Review Focus 2: pares que dividem celular ou CPF não se
# enxergam; sem perfil, 409.
RSpec.describe "Catálogo do cidadão", type: :request do
  before do
    create_default_protocol!
    active_protocol!("saude-do-idoso", offer: { "title" => "Saúde do idoso", "eligibility" => { "gte" => ["profile.age", 60] } })
    active_protocol!("saude-mental", offer: { "title" => "Saúde mental" })
    # Protocolo com elegibilidade só entra em oferta com linha no catálogo.
    TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: staff_with("cat-#{SecureRandom.hex(3)}@cidade.gov.br"))
    sign_in_citizen("+5541998765432")
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  def catalog_of(citizen) = get("/citizen/people/#{citizen.id}/catalog")
  def names(section) = body[section].map { |i| i["protocol_name"] }

  it "dois pares no mesmo celular: avó e neto com catálogos diferentes" do
    avo = profiled_citizen!(age: 62)
    neto = profiled_citizen!(age: 8, sex: "male", cpf: CampaignHistory.cpf_for("neto"))
    catalog_of(avo)
    expect(names("available")).to eq(%w[saude-do-idoso saude-mental triage-respiratoria])
    expect(body).to include("in_progress" => nil, "suggested" => [], "recent" => [], "reference_units" => [])
    catalog_of(neto)
    expect(names("available")).to eq(%w[saude-mental triage-respiratoria])
  end

  it "mesmo CPF em dois celulares: perfil e sugestão não cruzam" do
    mine = profiled_citizen!(age: 30, cpf: "52998224725")
    other = profiled_citizen!(age: 62, cpf: "52998224725", phone: "+5541900000000")
    TriageSuggestion.create!(citizen: other, source_triage: completed_triage!(other, "saude-mental"), protocol_name: "saude-do-idoso")
    catalog_of(mine)
    expect(body["suggested"]).to eq([])
    expect(names("available")).not_to include("saude-do-idoso")
    catalog_of(other)
    expect(status_and_error).to eq([ 404, "not_found" ])
  end

  it "sem perfil: 409 profile_required" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    catalog_of(citizen)
    expect(status_and_error).to eq([ 409, "profile_required" ])
  end
end
