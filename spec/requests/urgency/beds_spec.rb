require "rails_helper"

# Módulo 32b (ADR 0050; contrato §3 e §12 Q1): cadastro de leitos da observação
# da UPA, só do municipal_admin, escrita com step-up. Sem evento e sem trilha.
RSpec.describe "Urgência — leitos da observação", type: :request do
  let!(:city) { urgency_city! }
  let(:admin) { urgency_admin! }
  let(:upa) { create_unit("UPA Leitos", kind: "upa") }

  def bed!(unit = upa, label: "OBS 01") = UrgencyBed.create!(health_unit: unit, label: label, updated_by_user: admin)

  describe "como administrador com step-up" do
    before { stepped_up!(admin) }

    it "cria, lista por rótulo, renomeia e desativa" do
      json_post "/urgency/beds", health_unit_id: upa.id, label: " OBS 02 "
      expect(response).to have_http_status(:created)
      id = json_body.dig("bed", "id")
      expect(json_body["bed"]).to eq("id" => id, "health_unit_id" => upa.id, "label" => "OBS 02", "active" => true, "occupied" => false)

      bed!(label: "OBS 01")
      bed!(create_unit("UPA Outra", kind: "upa"), label: "X1")
      get "/urgency/beds", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |b| b["label"] }).to eq([ "OBS 01", "OBS 02" ])
      expect(json_body["items"].first.keys).to match_array(%w[id health_unit_id label active occupied])

      json_patch "/urgency/beds/#{id}", label: "OBS 03", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body["bed"]).to include("label" => "OBS 03", "active" => false, "occupied" => false)
      expect(UrgencyBed.find(id).updated_by_user_id).to eq(admin.id)
    end

    it "recusa a unidade que não é UPA (422 not_an_upa)" do
      json_post "/urgency/beds", health_unit_id: create_unit("UBS X", kind: "ubs").id, label: "OBS 01"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "not_an_upa", "path" => "health_unit_id")
    end

    it "recusa unidade inexistente, inativa ou malformada (422 invalid_request health_unit_id)" do
      inactive = create_unit("UPA Inativa", kind: "upa")
      inactive.update!(active: false)
      [ SecureRandom.uuid, inactive.id, "nao-e-uuid", nil ].each do |value|
        json_post "/urgency/beds", health_unit_id: value, label: "OBS 01"
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      end
      expect(UrgencyBed.count).to eq(0)
    end

    it "recusa rótulo fora de 1..20, active não booleano e chave desconhecida (422 com path)" do
      json_post "/urgency/beds", health_unit_id: upa.id, label: "L" * 21
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "label")

      json_post "/urgency/beds", health_unit_id: upa.id, label: "   "
      expect(json_body).to include("error" => "invalid_request", "path" => "label")

      json_post "/urgency/beds", health_unit_id: upa.id, label: "OBS 01", active: "sim"
      expect(json_body).to include("error" => "invalid_request", "path" => "active")

      json_post "/urgency/beds", health_unit_id: upa.id, label: "OBS 01", extra: 1
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"].map { |p| p["path"] }).to eq(%w[extra])
      expect(UrgencyBed.count).to eq(0)
    end

    it "rótulo repetido na unidade → 409 bed_label_taken (na criação e na edição); em outra UPA pode" do
      bed!(label: "OBS 01")
      json_post "/urgency/beds", health_unit_id: upa.id, label: "OBS 01"
      expect(response).to have_http_status(:conflict)
      expect(json_body).to include("error" => "bed_label_taken")

      other = bed!(label: "OBS 02")
      json_patch "/urgency/beds/#{other.id}", label: "OBS 01"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("bed_label_taken")

      json_post "/urgency/beds", health_unit_id: create_unit("UPA Dois", kind: "upa").id, label: "OBS 01"
      expect(response).to have_http_status(:created)
    end

    it "a unidade do leito não muda (422 health_unit_id); leito desconhecido é 404" do
      bed = bed!
      json_patch "/urgency/beds/#{bed.id}", health_unit_id: create_unit("UPA Tres", kind: "upa").id
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      json_patch "/urgency/beds/#{SecureRandom.uuid}", label: "Z"
      expect(response).to have_http_status(:not_found)
      json_patch "/urgency/beds/nao-e-uuid", label: "Z"
      expect(response).to have_http_status(:not_found)
    end

    it "leito ocupado aparece como occupied e não se desativa (409 bed_occupied); renomear pode" do
      bed = bed!
      encounter = arrived!(upa)
      classified!(encounter, color: "yellow", by: upa_nurse!(upa))
      called!(encounter, by: upa_doctor!(upa))
      UrgencyBedStay.create!(urgency_encounter: encounter.reload, urgency_bed: bed, health_unit: upa, started_at: Time.current,
                             started_by_user: upa_doctor!(upa))

      get "/urgency/beds", params: { health_unit_id: upa.id }
      expect(json_body["items"].first).to include("occupied" => true)

      json_patch "/urgency/beds/#{bed.id}", active: false
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("bed_occupied")
      expect(bed.reload.active).to be(true)

      json_patch "/urgency/beds/#{bed.id}", label: "OBS 09"
      expect(response).to have_http_status(:ok)

      bed.bed_stays.open_stays.first.update!(ended_at: Time.current, end_kind: "observation_ended", ended_by_user: upa_doctor!(upa))
      json_patch "/urgency/beds/#{bed.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body["bed"]).to include("active" => false, "occupied" => false)
    end

    it "reativar exige a unidade ainda UPA ativa (422 not_an_upa, path active); na UPA ativa passa" do
      bed = bed!
      bed.update!(active: false)
      upa.update!(kind: "ubs")
      json_patch "/urgency/beds/#{bed.id}", active: true
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "not_an_upa", "path" => "active")
      expect(bed.reload.active).to be(false)

      upa.update!(kind: "upa", active: false)
      json_patch "/urgency/beds/#{bed.id}", active: true
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "not_an_upa", "path" => "active")

      upa.update!(active: true)
      json_patch "/urgency/beds/#{bed.id}", active: true
      expect(response).to have_http_status(:ok)
      expect(json_body["bed"]).to include("active" => true)
    end

    it "PATCH: chave desconhecida → 422; corpo vazio → 200 sem mudança" do
      bed = bed!
      before = bed.slice(:label, :active, :updated_at)
      json_patch "/urgency/beds/#{bed.id}", extra: 1
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"].map { |p| p["path"] }).to eq(%w[extra])

      json_patch "/urgency/beds/#{bed.id}", {}
      expect(response).to have_http_status(:ok)
      expect(json_body["bed"]).to include("label" => "OBS 01", "active" => true)
      expect(bed.reload.slice(:label, :active, :updated_at)).to eq(before)
    end

    it "a lista exige health_unit_id de uma UPA e aceita só essa query" do
      get "/urgency/beds"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      get "/urgency/beds", params: { health_unit_id: create_unit("UBS Y", kind: "ubs").id }
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      get "/urgency/beds", params: { health_unit_id: upa.id, label: "x" }
      expect(json_body).to include("error" => "invalid_request", "path" => "label")
    end
  end

  describe "acesso" do
    it "escrita sem step-up → 401 mfa_required" do
      sign_in_as(admin)
      json_post "/urgency/beds", health_unit_id: upa.id, label: "OBS 01"
      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("mfa_required")
      expect(UrgencyBed.count).to eq(0)
    end

    it "o enfermeiro da UPA não lê nem escreve (403 missing_role)" do
      stepped_up!(upa_nurse!(upa))
      json_post "/urgency/beds", health_unit_id: upa.id, label: "OBS 01"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
      get "/urgency/beds", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
      expect(UrgencyBed.count).to eq(0)
    end

    it "sem sessão → 401; urgência desligada → 403 feature_disabled" do
      get "/urgency/beds", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:unauthorized)

      stepped_up!(admin)
      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      get "/urgency/beds", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end
  end
end
