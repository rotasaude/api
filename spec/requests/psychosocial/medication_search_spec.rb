require "rails_helper"

# Módulo 31 (P8, P47): a equipe do CAPS (sem health_professional) busca no
# catálogo de medicamentos para montar a receita e a notificação de controlado
# pela ação. Dado de referência da plataforma, sem dado de paciente. Para os
# papéis atuais nada muda (medication_search_spec cobre o restante).
RSpec.describe "CAPS — busca de medicamentos", type: :request do
  before do
    documents_city!
    import_test_catalog!
  end

  let(:caps) { caps! }

  def search(q = "losartana") = json_post("/attendance/medications/search", { q: q })
  def codes = json_body["items"].map { |item| item["catmat_code"] }

  [ false, true ].each do |lead|
    role = lead ? "psychosocial_lead" : "psychosocial_staff"

    it "#{role} busca no catálogo: 200 com items" do
      sign_in_as(caps_staff!(caps, lead: lead))
      search
      expect([ response.status, codes ]).to eq([ 200, [ 268_856 ] ])
    end

    it "#{role} com clinical_documents desligado segue recusado (como o profissional)" do
      documents_city!(enabled: false)
      sign_in_as(caps_staff!(caps, lead: lead))
      search
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_documents" } ])
    end
  end

  it "health_professional e municipal_admin seguem com 200" do
    sign_in_as(doctor!(create_unit))
    search
    expect([ response.status, codes ]).to eq([ 200, [ 268_856 ] ])
    sign_in_as(municipal_admin!)
    search
    expect([ response.status, codes ]).to eq([ 200, [ 268_856 ] ])
  end

  it "viewer recebe 403 missing_role" do
    sign_in_as(staff_with("viewer-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer"))
    search
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
