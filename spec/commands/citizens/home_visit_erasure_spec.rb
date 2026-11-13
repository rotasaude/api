require "rails_helper"

# Módulo 24b (ADR 0052; contrato §13, "Exclusão LGPD (ADR 0026)"): quem tem
# QUALQUER visita domiciliar (retirada inclusive) ou participação em atividade
# coletiva (atividade por engano inclusive) é registro retido, como o cadastro
# do 24a (L13). O pedido nasce retido e a confirmação (Citizens::Erase)
# reconfere pela mesma regra. A exclusão nunca apaga visita, folha, participação
# nem ficha.
RSpec.describe "Exclusão LGPD com visita domiciliar e atividade coletiva (ADR 0052)", type: :model do
  let!(:city) { home_visit_city!(collective: true) }
  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: agent) }
  let(:day) { home_visit_day!(agent: agent, team: team) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  def visit_for(patient, **over) = home_visit!(day: day, micro_area: area, subject: "resident", patient: patient, **over)

  def withdraw!(visit)
    result = HomeVisits::Withdraw.call(visit, by: agent, expected_state: "recorded", reason: "Lançada para o morador errado")
    expect(result).to be_ok
  end

  def activity_with(patient)
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "held_on" => Time.zone.today.iso8601, "shift" => 2,
               "activity_type" => 5, "place_text" => "Salão paroquial", "participants_count" => 12, "target_audience" => [ 12 ],
               "health_topics" => [ 4 ], "participants" => [ { "patient_id" => patient.id } ] }
    result = CollectiveActivities::Record.call(params: params, by: agent)
    expect(result).to be_ok
    result.payload[:activity]
  end

  it "paciente com visita retirada → pedido nasce retained" do
    patient, citizen = exam_patient!(31, age: 40, sex: "female")
    withdraw!(visit_for(patient))
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "paciente com visita ativa → pedido nasce retained" do
    patient, citizen = exam_patient!(32, age: 40, sex: "female")
    visit_for(patient)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "participante de atividade por engano → retained" do
    patient, citizen = exam_patient!(33, age: 40, sex: "female")
    activity = activity_with(patient)
    result = CollectiveActivities::MarkMistaken.call(activity, by: agent, expected_state: "recorded", reason: "Registrada em dobro")
    expect(result).to be_ok
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "participante de atividade válida → retained" do
    patient, citizen = exam_patient!(34, age: 40, sex: "female")
    activity_with(patient)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "visita a imóvel sem pessoa não retém ninguém" do
    _patient, citizen = exam_patient!(35, age: 40, sex: "female")
    home_visit!(day: day, micro_area: area)
    expect(HomeVisit.where.not(patient_id: nil)).not_to exist
    expect(request_for(citizen).payload[:request].status).to eq("pending")
  end

  it "paciente com cadastro individual já era retido (nenhum tombstone erased nasce)" do
    patient, citizen = exam_patient!(36, age: 40, sex: "female")
    registry_registration!(patient: patient)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
  end

  it "visita gravada depois do pedido: a confirmação retém e nada se apaga" do
    patient, citizen = exam_patient!(37, age: 40, sex: "female")
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    visit = visit_for(patient)
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(HomeVisit.where(id: visit.id)).to exist
  end

  it "participação gravada depois do pedido: a confirmação retém e nada se apaga" do
    patient, citizen = exam_patient!(38, age: 40, sex: "female")
    request = request_for(citizen).payload[:request]
    activity = activity_with(patient)
    expect(Citizens::Erase.call(request: request, by: care_admin!).payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(CollectiveActivityParticipant.where(collective_activity_id: activity.id, patient_id: patient.id)).to exist
  end
end
