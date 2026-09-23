require "rails_helper"

RSpec.describe Citizens::StartConversation do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  def start(version: Consents.current_version)
    described_class.call(citizen: citizen, consent_version: version, session_id: "sess-1")
  end

  it "abre a conversa web, registra o consentimento web e começa a triagem" do
    result = start
    expect(result).to be_ok
    conversation = result.payload[:conversation]
    expect(conversation).to be_channel_web
    expect(conversation.citizen).to eq(citizen)
    expect(conversation.phone).to eq(citizen.phone)
    expect(conversation.consents.last.channel).to eq("web")
    expect(result.payload[:triage].current_step).to eq("tosse")
    expect(result.payload[:resumed]).to be(false)
  end

  it "retoma a conversa ativa em vez de abrir outra" do
    first = start.payload
    CompleteTriage.call(triage: first[:triage], answer: "true")
    again = start
    expect(again.payload[:conversation]).to eq(first[:conversation])
    expect(again.payload[:triage].reload.current_step).to eq("febre")
    expect(again.payload[:resumed]).to be(true)
  end

  it "recusa versão do termo que não é a vigente" do
    expect(start(version: "999").reason).to eq(:consent_outdated)
  end

  it "pede o consentimento de novo quando um termo novo sai no meio da triagem" do
    first = start.payload
    ConsentTerm.create!(version: (Consents.current_version.to_i + 1).to_s, body: "Termo novo", published_at: Time.current)
    again = start
    expect(again).to be_ok
    conversation = again.payload[:conversation]
    expect(conversation).to eq(first[:conversation])
    expect(conversation.reload).to be_consented
    expect(CompleteTriage.call(triage: again.payload[:triage], answer: "true")).to be_ok
  end

  it "falha com :no_protocol sem protocolo ativo, sem perder o consentimento" do
    allow(StartTriage).to receive(:call).and_return(Result.fail(:no_protocol))
    result = start
    expect(result.reason).to eq(:no_protocol)
    expect(Conversation.channel_web.last).to be_state_consented
  end

  # Regressão: duas abas / toque duplo em "start" chamam o comando de novo
  # para a MESMA conversa antes de qualquer outro passo (ex.: repost do
  # formulário). Sem lock, os dois veem "sem consentimento vigente" e "sem
  # triagem em andamento" ao mesmo tempo: consent duplicado e 500 no índice
  # único de triagem em andamento. Aqui a chamada é sequencial (sem thread),
  # mas cobre a mesma conversa gravada pela primeira chamada e confere que a
  # segunda não grava consentimento nem triagem de novo.
  it "não duplica consentimento nem triagem ao chamar de novo para a mesma conversa" do
    first = start.payload
    again = start

    expect(again).to be_ok
    expect(again.payload[:conversation]).to eq(first[:conversation])
    expect(again.payload[:triage]).to eq(first[:triage])
    expect(again.payload[:resumed]).to be(true)

    conversation = first[:conversation]
    expect(conversation.consents.count).to eq(1)
    expect(conversation.triages.status_in_progress.count).to eq(1)
    expect(
      DomainEvent.where(name: "consent.given")
                 .where("payload->>'conversation_id' = ?", conversation.id).count
    ).to eq(1)
  end

  it "não duplica o consentimento novo ao chamar de novo depois de um termo publicado no meio" do
    first = start.payload
    ConsentTerm.create!(version: (Consents.current_version.to_i + 1).to_s, body: "Termo novo", published_at: Time.current)
    new_version = Consents.current_version

    start(version: new_version)
    again = start(version: new_version)

    expect(again).to be_ok
    conversation = first[:conversation].reload
    expect(again.payload[:conversation]).to eq(conversation)
    expect(conversation.consents.where(version: new_version.to_i).count).to eq(1)
    expect(conversation.consents.where(revoked_at: nil).count).to eq(1)
    expect(
      DomainEvent.where(name: "consent.given")
                 .where("payload->>'conversation_id' = ?", conversation.id)
                 .where("payload->>'version' = ?", new_version).count
    ).to eq(1)
  end
end
