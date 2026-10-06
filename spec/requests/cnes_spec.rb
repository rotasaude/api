# spec/requests/cnes_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §5; contratos §5.2): o municipal_admin vê propostas
# e divergências e confirma com step-up; proposta que mudou desde a leitura é
# pulada; nada é aplicado sem confirmação.
RSpec.describe "CNES da cidade", type: :request do
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let!(:jardim) { create_unit("UBS Jardim das Flores") }
  def json = JSON.parse(response.body)
  def apply(ids) = post("/cnes/apply", params: { proposal_ids: ids }, as: :json)

  before do
    cnes_city!
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ],
                   bonds: [ { cnes: "0000001", ine: nil, cbo_code: "225125", cpf: "52998224725", cns: "700000000000005" } ])
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
  end

  it "sem retrato: snapshot null e listas vazias" do
    CityProfile.current.update!(ibge_code: "4115200")
    get "/cnes"
    expect(json).to eq("snapshot" => nil, "proposals" => [], "divergences" => [])
  end

  it "GET mostra a proposta sem o alvo interno e sem CPF/CNS em claro; nada aplicado" do
    get "/cnes"
    expect(json["snapshot"]).to include("competence" => "202609")
    expect(json["proposals"].first.keys).to match_array(%w[id kind action local cnes confidence])
    expect(response.body).not_to include("52998224725")
    expect(response.body).not_to include("700000000000005")
    expect(jardim.reload.cnes).to be_nil
  end

  it "confirma com step-up, aplica, publica evento só com ids; a mesma proposta de novo é stale" do
    get "/cnes"
    id = json["proposals"].first["id"]
    apply([ id ])
    expect(response).to have_http_status(:ok)
    expect(json).to eq("applied" => 1, "skipped" => [])
    expect(jardim.reload.cnes).to eq("0000001")
    expect(DomainEvent.where(name: "cnes.proposals_applied").map(&:payload)).to eq([ { "user_id" => admin.id, "count" => 1 } ])
    apply([ id ])
    expect(json).to eq("applied" => 0, "skipped" => [ { "id" => id, "reason" => "stale" } ])
  end

  # Review Focus 4: o cadastro mudou depois da leitura.
  it "unidade editada à mão depois da leitura: stale, nada sobrescrito" do
    get "/cnes"
    id = json["proposals"].first["id"]
    jardim.update!(name: "UBS Jardim Renomeada")
    apply([ id ])
    expect(json["skipped"]).to eq([ { "id" => id, "reason" => "stale" } ])
    expect(jardim.reload.cnes).to be_nil
  end

  it "sem step-up: 401 mfa_required; lista inválida: 422; papel errado: 403" do
    get "/cnes"
    id = json["proposals"].first["id"]
    Session.find_by!(user: admin).update!(mfa_verified_at: 10.minutes.ago)
    apply([ id ])
    expect([ response.status, json ]).to eq([ 401, { "error" => "mfa_required" } ])
    Session.find_by!(user: admin).update!(mfa_verified_at: Time.current)
    apply([])
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_proposals" } ])
    apply([ "../etc" ])
    expect(response).to have_http_status(:unprocessable_entity)
    sign_in_as(staff_with("recepcao@cidade.gov.br", "citizen_verifier"))
    get "/cnes"
    expect([ response.status, json ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
