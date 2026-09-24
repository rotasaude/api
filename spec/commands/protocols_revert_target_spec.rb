require "rails_helper"

# A versão-alvo da reversão (spec 2026-09-23-revert-target §3): as MESMAS três
# condições que `call` exige, numa leitura pura. `revertible?` passa a derivar
# daqui — se as duas tivessem regra própria, a tela habilitaria o botão
# prometendo uma versão e a API reverteria para outra.
RSpec.describe Protocols::RevertActivation, ".revert_target" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:ana) { make_reviewer! }
  let(:bia) { make_reviewer! }
  let(:publisher) do
    User.create!(email_address: "pb-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
  end

  # Mesmo caminho de spec/commands/protocols_revert_activation_spec.rb:
  # Protocols::Activate com assinaturas de verdade, nunca ProtocolActivation
  # criada na mão — é o que garante que `kind: "signed"` venha do domínio.
  def activate!(version_number)
    ProtocolDefinition.create!(name: "dengue", version: version_number, status: "published",
                               definition: protocol_definition_hash(version: version_number))
    protocol = ProtocolDefinition.find_by!(name: "dengue", version: version_number)
    sign!(protocol, purpose: "activation", by: ana)
    sign!(protocol, purpose: "activation", by: bia)
    expect(Protocols::Activate.call(version: version_number, name: "dengue", by: publisher).ok?).to be(true)
    protocol.reload
  end

  # Autor salva v1 e v2; dois revisores assinam ativação de cada uma;
  # Protocols::Activate ativa v1 e depois v2 (v1 fica published de novo).
  let!(:v1) { activate!(1) }
  let!(:v2) { activate!(2) }

  # Protocolo separado, com a ÚNICA ativação em `kind: "baseline"` — o
  # protocolo que já estava em uso antes das assinaturas existirem.
  let!(:baseline_version) do
    legacy = ProtocolDefinition.create!(name: "sarampo", version: 1, status: "active",
                                        definition: protocol_definition_hash(name: "sarampo"))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)
    legacy
  end

  it "devolve a versão anterior quando a ativação corrente é assinada e a anterior está published" do
    expect(described_class.revert_target(v2.reload)).to eq(v1)
    expect(described_class.revertible?(v2.reload)).to be(true)
  end

  it "não devolve alvo para uma versão que não está em uso" do
    expect(described_class.revert_target(v1.reload)).to be_nil
    expect(described_class.revertible?(v1.reload)).to be(false)
  end

  it "não devolve alvo quando a ativação corrente é a linha-base" do
    # Uma versão ativa cuja única ativação é `kind: "baseline"` (o protocolo que
    # já estava em uso antes das assinaturas) não reverte: não há passo anterior.
    expect(described_class.revert_target(baseline_version.reload)).to be_nil
    expect(described_class.revertible?(baseline_version.reload)).to be(false)
  end

  it "não devolve alvo quando a versão anterior não está mais published" do
    v1.update!(status: "retired")

    expect(described_class.revert_target(v2.reload)).to be_nil
    expect(described_class.revertible?(v2.reload)).to be(false)
  end

  it "revertible? concorda com revert_target em todos os casos" do
    [ v1, v2, baseline_version ].each do |protocol|
      protocol.reload
      expect(described_class.revertible?(protocol)).to eq(described_class.revert_target(protocol).present?)
    end
  end

  # `activation_history` roda DUAS vezes na mesma reversão — a leitura rápida
  # sem lock e a reconferência sob lock. Com `created_at` empatado e sem
  # desempate, as duas execuções do MESMO SQL podem devolver ordens
  # diferentes: o alvo conferido deixa de ser o alvo revertido.
  #
  # O desempate por `id` compra DETERMINISMO, não cronologia — `id` é UUID
  # (gen_random_uuid), então a linha escolhida é estável e arbitrária. Num
  # empate de microssegundo não há ordem a respeitar; há consistência a
  # garantir. A segunda asserção prende qual linha vence, porque sem ela o
  # exemplo passaria por sorte: com tabela pequena o Postgres costuma devolver
  # ordem estável mesmo sem ORDER BY completo.
  # `activation_history` roda DUAS vezes na mesma reversão — a leitura rápida
  # sem lock e a reconferência sob lock. Com `created_at` empatado e a ordem
  # incompleta, as duas execuções do MESMO SQL podem devolver ordens
  # diferentes, e o alvo conferido deixa de ser o alvo revertido.
  #
  # Por que a asserção é sobre o SQL e não sobre qual linha volta: sem
  # desempate o Postgres devolve a ordem física, que numa tabela pequena é
  # estável — um exemplo que afirmasse "vence a de maior id" passaria por
  # sorte, ANTES da correção, e não provaria nada (já aconteceu duas vezes
  # neste projeto). O que se compra aqui é ordem totalmente especificada; é
  # isso que o exemplo prende.
  #
  # O desempate por `id` compra DETERMINISMO, não cronologia: `id` é UUID
  # (gen_random_uuid), então num empate a linha escolhida é estável e
  # arbitrária. Num empate de microssegundo não há ordem a respeitar; há
  # consistência a garantir.
  describe "ordenação do histórico de ativações" do
    include ActiveSupport::Testing::TimeHelpers

    # ProtocolActivation é append-only (trigger + readonly no modelo), então o
    # empate não se monta editando a linha: monta-se congelando o relógio e
    # ativando duas versões pelo caminho real.
    let!(:tied) { travel_to(1.hour.from_now) { activate!(3); activate!(4) } }

    def dengue_activations
      ProtocolActivation.joins(:protocol_definition).where(protocol_definitions: { name: "dengue" })
    end

    it "o arranjo empata de verdade — senão não há o que desempatar" do
      tie = dengue_activations.maximum(:created_at)

      expect(dengue_activations.where(created_at: tie).count).to eq(2)
    end

    it "ordena por created_at E por id, sem deixar empate para o banco resolver" do
      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] if payload[:sql].include?("protocol_activations")
      end
      begin
        described_class.send(:activation_history, "dengue")
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      ordering = queries.last[/ORDER BY (.+?)(?: LIMIT|$)/, 1]
      expect(ordering).to match(/created_at.*DESC/i)
      expect(ordering).to match(/\bid\b.*DESC/i)
    end
  end
end
