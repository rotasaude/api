# spec/requests/medication_search_spec.rb
require "rails_helper"

# Contrato §5: busca no catálogo da plataforma; REMUME primeiro ("na rede",
# pela unidade); controlado aparece marcado (bloqueado na emissão); escondido
# e removido nunca; sem catálogo ou sem listas Anvisa → 503.
RSpec.describe "Busca de medicamentos", type: :request do
  before { documents_city! }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UBS Norte") }
  let(:doctor) { doctor!(unit) }

  def search(q, unit_id: nil) = json_post("/attendance/medications/search", { q: q, unit_id: unit_id }.compact)

  it "sem catálogo ativo → 503 catalog_unavailable" do
    sign_in_as(doctor)
    search("losartana")
    expect([ response.status, json_body ]).to eq([ 503, { "error" => "catalog_unavailable" } ])
  end

  it "REMUME primeiro (por unidade), acento e caixa ignorados, controlado marcado, escondido fora" do
    import_test_catalog!
    CityMedication.create!(catalog_item_id: catalog_item(267_674).id, unit_ids: [ other_unit.id ], added_by_user: doctor)
    CityMedication.create!(catalog_item_id: catalog_item(267_772).id, unit_ids: [], added_by_user: doctor)
    sign_in_as(doctor)

    search("losartana")
    expect(json_body["items"].map { |item| item["catmat_code"] }).to eq([ 268_856 ]) # 384258 (manipulada) está escondida
    search("diazepam")
    expect(json_body["items"].first).to include("catmat_code" => 267_197, "controlled" => true, "in_network" => false)
    search("ácido fólico")
    expect(json_body["items"].first["catmat_code"]).to eq(267_503)
    search("o")
    expect(json_body["items"]).to eq([])

    search("mg", unit_id: unit.id)
    first = json_body["items"].first
    expect(first).to include("catmat_code" => 267_772, "in_network" => true)        # REMUME de toda a rede
    expect(json_body["items"].find { |item| item["catmat_code"] == 267_674 }["in_network"]).to be(false) # só na outra UBS
  end

  it "interruptor desligado → 403; recepção → 403 missing_role" do
    import_test_catalog!
    documents_city!(enabled: false)
    sign_in_as(doctor)
    search("losartana")
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "clinical_documents")
    documents_city!
    sign_in_as(verifier!)
    search("losartana")
    expect(json_body).to eq("error" => "missing_role")
    sign_in_as(municipal_admin!) # monta a REMUME e os protocolos
    search("losartana")
    expect(json_body["items"].map { |item| item["catmat_code"] }).to eq([ 268_856 ])
  end

  # api#60 (rodada especial do 19): o admin monta a REMUME e os protocolos antes de
  # ligar os documentos clínicos; o profissional segue exigindo o interruptor.
  describe "interruptor por papel" do
    before { import_test_catalog! }

    it "admin busca com clinical_documents desligado (só clinical_record)" do
      documents_city!(enabled: false)
      sign_in_as(municipal_admin!)
      search("losartana")
      expect([ response.status, json_body["items"].map { |item| item["catmat_code"] } ]).to eq([ 200, [ 268_856 ] ])
    end

    it "profissional com clinical_documents desligado segue recusado" do
      documents_city!(enabled: false)
      sign_in_as(doctor)
      search("losartana")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_documents" } ])
    end

    it "admin com clinical_record desligado é recusado pelo prontuário" do
      clinical_city!(enabled: false)
      sign_in_as(municipal_admin!)
      search("losartana")
      expect([ response.status, json_body["feature"] ]).to eq([ 403, "clinical_record" ])
    end

    it "quem tem os dois papéis segue a regra do admin" do
      documents_city!(enabled: false)
      both = doctor.tap { |u| Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current) }
      sign_in_as(both)
      search("losartana")
      expect(response.status).to eq(200)
    end
  end
end

