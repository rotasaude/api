require "rails_helper"

# Contrato §5: prestadores da cidade, itens com prazos próprios, token FHIR
# mostrado uma vez (só o hash fica), revogação e convite do usuário do portal.
RSpec.describe "Prestadores de exames (admin)", type: :request do
  before { exam_city! }

  let(:item) { exam_catalog_item! }
  let(:body) { { name: "Laboratório Central", cnes: "2345678", kind: "accredited", active: true,
                 items: [ { catalog_item_id: item.id, deadlines: { "result" => 5 } } ] } }

  before { stepped_up!(municipal_admin!) }

  it "cria com itens, gira e revoga o token, convida o usuário do portal" do
    json_post "/exams/admin/providers", body
    expect(response).to have_http_status(:created)
    provider = ExamProvider.find(json_body["id"])
    expect(json_body["items"]).to eq([ { "catalog_item_id" => item.id, "sigtap_code" => item.sigtap_code,
                                         "deadlines" => { "authorize" => nil, "schedule" => nil, "collect" => nil,
                                                          "result" => 5, "acknowledge" => nil } } ])
    expect(json_body).to include("simulated" => false, "has_fhir_token" => false)

    json_post "/exams/admin/providers/#{provider.id}/fhir_token"
    token = json_body["token"]
    expect(token.length).to be >= 40
    expect(provider.reload.fhir_token_digest).to eq(Digest::SHA256.hexdigest(token))
    expect(ExamProvider.by_token(token)).to eq(provider)
    expect(DomainEvent.where(name: "exam_provider.fhir_token_rotated").order(:occurred_at, :created_at).last.payload).to eq("exam_provider_id" => provider.id)
    expect(DomainEvent.all.map { |e| e.payload.to_json }.join).not_to include(token)

    json_post "/exams/admin/providers/#{provider.id}/fhir_token"
    expect(ExamProvider.by_token(token)).to be_nil
    json_delete "/exams/admin/providers/#{provider.id}/fhir_token"
    expect(response).to have_http_status(:no_content)
    expect(provider.reload.fhir_token_active?).to be(false)

    json_post "/exams/admin/providers/#{provider.id}/users", email: "Lab@Central.com.br"
    expect(response).to have_http_status(:created)
    expect(json_body).to include("email" => "lab@central.com.br", "role" => "exam_provider")
    expect(Invitation.find(json_body["id"])).to have_attributes(exam_provider_id: provider.id)
  end

  it "recusa nome repetido, tipo, CNES e item inexistente; a API nunca cria simulado" do
    json_post "/exams/admin/providers", body.merge(simulated: true)
    expect(ExamProvider.find(json_body["id"]).simulated).to be(false)
    { { name: "laboratório central" } => "duplicate_name", { kind: "hospital" } => "invalid_kind",
      { cnes: "12345" } => "invalid_cnes", { name: " " } => "invalid_name",
      { items: [ { catalog_item_id: SecureRandom.uuid } ] } => "invalid_items",
      { items: [ { catalog_item_id: item.id, deadlines: { "result" => 400 } } ] } => "invalid_deadline" }.each do |over, error|
      json_post "/exams/admin/providers", body.merge(over)
      expect([ response.status, json_body["error"] ]).to eq([ 422, error ]), over.inspect
    end
  end
end
