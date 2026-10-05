require "rails_helper"

RSpec.describe Citizens::SubmitAnswer do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:started) { Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload }
  let(:conversation) { started[:conversation] }
  let(:triage) { started[:triage] }

  def submit(answer, key = SecureRandom.uuid)
    described_class.call(conversation: conversation, answer: answer, idempotency_key: key)
  end

  it "avança para o próximo passo" do
    expect(submit("true")).to be_ok
    expect(triage.reload.current_step).to eq("febre")
  end

  it "conclui a triagem e a conversa no último passo, publicando os eventos" do
    submit("true")
    result = submit("true")
    expect(result.payload[:triage]).to be_status_completed
    expect(conversation.reload).to be_state_completed
    names = DomainEvent.where("payload->>'triage_id' = ?", triage.id).pluck(:name)
    expect(names).to include("triage.completed")
  end

  it "recusa resposta fora do esperado sem gravar nada" do
    expect(submit("banana").reason).to eq(:invalid_answer)
    expect(submit("sim").reason).to eq(:invalid_answer)
    expect(triage.reload.answers).to eq({})
    expect(triage).to be_status_in_progress
  end

  it "a mesma chave repetida não avança duas vezes" do
    submit("true", "k1")
    result = submit("true", "k1")
    expect(result.payload[:replayed]).to be(true)
    expect(triage.reload.answers).to eq("tosse" => "true")
    expect(triage.current_step).to eq("febre")
  end

  it "outra chave depois de concluída é recusada" do
    submit("true")
    submit("false")
    expect(submit("true").reason).to eq(:not_in_progress)
  end
  # Desvio 5: toda escrita que toca cidadão e conversa trava cidadão → conversa
  # (StartConversation, Erase). Na conclusão, Triages::Suggest grava
  # triage_suggestions, cuja FK pega FOR KEY SHARE no cidadão; travar a conversa
  # primeiro fecharia um ciclo com StartConversation/Erase (deadlock).
  it "trava o cidadão antes da conversa (ordem cidadão → conversa)" do
    conversation # cria antes de escutar
    locks = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.include?("FOR UPDATE")
      locks << :citizen if sql.include?('"citizens"')
      locks << :conversation if sql.include?('"conversations"')
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { submit("true") }
    expect(locks.first(2)).to eq(%i[citizen conversation])
  end

  it "conversa sem cidadão (WhatsApp) continua respondendo" do
    conversation.update_columns(citizen_id: nil)
    expect(submit("true")).to be_ok
    expect(triage.reload.current_step).to eq("febre")
  end
end
