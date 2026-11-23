require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7, §10, Q30): POST
# /zoonoses/euthanasias, só da veterinária e com step-up (401 mfa_required).
# Não há rota de edição nem de exclusão (404). A resposta traz `{ veterinarian:
# { name, crmv } }` do perfil profissional (CRMV-<UF> <número>) e nunca a nota.
# POST /zoonoses/neuterings, só da veterinária, sem step-up.
RSpec.describe "Zoonoses — eutanásia e castração", type: :request do
  let!(:city) { zoonoses_city! }
  let(:vet) { veterinarian! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }
  let(:note) { "Sofrimento intenso sem possibilidade de tratamento." }

  def body(animal, **over)
    { animal_id: animal.id, performed_on: today.iso8601, reason: "untreatable_suffering", reason_note: note,
      legal_basis: %w[cfmv_1000_2012] }.merge(over)
  end

  def euthanize(fields, query: "") = post("/zoonoses/euthanasias#{query}", params: fields.to_json, headers: headers)

  it "sem step-up → 401 mfa_required, nada gravado" do
    animal = animal!
    sign_in_as(step_up_enrolled!(vet))
    euthanize(body(animal))
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(Euthanasia.where(animal_id: animal.id)).to be_empty
  end

  it "PATCH/DELETE não existem (404)" do
    euthanasia = euthanasia!(animal: animal!, by: vet)
    stepped_up!(vet)
    patch "/zoonoses/euthanasias/#{euthanasia.id}", params: { reason: "other" }.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    delete "/zoonoses/euthanasias/#{euthanasia.id}", params: "{}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/zoonoses/euthanasias/#{euthanasia.id}"
    expect(response).to have_http_status(:not_found)
    expect(euthanasia.reload.reason).to eq("untreatable_suffering")
  end

  it "a resposta traz o nome e o CRMV da veterinária, nunca a nota" do
    animal = animal!
    stepped_up!(vet)
    euthanize(body(animal))
    expect(response).to have_http_status(:created)
    professional = vet.professional
    expect(json_body).to include("animal_id" => animal.id, "performed_on" => today.iso8601, "reason" => "untreatable_suffering",
                                 "legal_basis" => %w[cfmv_1000_2012],
                                 "veterinarian" => { "name" => professional.professional_name,
                                                     "crmv" => "CRMV-PR #{professional.registration_number}" })
    expect(response.body).not_to include("Sofrimento")

    euthanize(body(animal))
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_euthanized" } ])
    euthanize(body(animal!, reason_note: "curta"))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason_note" } ])
    euthanize(body(animal!), query: "?animal_id=#{animal.id}")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "equipe sem o perfil, com step-up → 403 veterinarian_required; fora da equipe → 403 missing_role" do
    stepped_up!(zoonoses_team!)
    euthanize(body(animal!))
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "veterinarian_required" } ])

    stepped_up!(staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    euthanize(body(animal!))
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "castração: a veterinária → 201 com o CRMV; a equipe → 403 veterinarian_required" do
    animal = animal!
    sign_in_as(zoonoses_team!)
    post "/zoonoses/neuterings", params: { animal_id: animal.id, performed_on: today.iso8601 }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "veterinarian_required" } ])

    sign_in_as(vet)
    post "/zoonoses/neuterings", params: { animal_id: animal.id, performed_on: today.iso8601 }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    expect(json_body).to include("animal_id" => animal.id, "performed_on" => today.iso8601,
                                 "veterinarian" => { "name" => vet.professional.professional_name,
                                                     "crmv" => "CRMV-PR #{vet.professional.registration_number}" })
    post "/zoonoses/neuterings", params: { animal_id: animal.id, performed_on: today.iso8601 }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
  end
end
