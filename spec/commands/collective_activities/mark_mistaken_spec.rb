require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §13; plano, Task 13): "registrada por
# engano". Só quem registrou (outro → not_found), com expected_state "recorded"
# e motivo de 10–500 caracteres depois do strip (cifrado; nunca no evento nem no
# erro); segunda vez → activity_changed. A atividade ganha só os três campos
# de engano (trigger) e a ficha já enfileirada fica (pendência do §15).
RSpec.describe CollectiveActivities::MarkMistaken, type: :model do
  let!(:city) { home_visit_city!(collective: true) }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:reason) { "  Registrei a atividade na equipe errada  " }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def activity!
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "held_on" => Time.zone.today.iso8601, "shift" => 1,
               "activity_type" => 4, "place_text" => "Escola municipal", "participants_count" => 20, "target_audience" => [ 1 ],
               "health_topics" => [ 1 ], "participants" => [ { "patient_id" => registry_patient!.id } ] }
    result = CollectiveActivities::Record.call(params: params, by: acs, origin: "dashboard", device: nil)
    raise "atividade recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:activity]
  end

  # A ficha da atividade enfileirada (a Task 14 gera pelo Record; aqui a linha
  # direto, para provar que o engano não a toca).
  def queued_ficha!(activity)
    LediOutboxEntry.create!(uuid: "#{team.health_unit.cnes}-#{SecureRandom.uuid}", ficha_type: "atividade_coletiva",
                            competence: activity.held_on.strftime("%Y%m"), source_type: "CollectiveActivity",
                            source_id: activity.id, ledi_version: "8.7.0", status: "pending", next_attempt_at: Time.current,
                            attempts: 0, bytes: "x".b)
  end

  def mark(activity, by: acs, expected_state: "recorded", reason: self.reason)
    described_class.call(activity, by: by, expected_state: expected_state, reason: reason)
  end

  def events = DomainEvent.where(name: "collective_activity.marked_mistaken")

  it "quem registrou marca com motivo; outro → not_found; segunda vez → activity_changed; a ficha enfileirada fica" do
    activity = activity!
    entry = queued_ficha!(activity)
    other = field_agent!(team: team)
    expect(mark(activity, by: other).reason).to eq(:not_found)
    expect(mark(activity, by: nil).reason).to eq(:not_found)
    expect(activity.reload.mistaken_at).to be_nil

    stale = CollectiveActivity.find(activity.id) # outra sessão leu antes da marca
    result = mark(activity)
    expect(result).to be_ok
    expect(result.payload[:activity].reload).to have_attributes(mistaken_by_user_id: acs.id,
                                                                mistaken_reason: "Registrei a atividade na equipe errada",
                                                                state: "mistaken")
    expect(activity.reload.mistaken_at).to be_present
    expect(events.sole.payload).to eq("collective_activity_id" => activity.id, "user_id" => acs.id)

    expect(mark(activity).reason).to eq(:activity_changed)
    expect(stale.mistaken_at).to be_nil
    expect(mark(stale).reason).to eq(:activity_changed)
    expect(events.count).to eq(1)
    expect(entry.reload).to have_attributes(status: "pending", source_id: activity.id)
    expect(LediOutboxEntry.where(source_type: "CollectiveActivity", source_id: activity.id).count).to eq(1)
  end

  it "motivo de 10–500 depois do strip e expected_state conhecido; outro estado esperado → activity_changed" do
    activity = activity!
    expect([ mark(activity, reason: "  curto   ").reason, mark(activity, reason: "  curto   ").details[:path] ])
      .to eq([ :invalid_request, "reason" ])
    expect(mark(activity, reason: "x" * 501).details[:path]).to eq("reason")
    expect(mark(activity, reason: nil).details[:path]).to eq("reason")
    expect(mark(activity, expected_state: "open").details[:path]).to eq("expected_state")
    expect(mark(activity, expected_state: "mistaken").reason).to eq(:activity_changed)
    expect(activity.reload.mistaken_at).to be_nil
    expect(mark(activity, reason: "x" * 500)).to be_ok
  end

  it "o Result e o evento não levam o motivo" do
    activity = activity!
    result = mark(activity, reason: "Paciente Benedita foi listada por engano")
    expect(result.payload.to_s).not_to include("Benedita")
    expect(events.sole.payload.to_s).not_to include("Benedita")
  end
end
