require "rails_helper"

# Spec §5.10–§5.11 e §4 (GAL): entrega do impresso (quem retirou e quando),
# situação por número; número do GAL registrado uma vez no exame do 21a.
RSpec.describe "Laboratório — entrega e GAL", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:staff) { lab_staff! }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }

  it "entrega só com laudo liberado; situação delivered; quem retirou cifrado" do
    item = type!(req.items.first, { glicose: "98" })
    sign_in_as(staff)
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "Maria (a própria)"
    expect(json_body["error"]).to eq("invalid_transition")
    Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead)
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "   "
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_delivered_to" ])
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "x" * 121
    expect(json_body["error"]).to eq("invalid_delivered_to")
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "Maria (a própria)"
    expect(json_body).to include("status" => "delivered", "delivered_to" => "Maria (a própria)")
    expect(req.reload.read_attribute_before_type_cast("delivered_to")).not_to include("Maria")
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "Outra pessoa"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
    get "/lab/requisitions", params: { number: req.number }
    expect(json_body["requisitions"].sole["status"]).to eq("delivered")
    expect(DomainEvent.where(name: "lab_requisition.delivered").sole.payload.keys).to contain_exactly("lab_requisition_id")
  end

  it "entrega recusa quem não é do laboratório nem da unidade" do
    item = type!(req.items.first, { glicose: "98" })
    Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead)
    sign_in_as(doctor!(create_unit("UBS Longe")))
    json_post "/lab/requisitions/#{req.id}/deliver", delivered_to: "Maria"
    expect(response).to have_http_status(:forbidden)
    expect(req.reload.status).to eq("released")
  end

  it "GAL: unidade ou laboratório registra uma vez; formato; estranho 403" do
    order = req.items.first.exam_order
    sign_in_as(doctor!(create_unit("UBS Longe")))
    json_post "/exams/orders/#{order.id}/gal_requisition", gal_requisition: "2026-000123"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(staff)
    json_post "/exams/orders/#{order.id}/gal_requisition", gal_requisition: "2026/000123"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_gal_requisition" ])
    json_post "/exams/orders/#{order.id}/gal_requisition", gal_requisition: "2026-000123"
    expect(json_body["gal_requisition"]).to eq("2026-000123")
    json_post "/exams/orders/#{order.id}/gal_requisition", gal_requisition: "2026-000124"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "gal_already_registered" ])
    expect(order.reload.gal_requisition).to eq("2026-000123")
    expect(DomainEvent.where(name: "exam_order.gal_registered").sole.payload.keys).to contain_exactly("exam_order_id")
  end
end
