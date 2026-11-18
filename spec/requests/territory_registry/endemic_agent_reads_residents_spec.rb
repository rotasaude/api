require "rails_helper"

# Módulo 35a (Q41 retirada; Q13(1) é regra de cadastro, não de leitura): o
# agente de endemias (515140), membro de campo atribuído à microárea, segue
# com a leitura de campo do 24b no domicílio RESIDENCIAL: as famílias com o
# responsável e os moradores, pelas mesmas chamadas que o dashboard faz para
# escolher o `subject` da visita. Fecha o laço com a visita `family_responsible`
# aceita no POST /home_visits. Guarda de regressão: se alguém esvaziar as
# famílias ou os cadastros do 515140 de novo, este spec quebra.
RSpec.describe "Território — o agente de endemias lê os moradores do residencial (regressão da Q41)", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let!(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }

  let!(:household) { registry_household!(micro_area: area) }
  let!(:responsible) { registry_patient! }
  let!(:resident) { registry_registration!(household: household) }
  let!(:family) do
    registry_family!(household, responsible: responsible).tap { |own| resident.update_columns(family_id: own.id) }
  end

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  it "GET do domicílio e dos cadastros traz o responsável e os moradores; a visita ao responsável é aceita" do
    sign_in_as(agent)

    get "/territory/households/#{household.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => household.id, "property_type" => "1")
    families = json_body.fetch("families")
    expect(families).to contain_exactly(
      a_hash_including("id" => family.id, "responsible" => { "patient_id" => responsible.id, "display_name" => responsible.display_name })
    )

    get "/territory/registrations", params: { household_id: household.id }
    expect(response).to have_http_status(:ok)
    residents = json_body.fetch("registrations")
    expect(residents).not_to be_empty
    expect(residents.map { _1.dig("patient", "id") }).to include(resident.patient_id)

    # O subject escolhido a partir do que o GET devolveu.
    picked = families.first
    json_post "/home_visits", {
      "client_uuid" => SecureRandom.uuid, "team_id" => team.id,
      "occurred_at" => [ 2.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0).iso8601,
      "household_id" => household.id, "subject" => "family_responsible", "family_id" => picked.fetch("id"),
      "outcome" => 1, "reasons" => [], "shared" => false,
      "vector_inspection" => { "activity" => "li", "work_type" => "routine", "situation" => "worked",
                               "educational_action" => true, "measures" => [] }
    }
    expect(response).to have_http_status(:created)
    expect(HomeVisit.sole).to have_attributes(subject: "family_responsible", family_id: family.id,
                                              patient_id: picked.dig("responsible", "patient_id"))
  end
end
