# spec/commands/start_triage_by_name_spec.rb
require "rails_helper"

# ADR 0027 (spec 2026-10-05 §5.2): a triagem começa pelo nome escolhido, se
# estiver em oferta para o par; a sugestão pendente daquele protocolo vira
# taken na mesma transação; a triagem aponta a versão ativa exata (ADR 0010).
RSpec.describe StartTriage, "por nome" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("inicio-#{SecureRandom.hex(3)}@cidade.gov.br") }
  let!(:idoso) do
    active_protocol!("saude-do-idoso", offer: { "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365 })
  end
  let!(:offer_row) { TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin) }
  let(:avo) { profiled_citizen!(age: 62) }

  # Uma conversa web ativa por par (índice único): reaproveita a que existe.
  def conversation_for(citizen)
    Conversation.channel_web.find_by(citizen: citizen, state: Conversation::ACTIVE_STATES) ||
      Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: :consented)
  end
  def start(citizen, name = "saude-do-idoso") = described_class.call(conversation: conversation_for(citizen), protocol_name: name)

  it "abre a triagem do protocolo escolhido na versão ativa" do
    triage = start(avo).payload[:triage]
    expect(triage).to have_attributes(protocol_name: "saude-do-idoso", protocol_definition_id: idoso.id, current_step: "q1")
  end

  it "fora de oferta: :not_offered e nenhuma triagem (idade, pausa, intervalo, inexistente)" do
    neto = profiled_citizen!(age: 8, sex: "male", cpf: CampaignHistory.cpf_for("neto"))
    expect(start(neto).reason).to eq(:not_offered)
    offer_row.update!(enabled: false)
    expect(start(avo).reason).to eq(:not_offered)
    offer_row.update!(enabled: true)
    completed_triage!(avo, "saude-do-idoso", at: 10.days.ago)
    expect(start(avo).reason).to eq(:not_offered)
    expect(start(avo, "fantasma").reason).to eq(:not_offered)
    expect(Triage.where(status: "in_progress")).to be_empty
  end

  it "sugestão pendente do protocolo vira taken com a triagem nova" do
    create_default_protocol!
    source = completed_triage!(avo, StartTriage::DEFAULT_PROTOCOL_NAME)
    suggestion = TriageSuggestion.create!(citizen: avo, source_triage: source, protocol_name: "saude-do-idoso")
    triage = start(avo).payload[:triage]
    expect(suggestion.reload).to have_attributes(status: "taken", taken_triage_id: triage.id, resolved_at: be_present)
  end
  # Uma leitura do catálogo em paralelo pode expirar a sugestão (catálogo:
  # pending → expired) enquanto o início a marca taken; o trigger recusa
  # expired → taken. O início nunca vira 500: a triagem nasce e quem chegou
  # primeiro decide o estado da sugestão.
  context "sugestão expirada por uma leitura do catálogo em paralelo" do
    before { create_default_protocol! }

    let!(:suggestion) do
      source = completed_triage!(avo, StartTriage::DEFAULT_PROTOCOL_NAME)
      TriageSuggestion.create!(citizen: avo, source_triage: source, protocol_name: "saude-do-idoso")
    end

    def expire! = TriageSuggestion.where(id: suggestion.id).update_all(status: "expired", resolved_at: Time.current)

    it "entre a leitura e a escrita: o início não levanta" do
      allow_any_instance_of(TriageSuggestion).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
        expire!
        original.call(*args, **kwargs)
      end
      result = start(avo)
      expect(result).to be_ok
      expect(result.payload[:triage]).to be_status_in_progress
      expect(suggestion.reload.status).not_to eq("pending")
    end

    it "antes da escrita: a sugestão fica expired e a triagem nasce" do
      allow(described_class).to receive(:take_suggestion!).and_wrap_original do |original, *args|
        expire!
        original.call(*args)
      end
      result = start(avo)
      expect(result).to be_ok
      expect(suggestion.reload).to have_attributes(status: "expired", taken_triage_id: nil)
    end
  end
end
