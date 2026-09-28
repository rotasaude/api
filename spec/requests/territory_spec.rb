require "rails_helper"

RSpec.describe "Território", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let!(:ubs) { create_unit("UBS Centro") }
  let!(:upa) { create_unit("UPA Norte", kind: "upa") }

  describe "com municipal_admin" do
    before { sign_in_as(admin) }

    it "cria, renomeia, cobre, desativa, reativa e lista com origem, estado e unidades" do
      json_post "/territory/neighborhoods", name: "  Santa Felicidade "
      expect(response).to have_http_status(:created)
      id = body.dig("neighborhood", "id")
      expect(body["neighborhood"])
        .to eq("id" => id, "name" => "Santa Felicidade", "source" => "manual", "active" => true, "units" => [])

      json_post "/territory/neighborhoods/#{id}", name: "Santa Felicidade Velha"
      expect(response).to have_http_status(:ok)
      expect(body.dig("neighborhood", "name")).to eq("Santa Felicidade Velha")

      json_post "/territory/neighborhoods/#{id}/coverage", health_unit_ids: [ upa.id, ubs.id ]
      expect(body.dig("neighborhood", "units")).to eq([
        { "id" => ubs.id, "name" => "UBS Centro", "active" => true },
        { "id" => upa.id, "name" => "UPA Norte", "active" => true }
      ])

      json_post "/territory/neighborhoods/#{id}/deactivate"
      expect(body.dig("neighborhood", "active")).to be(false)
      json_post "/territory/neighborhoods/#{id}/activate"
      expect(body.dig("neighborhood", "active")).to be(true)

      Neighborhood.create!(name: "Batel", source: "seed", active: false)
      get "/territory/neighborhoods"
      expect(body["neighborhoods"].map { |n| [ n["name"], n["source"], n["active"], n["units"].size ] })
        .to eq([ [ "Batel", "seed", false, 0 ], [ "Santa Felicidade Velha", "manual", true, 2 ] ])
    end

    it "unidade desativada depois de coberta continua listada, com active false" do
      centro = Neighborhood.create!(name: "Centro", source: "manual")
      NeighborhoodCoverage.create!(neighborhood: centro, health_unit: ubs)
      ubs.update!(active: false)
      get "/territory/neighborhoods"
      expect(body["neighborhoods"].sole["units"]).to eq([ { "id" => ubs.id, "name" => "UBS Centro", "active" => false } ])
    end

    describe "recusas" do
      let!(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }

      it "nome vazio ou que não é texto: 422 blank_name" do
        json_post "/territory/neighborhoods", name: "  "
        expect(status_and_error).to eq([ 422, "blank_name" ])
        json_post "/territory/neighborhoods", name: { "x" => 1 }
        expect(status_and_error).to eq([ 422, "blank_name" ])
        json_post "/territory/neighborhoods/#{centro.id}", name: ""
        expect(status_and_error).to eq([ 422, "blank_name" ])
      end

      it "nome repetido em outra caixa: 422 name_taken" do
        json_post "/territory/neighborhoods", name: "CENTRO"
        expect(status_and_error).to eq([ 422, "name_taken" ])
      end

      it "cobertura com unidade inativa, inexistente, ou corpo sem lista: 422 inactive_unit e nada muda" do
        ubs.update!(active: false)
        [ { health_unit_ids: [ ubs.id ] }, { health_unit_ids: [ SecureRandom.uuid ] },
          { health_unit_ids: "x" }, { health_unit_ids: [ { "id" => upa.id } ] }, {} ].each do |payload|
          json_post "/territory/neighborhoods/#{centro.id}/coverage", payload
          expect(status_and_error).to eq([ 422, "inactive_unit" ]), payload.inspect
        end
        expect(centro.coverages).to be_empty
      end

      it "cobertura em bairro inativo: 422 inactive_neighborhood" do
        centro.update!(active: false)
        json_post "/territory/neighborhoods/#{centro.id}/coverage", health_unit_ids: [ upa.id ]
        expect(status_and_error).to eq([ 422, "inactive_neighborhood" ])
      end

      it "bairro inexistente ou id que não é UUID: 404 not_found" do
        [ SecureRandom.uuid, "nao-e-uuid" ].each do |id|
          json_post "/territory/neighborhoods/#{id}/deactivate"
          expect(status_and_error).to eq([ 404, "not_found" ])
        end
      end
    end
  end

  describe "só o municipal_admin" do
    (Membership::ROLES - %w[municipal_admin]).each do |role|
      it "#{role}: 403 missing_role em todas, nada muda" do
        centro = Neighborhood.create!(name: "Centro", source: "manual")
        sign_in_as(staff_with("#{role}@cidade.gov.br", role))

        get "/territory/neighborhoods"
        expect(status_and_error).to eq([ 403, "missing_role" ])
        [
          [ "/territory/neighborhoods", { name: "Novo" } ],
          [ "/territory/neighborhoods/#{centro.id}", { name: "Outro" } ],
          [ "/territory/neighborhoods/#{centro.id}/deactivate", {} ],
          [ "/territory/neighborhoods/#{centro.id}/activate", {} ],
          [ "/territory/neighborhoods/#{centro.id}/coverage", { health_unit_ids: [ ubs.id ] } ]
        ].each do |path, params|
          json_post path, params
          expect(status_and_error).to eq([ 403, "missing_role" ]), path
        end
        expect(centro.reload).to have_attributes(name: "Centro", active: true)
        expect(Neighborhood.count).to eq(1)
        expect(NeighborhoodCoverage.count).to eq(0)
      end
    end
  end

  it "sem sessão: 401" do
    get "/territory/neighborhoods"
    expect(response).to have_http_status(:unauthorized)
  end
end
