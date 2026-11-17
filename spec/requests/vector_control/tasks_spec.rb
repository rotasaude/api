require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6, §12, §17; Q8, Q9; A-8, A-14):
# /vector_control/tasks, as tarefas da coordenação. A intensificação sai com
# a ovitrampa e os quarteirões sugeridos (nunca paciente); fechar é open →
# done | dismissed uma vez, com nota 10–500 (409 invalid_transition path
# status; 422 invalid_request path note).
RSpec.describe "Vigilância ambiental — tarefas", type: :request do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:neighbor) { city_block!(neighborhood: neighborhood, number: "13") }
  let(:today) { Time.zone.today }

  # Contagem de 150 ovos: a tarefa de intensificação, aberta.
  def task!
    first, second = [ block, neighbor ].sort_by(&:id)
    CityBlockNeighbor.create!(city_block: first, neighbor_block: second)
    ovitrap = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), number: "OV-12")
    reading = ovitrap_collected!(ovitrap, agent: agent)
    VectorControl::CountReading.call(reading: reading, egg_count: 150, note: nil, by: vector_lab!).payload.fetch(:task)
  end

  it "lista as abertas com a ovitrampa e os quarteirões sugeridos; só a coordenação" do
    task = task!
    sign_in_as(coordinator)
    get "/vector_control/tasks", params: { state: "open" }
    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    item = json_body["items"].sole
    expect(item.except("suggested_blocks")).to eq("id" => task.id, "kind" => "ovitrap_intensification", "state" => "open",
                                                  "created_at" => task.created_at.utc.iso8601,
                                                  "ovitrap" => { "id" => task.ovitrap_id, "number" => "OV-12" },
                                                  "disease" => nil, "case_on" => nil, "transmission_block_id" => nil, "closed_at" => nil)
    expect(item["suggested_blocks"]).to contain_exactly({ "id" => block.id, "number" => "12" }, { "id" => neighbor.id, "number" => "13" })
    get "/vector_control/tasks", params: { state: "closed" }
    expect(json_body["items"]).to be_empty
    get "/vector_control/tasks", params: { state: "done" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])

    sign_in_as(vector_lab!)
    get "/vector_control/tasks", params: { state: "open" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    json_post "/vector_control/tasks/#{task.id}/close", state: "done", note: "Quarteirões vistoriados na semana"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "fechar duas vezes → 409 invalid_transition path status" do
    task = task!
    sign_in_as(coordinator)
    json_post "/vector_control/tasks/#{task.id}/close", state: "done", note: "Quarteirões vistoriados na semana"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => task.id, "state" => "done")
    expect(json_body["closed_at"]).to be_present
    expect(json_body.to_s).not_to include("vistoriados")
    expect(task.reload).to have_attributes(state: "done", closed_by_user_id: coordinator.id, closed_note: "Quarteirões vistoriados na semana")
    expect(DomainEvent.where(name: "vector_task.closed").sole.payload).to eq("vector_task_id" => task.id, "user_id" => coordinator.id)

    json_post "/vector_control/tasks/#{task.id}/close", state: "dismissed", note: "Outra nota para dispensar a tarefa"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    get "/vector_control/tasks", params: { state: "closed" }
    expect(json_body["items"].map { |item| item["id"] }).to eq([ task.id ])
  end

  it "sem nota → 422 invalid_request path note" do
    task = task!
    sign_in_as(coordinator)
    json_post "/vector_control/tasks/#{task.id}/close", state: "dismissed"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
    json_post "/vector_control/tasks/#{task.id}/close", state: "dismissed", note: "curta"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
    json_post "/vector_control/tasks/#{task.id}/close", state: "open", note: "Nota com tamanho suficiente"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    json_post "/vector_control/tasks/#{task.id}/close", state: "done", note: "Nota com tamanho suficiente", reason: "x"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post "/vector_control/tasks/#{SecureRandom.uuid}/close", state: "done", note: "Nota com tamanho suficiente"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    expect(task.reload.state).to eq("open")
  end
end
